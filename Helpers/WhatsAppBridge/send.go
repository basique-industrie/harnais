package main

import (
	"context"
	"database/sql"
	"errors"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
	"strings"
	"time"
)

func validateSend(args object) (types.JID, string, string, error) {
	if args["user_requested"] != true {
		return types.JID{}, "", "", errors.New("Send only when the user explicitly requested this exact recipient and message")
	}
	chat, text, requestID := str(args, "chat"), str(args, "text"), str(args, "request_id")
	jid, err := types.ParseJID(chat)
	if err != nil || jid.User == "" || jid.Device != 0 || (jid.Server != types.DefaultUserServer && jid.Server != types.GroupServer && jid.Server != types.HiddenUserServer) {
		return types.JID{}, "", "", errors.New("Use a contact or group chat ID returned by the read tools")
	}
	if strings.TrimSpace(text) == "" || len(text) > 16000 {
		return types.JID{}, "", "", errors.New("Message must contain 1–16000 bytes")
	}
	if len(requestID) < 8 || len(requestID) > 128 {
		return types.JID{}, "", "", errors.New("Supply a unique request_id of 8–128 characters; reuse it when checking this send")
	}
	return jid, text, requestID, nil
}

func (b *bridge) sendPrepared(ctx context.Context, args object, document *localDocument) (object, error) {
	jid, text, key, err := validateSend(args)
	if err != nil {
		return nil, err
	}
	b.sendMu.Lock()
	defer b.sendMu.Unlock()
	var oldChat, oldText, id, state string
	err = b.db.QueryRowContext(ctx, "SELECT chat,text,message_id,state FROM sends WHERE request_id=?", key).Scan(&oldChat, &oldText, &id, &state)
	if err == nil {
		if oldChat != jid.String() || oldText != text {
			return nil, errors.New("request_id already belongs to a different message")
		}
		if state == "sent" {
			return object{"sent": true, "messageID": id, "alreadySent": true}, nil
		}
		return nil, errors.New("The previous send has an uncertain outcome. Check WhatsApp before sending again; Harnais will not retry it automatically")
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if !b.client.IsConnected() || !b.client.IsLoggedIn() {
		return nil, errors.New("WhatsApp is offline. Reconnect before sending")
	}
	// No arbitrary broadcast targets. The user must resolve a known contact/chat.
	var exists int
	_ = b.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM chats WHERE jid=?", jid.String()).Scan(&exists)
	if exists == 0 && jid != b.client.Store.ID.ToNonAD() {
		contact, e := b.client.Store.Contacts.GetContact(ctx, jid)
		if e != nil || !contact.Found {
			return nil, errors.New("Recipient was not found in the linked contacts or chats")
		}
	}
	id = b.client.GenerateMessageID()
	_, err = b.db.ExecContext(ctx, "INSERT INTO sends(request_id,chat,text,message_id,state) VALUES(?,?,?,?,'pending')", key, jid.String(), text, id)
	if err != nil {
		return nil, err
	}
	sendCtx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	message := &waE2E.Message{Conversation: proto.String(text)}
	if document != nil {
		upload, uploadErr := b.client.Upload(sendCtx, document.data, whatsmeow.MediaDocument)
		if uploadErr != nil {
			_, _ = b.db.Exec("DELETE FROM sends WHERE request_id=?", key)
			return nil, errors.New("Document upload failed; no message was sent")
		}
		message = documentMessage(document, upload)
	}
	response, err := b.client.SendMessage(sendCtx, jid, message, whatsmeow.SendRequestExtra{ID: id})
	if err != nil {
		return nil, errors.New("WhatsApp did not confirm the send. Check the chat before retrying; this request_id will not send twice")
	}
	_, err = b.db.ExecContext(ctx, "UPDATE sends SET state='sent' WHERE request_id=?", key)
	if err != nil {
		return nil, errors.New("Message sent but local receipt could not be saved. Do not retry")
	}
	_, _ = b.db.ExecContext(ctx, "INSERT OR REPLACE INTO messages(chat,id,sender,from_me,timestamp,text) VALUES(?,?,?,1,?,?)", jid.String(), id, b.client.Store.ID.ToNonAD().String(), response.Timestamp.Unix(), messageText(message))
	b.saveAttachment(jid.String(), id, message)
	_, _ = b.db.ExecContext(ctx, "INSERT INTO chats(jid,updated) VALUES(?,?) ON CONFLICT(jid) DO UPDATE SET updated=excluded.updated", jid.String(), response.Timestamp.Unix())
	return object{"sent": true, "messageID": id, "chat": jid.String()}, nil
}
