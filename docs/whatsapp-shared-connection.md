# WhatsApp shared connection

Harnais uses one local linked-device session for the selected coding accounts.
The desktop WhatsApp app stays signed in. Its private database and credentials
are not copied. WhatsApp on the phone must authorize Harnais by scanning its QR
code under Settings > Linked devices.

The adapter uses the unofficial whatsmeow client, pinned in
`Helpers/WhatsAppBridge/go.mod` and `go.sum`. It is not Meta's Business API.
Harnais packages the compiled helper; users do not need Go, Node, or Python.

## Tools

- Check the link and synced message count.
- Find chats and contacts, search messages, and read a chat.
- Find received or sent documents by filename and caption.
- Download a document, image, video, or audio attachment, up to 50 MB.
- Read a document locally, up to 16 MB. The same reader used for Drive handles
  PDF, Office, OpenDocument, UTF-8 text, and image OCR. The original download
  remains available if extraction is unsupported.
- Send a text message or a local document with an optional caption, up to 50 MB.

Send tools require the agent to assert that the human requested the recipient
and content. This is an instruction and validation check, not independent proof
of user intent. Provider tool permissions still govern sends. There are no
automatic replies, broadcasts, or bulk-send tools. A unique request ID prevents
duplicate sends. If WhatsApp does not acknowledge a send, that ID stays blocked;
the agent must check the chat before attempting another send.

## Data and lifecycle

Session keys, message history, and attachment metadata live in `~/.harnais/whatsapp`
with a user-only directory and files. A user-only Unix socket connects local MCP
processes to the single helper. There is no TCP listener. QR values are available
only to the linking UI, never through MCP tools or the inventory health file.
The helper does not log chat contents or session keys.

The helper starts when linking or when a tool is first used. It stays running to
receive messages and reconnects using the saved device session. Restarting the
Mac does not require another link; the next tool call starts the helper.

Only history WhatsApp supplies to this linked device is available. View-once and
disappearing-message content is excluded. Received revocations remove the local
message and attachment metadata. Downloaded originals are local files and do not
automatically disappear when a remote message is revoked. Disconnect unlinks
Harnais, clears its local message/download cache, and removes its shared adapters.
The phone's Linked devices screen can also revoke access.

Agents send the messages/documents they read to their selected AI provider as
part of tool results. Per-account switches determine which configurations receive
the adapter. Reload existing agent sessions after changing availability.

## Validation

Automated tests cover both MCP framings, tool discovery, document bytes and
metadata, filename containment, size limits, disappearing-message exclusions,
revocations, QR isolation, literal searches, and duplicate-send handling. Swift
tests cover document extraction containment and sharing across seven account
configurations. The run passed 765 Swift checks and 12 Go tests, including the race detector.
Live checks below were recorded separately after the phone link.

Live verification on September 28, 2026 passed. All seven saved account adapters
listed chats with the same ten tools. A received PDF downloaded and produced
2,910 characters of text. With explicit user approval, Harnais sent the one-page
`harnais-whatsapp-test.pdf` to the user's own chat with the caption "Harnais
document test". Its downloaded bytes matched the original, and its text was
readable. All seven account adapters also downloaded and read this PDF successfully. The test PDF remains in that chat. Restarting the helper restored the linked session without another QR scan; all seven accounts could still list documents afterward. The obsolete "Import Grafana from
Cursor" shortcut was then removed from Add connection.

## Sources

- [whatsmeow](https://github.com/tulir/whatsmeow)
- [whatsmeow API](https://pkg.go.dev/go.mau.fi/whatsmeow)
- [WhatsApp MCP reference architecture](https://github.com/lharries/whatsapp-mcp)
- [WhatsApp linked devices](https://faq.whatsapp.com/378279804439436/)
