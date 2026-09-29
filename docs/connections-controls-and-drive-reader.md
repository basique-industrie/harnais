# Connection controls and Drive reader

Connections and Skills share a 28-point add menu, outlined account menu and search field. Their trailing edges follow the content column. Narrow windows place the actions on a separate right-aligned row. Skills uses Add skill for creation and folder import.

## Account availability

The Accounts tab of a shared connection has one switch per registered account. Save and sync persists the selection in `excludedAccountIDs` and removes the owned adapter from excluded accounts. Other services and credentials remain available. Sync all respects exclusions; a global pause preserves individual account choices. Accounts using one settings file switch together. An exclusion wins if conflicting choices reach the exporter.

An intentional exclusion shows Off rather than a missing-connection warning. Existing provider sessions need a reload. These controls manage local Harnais adapter configuration, not revocation of independent provider logins or tools already running in a session.

## Why the Drive reader differed

The Cursor plugin uses Google's hosted Drive MCP service. Its documented reader supports Office, OpenDocument and image content. The previous Harnais reader extracted plain text and PDFs and exported Google Sheets as PDF. That lost cell addresses, formulas and hidden sheets. Google's hosted service currently rejects a read with Harnais's own OAuth registration, even though the stable Drive API accepts the same login.

Harnais now reads downloaded content locally:

- Google Sheets exports to XLSX, including all sheets, cell addresses, cached values and formulas. Hidden sheets are included.
- DOCX, XLSX, PPTX, ODT, ODS and ODP packages are read without unpacking files into the filesystem or executing package content.
- Legacy DOC and RTF use macOS's text converter.
- PNG/JPEG and scanned PDF pages use local Vision OCR. Text PDFs still use PDF text extraction.
- Downloads, comments, metadata, file creation, copying, renaming, moving, trashing and sharing retain their existing tools.

The existing `drive.readonly` and `drive.file` scopes are preserved. Google's hosted connector documents the same scope pair. A file authorized for Cursor is not automatically authorized for Harnais, so neither a provider switch nor reading a file can grant broader edit permissions.

## Document editing

The shared adapter now exposes 29 tools, including native Sheets, Docs and Slides editing and whole-file replacement for uploaded Office files. See [Drive document editing](drive-document-editing.md) for the tool list, permissions, examples and validation.

## Limits

This is content extraction, not a rendering replica. OCR does not describe non-text visuals. Dates in spreadsheets may be stored serial numbers, shared formulas retain their group metadata, and charts/formatting require the original download. Output is capped at 500,000 characters; PDFs process at most 100 pages, with OCR on the first 30. Binary input is capped at 16 MB; package members and total expanded XML have separate bounds. Google-native exports also remain subject to Google's limits. Comments are returned separately with anchors.

## Verification

758 automated checks passed. The new checks cover repeated per-account sync across the seven-account layout, re-enabling, global pause, shared settings-file conflicts, persisted choices, Office readers, hidden-sheet/formula preservation, image OCR and malformed packages.

The live fixture script creates private test files, reads them through the shared connection and trashes them afterward. It tests Google Docs/Sheets, binary Office/OpenDocument files, copying, renaming, permissions and download bytes. `--all-accounts` also reads an XLSX through each account's actual configured command and verifies formulas plus hidden-sheet content.

```sh
python3 scripts/check-drive-reader.py --binary '.build/release/harnais' --all-accounts --output /tmp/harnais-drive-reader.json
python3 scripts/probe-shared-connections.py harnais-google-drive-personal --tool list_recent_files --record --output /tmp/harnais-drive-accounts.json
```

References: [Google hosted reader](https://developers.google.com/workspace/drive/api/reference/mcp/tools_list/read_file_content), [hosted connector setup and scopes](https://developers.google.com/workspace/drive/api/guides/configure-mcp-server), [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth), [export formats](https://developers.google.com/workspace/drive/api/guides/ref-export-formats).

All seven registered account adapters passed a live workbook read, including formulas and a hidden sheet. Nine private fixtures were created and all nine were trashed. The duplicate account-level Cursor `google-drive` transport was removed after these checks. Cursor CLI now reports only `harnais-google-drive-personal` for Drive, ready, along with the other ten shared services. The inactive plugin cache remains inspectable. Backup: `~/.harnais/migrations/20260928-172553-drive-reader-shared/cursor-mcp.json`.
