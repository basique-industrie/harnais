package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

func fixtureBridge(t *testing.T) *bridge {
	t.Helper()
	directory := t.TempDir()
	db, err := openMessages(directory)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	jid := types.NewJID("12345", types.DefaultUserServer)
	return &bridge{db: db, directory: directory, client: whatsmeow.NewClient(&store.Device{ID: &jid}, nil), state: "connected"}
}
func fixtureMessage(id, text string) *events.Message {
	return &events.Message{Info: types.MessageInfo{MessageSource: types.MessageSource{Chat: types.NewJID("12345", types.DefaultUserServer), Sender: types.NewJID("67890", types.DefaultUserServer)}, ID: id, Timestamp: time.Unix(1000, 0), PushName: "Fixture contact"}, Message: &waE2E.Message{Conversation: proto.String(text)}}
}
func TestMessageSearchAndContactIsolation(t *testing.T) {
	b := fixtureBridge(t)
	b.saveMessage(fixtureMessage("one", "Quarterly O'Brien report"))
	b.saveMessage(fixtureMessage("two", "Other content"))
	result, err := b.tool(context.Background(), object{"name": "whatsapp_search_messages", "arguments": object{"query": "O'Brien", "limit": 10.0}})
	if err != nil {
		t.Fatal(err)
	}
	messages := result["messages"].([]object)
	if len(messages) != 1 || messages[0]["id"] != "one" {
		t.Fatalf("literal query failed: %v", result)
	}
	result, err = b.tool(context.Background(), object{"name": "whatsapp_read_chat", "arguments": object{"chat": "different@s.whatsapp.net"}})
	if err != nil || len(result["messages"].([]object)) != 0 {
		t.Fatal("cross-chat leak")
	}
}
func TestEphemeralAndViewOnceExcluded(t *testing.T) {
	b := fixtureBridge(t)
	for _, variant := range []string{"ephemeral", "view-once", "expiring-document", "expiring-image"} {
		m := fixtureMessage(variant, "Private fixture")
		switch variant {
		case "ephemeral":
			m.IsEphemeral = true
		case "view-once":
			m.IsViewOnce = true
		case "expiring-document":
			m.Message = &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{FileName: proto.String("private.pdf"), ContextInfo: &waE2E.ContextInfo{Expiration: proto.Uint32(3600)}}}
		case "expiring-image":
			m.Message = &waE2E.Message{ImageMessage: &waE2E.ImageMessage{ContextInfo: &waE2E.ContextInfo{Expiration: proto.Uint32(3600)}}}
		}
		b.saveMessage(m)
	}
	var count int
	b.db.QueryRow("SELECT COUNT(*) FROM messages").Scan(&count)
	if count != 0 {
		t.Fatal("private message cached")
	}
	b.db.QueryRow("SELECT COUNT(*) FROM attachments").Scan(&count)
	if count != 0 {
		t.Fatal("private attachment cached")
	}
}
func TestDocumentDiscoveryAndRevoke(t *testing.T) {
	b := fixtureBridge(t)
	m := fixtureMessage("doc", "")
	m.Message = &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{FileName: proto.String("report.pdf"), Mimetype: proto.String("application/pdf"), FileLength: proto.Uint64(123), Caption: proto.String("Quarterly numbers")}}
	b.saveMessage(m)
	result, err := b.documents(context.Background(), object{"query": "report"})
	if err != nil {
		t.Fatal(err)
	}
	items := result["documents"].([]object)
	if len(items) != 1 || items[0]["bytes"] != int64(123) || items[0]["message_id"] != "doc" {
		t.Fatal(result)
	}
	revoke := fixtureMessage("revoke", "")
	revoke.Message = &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{Type: waE2E.ProtocolMessage_REVOKE.Enum(), Key: &waCommon.MessageKey{ID: proto.String("doc")}}}
	b.saveMessage(revoke)
	result, err = b.documents(context.Background(), object{})
	if err != nil || len(result["documents"].([]object)) != 0 {
		t.Fatal("revoked document still discoverable")
	}
}
func TestSendRequiresExplicitRequestAndSafeTarget(t *testing.T) {
	args := object{"chat": "12345@s.whatsapp.net", "text": "Fixture", "request_id": "fixture-send-1"}
	if _, _, _, err := validateSend(args); err == nil {
		t.Fatal("send without request allowed")
	}
	args["user_requested"] = true
	for _, chat := range []string{"status@broadcast", "123@newsletter", "123:4@s.whatsapp.net", "", "name@example.com"} {
		args["chat"] = chat
		if _, _, _, err := validateSend(args); err == nil {
			t.Fatalf("bad target accepted: %s", chat)
		}
	}
	args["chat"] = "12345@s.whatsapp.net"
	if _, _, _, err := validateSend(args); err != nil {
		t.Fatal(err)
	}
}
func TestSendIdempotencyAndUncertainResult(t *testing.T) {
	b := fixtureBridge(t)
	args := object{"chat": "12345@s.whatsapp.net", "text": "Fixture", "request_id": "fixture-send-1", "user_requested": true}
	_, err := b.db.Exec("INSERT INTO sends VALUES(?,?,?,?,?)", "fixture-send-1", args["chat"], args["text"], "message-one", "sent")
	if err != nil {
		t.Fatal(err)
	}
	result, err := b.sendPrepared(context.Background(), args, nil)
	if err != nil || result["alreadySent"] != true {
		t.Fatal("retry not deduplicated")
	}
	b.db.Exec("UPDATE sends SET state='pending'")
	if _, err = b.sendPrepared(context.Background(), args, nil); err == nil {
		t.Fatal("uncertain send retried")
	}
	b.db.Exec("UPDATE sends SET state='sent'")
	args["text"] = "Changed"
	if _, err = b.sendPrepared(context.Background(), args, nil); err == nil {
		t.Fatal("id reused for different content")
	}
}
func TestLocalDocumentPreservesBytesAndCaption(t *testing.T) {
	path := filepath.Join(t.TempDir(), "report.pdf")
	data := []byte("%PDF-1.7\nHarnais fixture")
	os.WriteFile(path, data, 0600)
	doc, err := readDocument(path, "Requested report")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(doc.data, data) || doc.mime != "application/pdf" || doc.name != "report.pdf" {
		t.Fatal("document changed")
	}
	sent := documentMessage(doc, whatsmeow.UploadResponse{URL: "https://example.invalid/media", FileLength: uint64(len(data)), MediaKey: []byte{1, 2}, FileSHA256: []byte{3, 4}}).GetDocumentMessage()
	if sent.GetCaption() != "Requested report" || sent.GetFileLength() != uint64(len(data)) || !bytes.Equal(sent.GetMediaKey(), []byte{1, 2}) {
		t.Fatal("upload metadata lost")
	}
	if _, err = readDocument("relative.pdf", ""); err == nil {
		t.Fatal("relative path allowed")
	}
	if _, err = readDocument(filepath.Dir(path), ""); err == nil {
		t.Fatal("directory allowed")
	}
	file, _ := os.OpenFile(path, os.O_WRONLY, 0600)
	file.Truncate(maxAttachment + 1)
	file.Close()
	if _, err = readDocument(path, ""); err == nil {
		t.Fatal("oversized document allowed")
	}
}
func TestReceivedFilenameCannotEscapeCache(t *testing.T) {
	for _, name := range []string{"../../secret.pdf", "..\\..\\private.pdf", "/etc/passwd", "\x00evil.pdf", ".."} {
		safe := safeFilename(name, "application/pdf")
		if strings.ContainsAny(safe, "/\\\x00") || safe == ".." || strings.HasPrefix(safe, ".") {
			t.Fatalf("unsafe filename %q", safe)
		}
	}
}
func TestDownloadWriteBound(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "bounded")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	bounded := boundedFile{file}
	if _, err = bounded.WriteAt([]byte{1}, maxAttachment+(1<<20)); err == nil {
		t.Fatal("oversized write accepted")
	}
	if err = bounded.Truncate(maxAttachment + (2 << 20)); err == nil {
		t.Fatal("oversized truncate accepted")
	}
}
func TestStatusDoesNotExposeQRToAgents(t *testing.T) {
	b := fixtureBridge(t)
	b.setState("scan-qr", "SECRET-QR-FIXTURE")
	value, err := b.tool(context.Background(), object{"name": "whatsapp_status"})
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(value)
	if bytes.Contains(data, []byte("SECRET")) {
		t.Fatal("QR leaked to MCP")
	}
	disk, _ := os.ReadFile(filepath.Join(b.directory, "health.json"))
	if bytes.Contains(disk, []byte("SECRET")) {
		t.Fatal("QR leaked to health file")
	}
	if b.status(true)["qr"] != "SECRET-QR-FIXTURE" {
		t.Fatal("UI cannot read QR")
	}
}
func TestMCPDiscoveryAndBothFramings(t *testing.T) {
	init := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}`
	list := `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`
	input := init + "\n" + fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(list), list)
	var output bytes.Buffer
	if err := mcp(t.TempDir(), strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	text := output.String()
	if !strings.Contains(text, `"protocolVersion":"2024-11-05"`) || !strings.Contains(text, "Content-Length:") || !strings.Contains(text, "whatsapp_read_document") || !strings.Contains(text, "whatsapp_send_document") {
		t.Fatal("MCP discovery failed")
	}
	if len(toolDefinitions()) != 10 {
		t.Fatal("unexpected tool count")
	}
}
func TestMCPRejectsUnboundedInput(t *testing.T) {
	if err := mcp(t.TempDir(), strings.NewReader(strings.Repeat("x", (1<<20)+10)+"\n"), &bytes.Buffer{}); err == nil {
		t.Fatal("oversized input accepted")
	}
}

func TestChatReadBoundsTokenPayload(t *testing.T) {
	b := fixtureBridge(t)
	for i := 0; i < 100; i++ {
		b.saveMessage(fixtureMessage(fmt.Sprint(i), strings.Repeat("x", 32768)))
	}
	result, err := b.tool(context.Background(), object{"name": "whatsapp_read_chat", "arguments": object{"chat": "12345@s.whatsapp.net", "limit": 100.0}})
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(result)
	if len(data) > 150000 || result["truncated"] != true {
		t.Fatal("chat result not bounded")
	}
}
