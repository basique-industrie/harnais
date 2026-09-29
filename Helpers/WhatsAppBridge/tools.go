package main

import (
	"context"
	"errors"
	"strings"
	"time"
)

func str(args object, key string) string { value, _ := args[key].(string); return value }
func limit(args object) int {
	n, _ := args["limit"].(float64)
	if n < 1 {
		return 20
	}
	if n > 100 {
		return 100
	}
	return int(n)
}
func (b *bridge) tool(ctx context.Context, input object) (object, error) {
	name := str(input, "name")
	args, _ := input["arguments"].(map[string]any)
	if args == nil {
		args = object{}
	}
	if name == "whatsapp_status" {
		return b.status(false), nil
	}
	if b.client.Store.ID == nil {
		return nil, errors.New("Link WhatsApp in Harnais first. Open Connections > Add connection > WhatsApp and scan the QR code")
	}
	switch name {
	case "whatsapp_list_chats":
		query := str(args, "query")
		if len(query) > 512 {
			return nil, errors.New("Search is too long")
		}
		rows, err := b.db.QueryContext(ctx, "SELECT jid,name,updated FROM chats WHERE instr(lower(name),lower(?))>0 OR instr(jid,?)>0 ORDER BY updated DESC,jid LIMIT ?", query, query, limit(args))
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		items := []object{}
		for rows.Next() {
			var jid, name string
			var timestamp int64
			if err = rows.Scan(&jid, &name, &timestamp); err != nil {
				return nil, err
			}
			items = append(items, object{"chat": jid, "name": name, "lastMessageAt": timestamp})
		}
		return object{"chats": items, "historyIsPartial": true}, rows.Err()
	case "whatsapp_search_messages", "whatsapp_read_chat":
		chat, query := str(args, "chat"), str(args, "query")
		if name == "whatsapp_read_chat" && chat == "" {
			return nil, errors.New("Choose a chat returned by whatsapp_list_chats")
		}
		if len(query) > 512 {
			return nil, errors.New("Search is too long")
		}
		before, _ := args["before"].(float64)
		if before <= 0 {
			before = float64(time.Now().Unix() + 1)
		}
		rows, err := b.db.QueryContext(ctx, "SELECT chat,id,sender,from_me,timestamp,text FROM messages WHERE (?='' OR chat=?) AND instr(lower(text),lower(?))>0 AND timestamp<? ORDER BY timestamp DESC,chat,id LIMIT ?", chat, chat, query, int64(before), limit(args))
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		items := []object{}
		remaining := 128 * 1024
		truncated := false
		for rows.Next() {
			var chat, id, sender, text string
			var fromMe bool
			var timestamp int64
			if err = rows.Scan(&chat, &id, &sender, &fromMe, &timestamp, &text); err != nil {
				return nil, err
			}
			if len(text) > remaining {
				truncated = true
				break
			}
			remaining -= len(text)
			items = append(items, object{"chat": chat, "id": id, "sender": sender, "fromMe": fromMe, "timestamp": timestamp, "text": text})
		}
		return object{"messages": items, "historyIsPartial": true, "truncated": truncated}, rows.Err()
	case "whatsapp_search_contacts":
		query := strings.ToLower(str(args, "query"))
		if query == "" {
			return nil, errors.New("Enter a contact name or number")
		}
		contacts, err := b.client.Store.Contacts.GetAllContacts(ctx)
		if err != nil {
			return nil, err
		}
		items := []object{}
		for jid, c := range contacts {
			name := c.FullName
			if name == "" {
				name = c.PushName
			}
			if strings.Contains(strings.ToLower(name), query) || strings.Contains(jid.User, query) {
				items = append(items, object{"chat": jid.ToNonAD().String(), "name": name})
				if len(items) >= limit(args) {
					break
				}
			}
		}
		return object{"contacts": items}, nil
	case "whatsapp_list_documents":
		return b.documents(ctx, args)
	case "whatsapp_read_document":
		return b.readAttachment(ctx, args)
	case "whatsapp_download_attachment":
		return b.download(ctx, args)
	case "whatsapp_send_document":
		return b.sendDocument(ctx, args)
	case "whatsapp_send_message":
		return b.sendPrepared(ctx, args, nil)
	default:
		return nil, errors.New("Unknown WhatsApp tool")
	}
}
