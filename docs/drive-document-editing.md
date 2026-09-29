# Drive document editing

The shared Google Drive adapter now exposes 29 tools. The previous 11 file tools remain available. New tools edit native Google Sheets, Docs and Slides and replace the content of uploaded files without creating another file.

## What each tool does

| Area | Tools | Supported work |
| --- | --- | --- |
| Drive files | Existing `list_recent_files`, `search_files`, `get_file_metadata`, `get_file_permissions`, `read_file_content`, `download_file_content`, `copy_file`, `create_file`, `update_file`, `trash_file`, `share_file` | Existing browsing, reading, creation and file management |
| Uploaded files | `download_file_to_path`, `replace_file_content` | Replace complete Excel, Word, PowerPoint, PDF or other binary/text content while preserving the file ID, link, name, folder and sharing |
| Creation | `create_spreadsheet`, `create_document`, `create_presentation` | Create native files with the shared Harnais login, optionally inside a folder |
| Workbook inspection | `get_spreadsheet`, `read_spreadsheet_values` | Sheet IDs, dimensions, named ranges, charts, cell formats, values and formulas across worksheets |
| Workbook editing | `update_spreadsheet_values`, `append_spreadsheet_values`, `clear_spreadsheet_values` | Write selected cell ranges, evaluate intended formulas, append rows or clear contents while retaining formats |
| Workbook structure | `batch_update_spreadsheet`, `copy_worksheet` | Worksheets, row/column operations, formatting, filters, sorting, validation, charts, merged cells and worksheet copies |
| Documents | `get_document`, `replace_document_text`, `batch_update_document` | Read all tabs; replace text; insert, remove or style text; manipulate tables and other supported Docs structures |
| Presentations | `get_presentation`, `replace_presentation_text`, `batch_update_presentation` | Read slides and object IDs; replace text; create or edit slides, shapes, text and other supported Slides structures |

Batch tools accept official API Request objects, at most 100 operations and 8 MB per call. Google validates supported operations and applies each valid batch atomically. Feature availability can vary for Google's preview-only operations. The adapter does not advertise preview access.

## Uploaded Excel versus native Google Sheets

Cell and worksheet tools operate on native Google Sheets. An `.xlsx` file stored in Drive remains an Excel file and does not gain Sheets API support simply because it is on Drive.

For an existing Excel workbook:

1. Call `download_file_to_path`. It creates a private local working copy and returns its path, MIME type and version without filling the agent context with base64. Keep a backup before editing.
2. Edit the downloaded workbook with an appropriate spreadsheet editor. Preserve formulas, formatting, charts and macros as required by the file. Harnais does not reconstruct the workbook from its text preview or recalculate Excel formulas itself.
3. Call `replace_file_content` with the same `fileId`, the edited `localPath`, and the original `version` as `expectedVersion`.
4. Download or read it again to verify the result, then remove the temporary local working folder.

The same workflow applies to uploaded Word and PowerPoint files. Replacement sends the exact supplied bytes; it never converts them to a Google format. Office files require `localPath` or `base64Content` rather than text input. A local path must be absolute, name a regular file and not be a symlink. Text input is available for text, JSON and XML files. Native Google files, folders, shortcuts, trashed files and files lacking edit capability are rejected before upload.

Replacement is bounded to 16 MB. Files over 5 MB use a Google resumable-upload session. The current implementation sends one payload per session and does not persist sessions across process restarts. A network interruption can leave completion uncertain; inspect the file before retrying.

`expectedVersion` checks metadata immediately before replacement. It is a preflight check, not an atomic lock against a collaborator changing the file during the upload. Coordinate whole-file edits. Docs and Slides provide a stronger `requiredRevisionId` write control, which Google rejects if stale. Sheets has no equivalent revision argument in these tools.

## Cell editing example

For native Google Sheets, call `update_spreadsheet_values`:

```json
{
  "fileId": "SPREADSHEET_ID",
  "valueInputOption": "USER_ENTERED",
  "data": [
    {"range": "Budget!B2:C2", "values": [[21, "=B2*2"]]}
  ]
}
```

The default input mode is `RAW`, which writes strings literally. Choose `USER_ENTERED` explicitly for formulas or Google's number/date parsing. A null value skips a cell; an empty string clears it. Use `read_spreadsheet_values` with `FORMULA` to inspect formulas or `UNFORMATTED_VALUE` to read calculated values.

For formatting or worksheet structure, read `get_spreadsheet` first to obtain sheet IDs, then send native Request objects to `batch_update_spreadsheet`. Grid indices are zero-based and end-exclusive. Document indices use UTF-16 offsets and the tab IDs returned by `get_document`. Slide edits use the object IDs returned by `get_presentation`.

## Permissions and activation

Harnais reuses its existing `drive.readonly` and `drive.file` scopes. No additional broad write scope or separate account login was added. Reading a file does not grant Harnais permission to edit it. Google continues to restrict writes to files created or explicitly authorized for the Harnais app, unless the user previously granted broader consent. A file authorized for Cursor is not automatically authorized for Harnais.

Drive, Sheets, Docs and Slides APIs must be enabled in the project that owns the OAuth client. These services were enabled in the existing `harnais-mcp` project using its designated personal owner. Custom OAuth clients need the same API setup in their own projects. Errors now distinguish disabled APIs, permission failures, rate limits and revision conflicts.

Provider tool approvals continue to apply. All editing tools declare write/destructive annotations. After upgrading, reload a provider's MCP connection or start a fresh session so its cached tool list includes the additions. Harnais cannot replace the schema already cached inside a running third-party agent session.

## Validation

- 883 automated checks passed, including 99 added checks for routing, write annotations, payload preservation, scope, native revision controls, malformed arguments, URL isolation, size limits, private local file handoff and resumable upload destinations.
- Live private fixtures passed native Sheets values/formulas, literal RAW text, frozen rows and bold formatting, append/copy/clear operations, Docs insertion/replacement and stale-revision rejection, and Slides creation/shapes/text/replacement.
- A live Excel replacement preserved ID, URL, filename, parent folder, formulas, hidden-sheet content and exact revised bytes. A stale preflight version was rejected.
- A replacement larger than 5 MB uploaded and downloaded byte-for-byte through a resumable session.
- Each live run creates six private fixtures and trashes only those fixtures on completion. No existing user document is edited.
- All seven saved account configurations exposed the same 29 tools and passed a native spreadsheet write/read, Docs and Slides reads, and exact XLSX download comparison. The packaged run passed 14 live checks and trashed all six fixtures. Results are recorded in `/tmp/harnais-drive-edit-all-accounts.json`.
- All seven read-only health probes passed with 29 tools; Harnais's dated Drive validation record was refreshed. The final signed development bundle was gracefully relaunched and its new process verified.

Run the end-to-end check with:

```sh
python3 scripts/check-drive-editing.py \
  --binary 'dist/Harnais Dev.app/Contents/MacOS/harnais' \
  --all-accounts --output /tmp/harnais-drive-edit-all-accounts.json
```

References: [Drive file updates](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/update), [upload protocols](https://developers.google.com/workspace/drive/api/guides/manage-uploads), [Sheets cell writes](https://developers.google.com/workspace/sheets/api/reference/rest/v4/spreadsheets.values/batchUpdate), [Sheets structural requests](https://developers.google.com/workspace/sheets/api/reference/rest/v4/spreadsheets/request), [Docs updates and revision controls](https://developers.google.com/workspace/docs/api/reference/rest/v1/documents/batchUpdate), [Slides updates and revision controls](https://developers.google.com/workspace/slides/api/reference/rest/v1/presentations/batchUpdate).
