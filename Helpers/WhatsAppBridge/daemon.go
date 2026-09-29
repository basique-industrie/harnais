package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

type bridge struct {
	client    *whatsmeow.Client
	db        *sql.DB
	mu        sync.Mutex
	qr        string
	state     string
	directory string
	sendMu    sync.Mutex
}

func serve(directory string) error {
	lock, err := os.OpenFile(filepath.Join(directory, "bridge.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return nil
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	container, err := sqlstore.New(context.Background(), "sqlite3", "file:"+filepath.Join(directory, "session.db")+"?_foreign_keys=on&_busy_timeout=5000", nil)
	if err != nil {
		return err
	}
	defer container.Close()
	device, err := container.GetFirstDevice(context.Background())
	if err != nil {
		return err
	}
	store.DeviceProps.Os = proto.String("Harnais")
	store.DeviceProps.RequireFullSync = proto.Bool(false)
	client := whatsmeow.NewClient(device, nil)
	db, err := openMessages(directory)
	if err != nil {
		return err
	}
	defer db.Close()
	b := &bridge{client: client, db: db, state: "connecting", directory: directory}
	client.AddEventHandler(b.event)
	socket := filepath.Join(directory, "bridge.sock")
	_ = os.Remove(socket)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer os.Remove(socket)
	if err = os.Chmod(socket, 0600); err != nil {
		listener.Close()
		return err
	}
	mux := http.NewServeMux()
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 70 * time.Second}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(stop)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method != "POST" || r.Host != "localhost" {
			http.Error(w, `{ "error": "Invalid request" }`, 400)
			return
		}
		var input object
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&input); err != nil {
			http.Error(w, `{ "error": "Invalid request" }`, 400)
			return
		}
		var result object
		var requestErr error
		switch r.URL.Path {
		case "/status":
			result = b.status(true)
		case "/stop":
			result = object{"stopped": true}
			defer func() { stop <- syscall.SIGTERM }()
		case "/logout":
			if client.Store.ID != nil {
				requestErr = client.Logout(r.Context())
			}
			if requestErr == nil {
				_, requestErr = db.Exec("DELETE FROM messages; DELETE FROM chats; DELETE FROM sends; DELETE FROM attachments; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
				_ = os.RemoveAll(filepath.Join(directory, "downloads"))
				result = object{"unlinked": true}
				defer func() { stop <- syscall.SIGTERM }()
			} else {
				requestErr = errors.New("WhatsApp could not unlink. Check your network or unlink Harnais from WhatsApp on your phone, then retry")
			}
		case "/tool":
			result, requestErr = b.tool(r.Context(), input)
		default:
			requestErr = errors.New("Unknown operation")
		}
		if requestErr != nil {
			w.WriteHeader(400)
			result = object{"error": requestErr.Error()}
		}
		_ = json.NewEncoder(w).Encode(result)
	})
	go func() { _ = server.Serve(listener) }()
	go b.connect()
	<-stop
	client.Disconnect()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return server.Shutdown(ctx)
}

func (b *bridge) connect() {
	if b.client.Store.ID == nil {
		qr, err := b.client.GetQRChannel(context.Background())
		if err != nil {
			b.setState("link-failed", "")
			return
		}
		if err = b.client.Connect(); err != nil {
			b.setState("offline", "")
			return
		}
		for item := range qr {
			if item.Event == "code" {
				b.setState("scan-qr", item.Code)
			} else if item.Event == "success" {
				b.setState("connected", "")
			} else {
				b.setState(item.Event, "")
			}
		}
	} else if err := b.client.Connect(); err != nil {
		b.setState("offline", "")
	}
}
func (b *bridge) setState(state, qr string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.state = state
	b.qr = qr
	// Contains no account identifier, message, QR, or key. Inventory can read it without starting a process.
	data, _ := json.Marshal(object{"state": state})
	temp := filepath.Join(b.directory, "health.json.tmp")
	if os.WriteFile(temp, data, 0600) == nil {
		_ = os.Rename(temp, filepath.Join(b.directory, "health.json"))
	}
}
func (b *bridge) status(includeQR bool) object {
	b.mu.Lock()
	defer b.mu.Unlock()
	var count int
	_ = b.db.QueryRow("SELECT COUNT(*) FROM messages").Scan(&count)
	value := object{"state": b.state, "connected": b.client.IsConnected() && b.client.IsLoggedIn(), "messageCount": count,
		"history": "Only history WhatsApp syncs to this linked device is available. View-once and disappearing message content is excluded.", "version": 1}
	if b.client.Store.ID != nil {
		value["account"] = b.client.Store.ID.ToNonAD().String()
	}
	if includeQR && b.qr != "" {
		value["qr"] = b.qr
	}
	return value
}

func (b *bridge) event(evt any) {
	switch e := evt.(type) {
	case *events.Connected:
		b.setState("connected", "")
	case *events.Disconnected:
		b.setState("offline", "")
	case *events.LoggedOut:
		_ = os.RemoveAll(filepath.Join(b.directory, "downloads"))
		b.setState("unlinked", "")
		_, _ = b.db.Exec("DELETE FROM messages; DELETE FROM chats; DELETE FROM sends; DELETE FROM attachments; PRAGMA wal_checkpoint(TRUNCATE);")
	case *events.Message:
		b.saveMessage(e)
	case *events.HistorySync:
		for _, conversation := range e.Data.GetConversations() {
			if conversation.GetEphemeralExpiration() > 0 {
				continue
			}
			jid, err := types.ParseJID(conversation.GetID())
			if err != nil {
				continue
			}
			_, _ = b.db.Exec("INSERT INTO chats(jid,name) VALUES(?,?) ON CONFLICT(jid) DO UPDATE SET name=CASE WHEN excluded.name<>'' THEN excluded.name ELSE name END", jid.String(), conversation.GetName())
			for _, msg := range conversation.GetMessages() {
				parsed, err := b.client.ParseWebMessage(jid, msg.GetMessage())
				if err == nil {
					b.saveMessage(parsed)
				}
			}
		}
	}
}
