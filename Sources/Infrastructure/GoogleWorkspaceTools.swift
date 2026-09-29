import Foundation

/// Schemas for native Sheets, Docs and Slides editing through the shared Drive login.
enum GoogleWorkspaceTools {
    static var tools: [[String: Any]] {
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": string, "minItems": 1, "maxItems": 100]
        let boolean: [String: Any] = ["type": "boolean"]
        let requests: [String: Any] = ["type": "array", "items": ["type": "object", "additionalProperties": true], "minItems": 1, "maxItems": 100]
        let values: [String: Any] = ["type": "array", "items": ["type": "array", "items": ["type": ["string", "number", "boolean", "null"]]], "minItems": 1]
        let input: [String: Any] = ["type": "string", "enum": ["RAW", "USER_ENTERED"], "default": "RAW"]
        func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]], _ required: [String], write: Bool = false) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": !write, "destructiveHint": write, "idempotentHint": !write, "openWorldHint": true]]
        }
        let file = ["fileId": string]
        let revision = ["fileId": string, "requiredRevisionId": string]
        var result = [("spreadsheet", "Google Sheets workbook"), ("document", "Google Docs document"), ("presentation", "Google Slides presentation")].map { kind, label in
            tool("create_" + kind, "Create a native \(label) in Drive with Harnais edit access. Optional destination parentId. Returns its file ID and link.", ["title": string, "parentId": string], ["title"], write: true)
        }
        result += [
            tool("get_spreadsheet", "Inspect a native Google Sheets workbook, sheet IDs, dimensions, charts and named ranges. Optional A1 ranges and includeGridData expose cell formats and formulas. Defaults to metadata only. For uploaded Excel use download_file_content and replace_file_content.", file.merging(["ranges": strings, "includeGridData": boolean]) { _, b in b }, ["fileId"]),
            tool("read_spreadsheet_values", "Read one or more A1 ranges in native Google Sheets. Choose FORMULA for formulas, UNFORMATTED_VALUE for stored values, or FORMATTED_VALUE for display text. Supports multiple worksheets.", file.merging(["ranges": strings, "valueRenderOption": ["type": "string", "enum": ["FORMATTED_VALUE", "UNFORMATTED_VALUE", "FORMULA"]]]) { _, b in b }, ["fileId", "ranges"]),
            tool("update_spreadsheet_values", "Write selected ranges in native Google Sheets without replacing other cells or formatting. data contains {range, values, majorDimension?}. RAW is the default; explicitly choose USER_ENTERED to evaluate formulas or parse dates/numbers. Null cells are skipped; empty strings clear cells.", file.merging(["data": ["type": "array", "minItems": 1, "maxItems": 100, "items": ["type": "object", "properties": ["range": string, "values": values, "majorDimension": ["type": "string", "enum": ["ROWS", "COLUMNS"]]], "required": ["range", "values"], "additionalProperties": false]], "valueInputOption": input]) { _, b in b }, ["fileId", "data"], write: true),
            tool("append_spreadsheet_values", "Append rows after the logical table in an A1 range in native Google Sheets. Inserts rows. RAW by default; USER_ENTERED evaluates formulas. Repeating this call appends duplicate rows; check results before retrying.", file.merging(["range": string, "values": values, "valueInputOption": input]) { _, b in b }, ["fileId", "range", "values"], write: true),
            tool("clear_spreadsheet_values", "Clear values and formulas in explicit A1 ranges in native Google Sheets. Retains formatting and validation. This removes cell contents.", file.merging(["ranges": strings]) { _, b in b }, ["fileId", "ranges"], write: true),
            tool("batch_update_spreadsheet", "Apply up to 100 official Sheets API Request objects atomically. Supports addSheet, deleteSheet, updateSheetProperties, repeatCell formatting, updateCells, insertDimension, deleteDimension, sortRange, setBasicFilter, addChart, mergeCells and data validation. Indices are zero-based and end-exclusive. Inspect sheet IDs first. https://developers.google.com/workspace/sheets/api/reference/rest/v4/spreadsheets/request", file.merging(["requests": requests]) { _, b in b }, ["fileId", "requests"], write: true),
            tool("copy_worksheet", "Copy a worksheet by sheetId into a native Google Sheets workbook, including the same workbook. Returns the new sheet properties. Requires access to both workbooks.", file.merging(["sheetId": ["type": "integer", "minimum": 0], "destinationSpreadsheetId": string]) { _, b in b }, ["fileId", "sheetId", "destinationSpreadsheetId"], write: true),
            tool("get_document", "Read a native Google Docs document with all tabs, text, tables, structural indices, styles and revisionId. Indices for edits are UTF-16 offsets. Uploaded Word files use download_file_content and replace_file_content.", file, ["fileId"]),
            tool("replace_document_text", "Replace literal text throughout native Google Docs. Optional tabIds limits the replacement. matchCase defaults true. Use requiredRevisionId from get_document to reject concurrent edits. Empty replacement deletes matching text.", revision.merging(["text": string, "replacement": string, "matchCase": boolean, "tabIds": strings]) { _, b in b }, ["fileId", "text", "replacement"], write: true),
            tool("batch_update_document", "Apply up to 100 official Docs API Request objects atomically: insertText, deleteContentRange, updateTextStyle, updateParagraphStyle, insertTable, insertInlineImage and more. Read the document first for UTF-16 indices and tab IDs. Use requiredRevisionId to reject stale edits. https://developers.google.com/workspace/docs/api/reference/rest/v1/documents/request", revision.merging(["requests": requests]) { _, b in b }, ["fileId", "requests"], write: true),
            tool("get_presentation", "Read a native Google Slides presentation, slide/object IDs, text, shapes, notes and revisionId. Uploaded PowerPoint files use download_file_content and replace_file_content.", file, ["fileId"]),
            tool("replace_presentation_text", "Replace literal text in native Google Slides. Optional pageObjectIds limits slides. matchCase defaults true. Use requiredRevisionId from get_presentation to reject stale edits. Empty replacement deletes matching text.", revision.merging(["text": string, "replacement": string, "matchCase": boolean, "pageObjectIds": strings]) { _, b in b }, ["fileId", "text", "replacement"], write: true),
            tool("batch_update_presentation", "Apply up to 100 official Slides API Request objects atomically: createSlide, createShape, insertText, deleteText, updateTextStyle, updateShapeProperties, duplicateObject, deleteObject and more. Read object IDs first. Use requiredRevisionId to reject concurrent edits. https://developers.google.com/workspace/slides/api/reference/rest/v1/presentations/request", revision.merging(["requests": requests]) { _, b in b }, ["fileId", "requests"], write: true)
        ]
        return result
    }
}
