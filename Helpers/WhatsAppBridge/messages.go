package main

import (
	"database/sql"
	_ "github.com/mattn/go-sqlite3"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types/events"
	"path/filepath"
)

func openMessages(directory string) (*sql.DB, error) {
	db, err := sql.Open("sqlite3", "file:"+filepath.Join(directory, "messages.db")+"?_journal_mode=WAL&_busy_timeout=5000&_secure_delete=on")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS chats (jid TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', updated INTEGER NOT NULL DEFAULT 0);
	CREATE TABLE IF NOT EXISTS messages (chat TEXT NOT NULL, id TEXT NOT NULL, sender TEXT NOT NULL, from_me INTEGER NOT NULL, timestamp INTEGER NOT NULL, text TEXT NOT NULL, PRIMARY KEY(chat,id));
	CREATE INDEX IF NOT EXISTS messages_time ON messages(chat,timestamp);
	CREATE TABLE IF NOT EXISTS attachments (chat TEXT NOT NULL,id TEXT NOT NULL,name TEXT,mime TEXT,size INTEGER,document INTEGER,payload BLOB,PRIMARY KEY(chat,id));
	CREATE TABLE IF NOT EXISTS sends (request_id TEXT PRIMARY KEY, chat TEXT NOT NULL, text TEXT NOT NULL, message_id TEXT NOT NULL, state TEXT NOT NULL);`)
	if err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func messageText(msg *waE2E.Message) string {
	if msg == nil {
		return ""
	}
	if text := msg.GetConversation(); text != "" {
		return text
	}
	if ext := msg.GetExtendedTextMessage(); ext != nil {
		return ext.GetText()
	}
	if image := msg.GetImageMessage(); image != nil {
		return "[Image] " + image.GetCaption()
	}
	if video := msg.GetVideoMessage(); video != nil {
		return "[Video] " + video.GetCaption()
	}
	if doc := msg.GetDocumentMessage(); doc != nil {
		return "[Document] " + doc.GetFileName() + " " + doc.GetCaption()
	}
	if msg.GetAudioMessage() != nil {
		return "[Audio message]"
	}
	if msg.GetStickerMessage() != nil {
		return "[Sticker]"
	}
	return ""
}

func (b *bridge) saveMessage(e *events.Message) {
	if e == nil || e.Message == nil || e.Info.Chat.Server == "broadcast" || e.Info.Chat.Server == "newsletter" {
		return
	}
	chat, id := e.Info.Chat.ToNonAD().String(), e.Info.ID
	if p := e.Message.GetProtocolMessage(); p != nil {
		if p.GetType() == waE2E.ProtocolMessage_REVOKE {
			_, _ = b.db.Exec("DELETE FROM messages WHERE chat=? AND id=?", chat, p.GetKey().GetID())
			_, _ = b.db.Exec("DELETE FROM attachments WHERE chat=? AND id=?", chat, p.GetKey().GetID())
		}
		if p.GetType() == waE2E.ProtocolMessage_MESSAGE_EDIT {
			_, _ = b.db.Exec("UPDATE messages SET text=? WHERE chat=? AND id=?", messageText(p.GetEditedMessage()), chat, p.GetKey().GetID())
		}
		return
	}
	if e.IsViewOnce || e.IsViewOnceV2 || e.IsViewOnceV2Extension || e.IsEphemeral || hasExpiration(e.Message) {
		return
	}
	text := messageText(e.Message)
	if text == "" {
		return
	}
	if len(text) > 32768 {
		text = text[:32768]
	}
	_, _ = b.db.Exec("INSERT OR REPLACE INTO messages(chat,id,sender,from_me,timestamp,text) VALUES(?,?,?,?,?,?)", chat, id, e.Info.Sender.ToNonAD().String(), e.Info.IsFromMe, e.Info.Timestamp.Unix(), text)
	b.saveAttachment(chat, id, e.Message)
	name := ""
	if !e.Info.IsGroup && !e.Info.IsFromMe {
		name = e.Info.PushName
	}
	_, _ = b.db.Exec("INSERT INTO chats(jid,name,updated) VALUES(?,?,?) ON CONFLICT(jid) DO UPDATE SET updated=MAX(updated,excluded.updated), name=CASE WHEN name='' THEN excluded.name ELSE name END", chat, name, e.Info.Timestamp.Unix())
}
