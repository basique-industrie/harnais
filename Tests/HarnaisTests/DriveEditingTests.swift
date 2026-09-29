import Domain
import Foundation
import Infrastructure

enum DriveEditingTests {
    static func run(expect: (Bool, String) -> Void) throws {
        func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func body(_ request: URLRequest) throws -> [String: Any] { try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any] }
        let tools = DriveMCPServer.tools
        expect(Set(tools.compactMap { $0["name"] as? String }).count == tools.count, "Drive tool names are unique")
        for tool in tools where ["replace_file_content", "update_spreadsheet_values", "append_spreadsheet_values", "clear_spreadsheet_values", "batch_update_spreadsheet", "copy_worksheet", "replace_document_text", "batch_update_document", "replace_presentation_text", "batch_update_presentation"].contains(tool["name"] as! String) {
            let flags = tool["annotations"] as! [String: Any]
            expect(flags["readOnlyHint"] as? Bool == false && flags["destructiveHint"] as? Bool == true, "Editing tools declare write effects")
        }
        for url in ["http://www.googleapis.com/drive/v3/files/x", "https://www.googleapis.com.evil.invalid/drive/v3/files/x", "https://www.googleapis.com/drive/v3/filesEvil/x", "https://evil.invalid/v4/spreadsheets/x", "https://sheets.googleapis.com/v4/spreadsheetsEvil/x", "https://docs.googleapis.com@evil.invalid/v1/documents/x", "https://www.googleapis.com:444/drive/v3/files/x", "https://www.googleapis.com/drive/v3/files/x#fragment"] {
            expect(!GoogleWorkspaceTransport.isAllowed(URL(string: url)!), "Google credential destination rejects foreign or malformed endpoints")
        }
        let meta: [String: Any] = ["id": "workbook", "name": "Budget.xlsx", "mimeType": DriveContentReader.xlsx, "version": "10", "parents": ["folder"], "webViewLink": "https://drive.google.com/file/d/workbook/view", "capabilities": ["canEdit": true]]
        let bytes = Data([0x50, 0x4b, 3, 4, 0, 255, 128])
        var calls = 0
        let result = try DriveMCPServer.call("replace_file_content", ["fileId": "workbook", "base64Content": bytes.base64EncodedString(), "expectedVersion": "10"]) { request in
            calls += 1
            if request.httpMethod == "GET" { return try json(meta) }
            expect(request.httpMethod == "PATCH" && request.url?.path == "/upload/drive/v3/files/workbook", "Replacement updates the original file ID")
            expect(request.httpBody == bytes, "Replacement preserves every binary byte")
            expect(request.value(forHTTPHeaderField: "Content-Type") == DriveContentReader.xlsx, "Replacement keeps the existing Office MIME type")
            expect(request.url!.query!.contains("uploadType=media") && request.url!.query!.contains("supportsAllDrives=true"), "Replacement uses media update and supports shared drives")
            return try json(meta)
        }
        expect(calls == 2 && result["id"] as? String == "workbook" && result["webViewLink"] as? String == meta["webViewLink"] as? String, "Replacement returns the same ID and link without create/copy calls")
        let local = try DriveMCPServer.call("download_file_to_path", ["fileId": "workbook"]) { request in
            request.url?.query?.contains("alt=media") == true ? bytes : try json(meta)
        }
        let localFile = URL(fileURLWithPath: local["localPath"] as! String)
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        expect(try Data(contentsOf: localFile) == bytes && localFile.pathExtension == "xlsx", "Local workbook download preserves bytes and extension")
        expect(local["base64Content"] == nil && local["version"] as? String == "10", "Local download returns version without binary context overhead")
        expect((try FileManager.default.attributesOfItem(atPath: localFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Downloaded working files are private")
        _ = try DriveMCPServer.call("replace_file_content", ["fileId": "workbook", "localPath": localFile.path]) { request in
            if request.httpMethod != "GET" { expect(request.httpBody == bytes, "Local replacement uploads exact edited bytes") }
            return try json(meta)
        }
        let link = localFile.deletingLastPathComponent().appendingPathComponent("link.xlsx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: localFile)
        for path in ["relative.xlsx", link.path, localFile.deletingLastPathComponent().path] {
            var wrote = false
            let attempt = try? DriveMCPServer.call("replace_file_content", ["fileId": "workbook", "localPath": path]) { request in
                wrote = wrote || request.httpMethod != "GET"; return try json(meta)
            }
            expect(attempt == nil && !wrote, "Local replacement rejects relative paths, symlinks and directories")
        }
        for patch: [String: Any] in [[:], ["textContent": "bad"], ["base64Content": "not base64!"], ["base64Content": "AA==", "textContent": "both"], ["base64Content": "AA==", "contentMimeType": "text/plain"], ["base64Content": "AA==", "expectedVersion": "9"], ["base64Content": "AA==", "contentMimeType": "text/plain\r\nX-Header: injected"]] {
            var wrote = false
            let attempt = try? DriveMCPServer.call("replace_file_content", patch.merging(["fileId": "workbook"]) { a, _ in a }) { request in
                wrote = wrote || request.httpMethod != "GET"; return try json(meta)
            }
            expect(attempt == nil && !wrote, "Invalid or stale replacement fails before any upload")
        }
        for change: [String: Any] in [["mimeType": "application/vnd.google-apps.spreadsheet"], ["mimeType": "application/vnd.google-apps.folder"], ["mimeType": "application/vnd.google-apps.shortcut"], ["capabilities": ["canEdit": false]], ["trashed": true]] {
            var wrote = false
            let attempt = try? DriveMCPServer.call("replace_file_content", ["fileId": "workbook", "base64Content": "AA=="]) { request in
                wrote = wrote || request.httpMethod != "GET"; return try json(meta.merging(change) { _, b in b })
            }
            expect(attempt == nil && !wrote, "Native, trashed and uneditable files cannot receive binary replacements")
        }
        let large = Data(repeating: 83, count: 6 * 1024 * 1024)
        var stage = 0
        _ = try DriveMCPServer.call("replace_file_content", ["fileId": "workbook", "base64Content": large.base64EncodedString()]) { request in
            stage += 1
            if stage == 1 { return try json(meta) }
            if stage == 2 {
                expect(request.httpMethod == "PATCH" && request.url!.query!.contains("uploadType=resumable"), "Large replacement starts a resumable update")
                expect(request.httpBody == nil && request.value(forHTTPHeaderField: "X-Upload-Content-Length") == String(large.count), "Resumable setup declares length without uploading data twice")
                return try json(["uploadURL": "https://www.googleapis.com/upload/drive/v3/files/workbook?uploadType=resumable&upload_id=fixture"])
            }
            expect(request.httpMethod == "PUT" && request.httpBody == large, "Resumable upload sends exact bytes to the session")
            return try json(meta)
        }
        expect(stage == 3, "Large replacement uses one session and one upload")
        for location in ["https://evil.invalid/upload", "https://www.googleapis.com/upload/drive/v3/files/other?upload_id=x", "https://www.googleapis.com/upload/drive/v3/files/workbook"] {
            var writes = 0
            let attempt = try? DriveMCPServer.call("replace_file_content", ["fileId": "workbook", "base64Content": large.base64EncodedString()]) { request in
                if request.httpMethod == "GET" { return try json(meta) }
                writes += 1; return try json(["uploadURL": location])
            }
            expect(attempt == nil && writes == 1, "Upload session cannot redirect content to another file or host")
        }
        var oversizedWrites = 0
        let oversized = try? DriveMCPServer.call("replace_file_content", ["fileId": "workbook", "base64Content": Data(repeating: 0, count: 16 * 1024 * 1024 + 1).base64EncodedString()]) { request in
            if request.httpMethod != "GET" { oversizedWrites += 1 }; return try json(meta)
        }
        expect(oversized == nil && oversizedWrites == 0, "Replacement size limit fails before writing")

        for kind in ["spreadsheet", "document", "presentation"] {
            _ = try DriveMCPServer.call("create_" + kind, ["title": "Fixture", "parentId": "folder"]) { request in
                let payload = try body(request)
                expect(request.httpMethod == "POST" && request.url?.path == "/drive/v3/files", "Native creation uses the shared Drive app")
                expect(payload["mimeType"] as? String == "application/vnd.google-apps." + kind && payload["parents"] as? [String] == ["folder"], "Native creation preserves file type and folder")
                return try json(["id": "native"])
            }
        }
        _ = try DriveMCPServer.call("get_spreadsheet", ["fileId": "book", "ranges": ["'Profit & Loss'!A1:C3"], "includeGridData": true]) { request in
            expect(request.url?.host == "sheets.googleapis.com" && request.httpMethod == "GET", "Workbook inspection uses Sheets")
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            expect(q.contains { $0.name == "includeGridData" && $0.value == "true" }, "Workbook inspection can include formatting")
            return try json([:])
        }
        let ranges = ["'Profit & Loss'!A1:C3", "'Notes #1'!B2"]
        _ = try DriveMCPServer.call("read_spreadsheet_values", ["fileId": "book", "ranges": ranges, "valueRenderOption": "FORMULA"]) { request in
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            expect(q.filter { $0.name == "ranges" }.compactMap(\.value) == ranges, "Multi-range reads preserve encoded worksheet names")
            expect(q.contains { $0.name == "valueRenderOption" && $0.value == "FORMULA" }, "Formula reads keep formula mode")
            return try json([:])
        }
        for mode in [nil, "USER_ENTERED"] as [String?] {
            var args: [String: Any] = ["fileId": "book", "data": [["range": "Sheet1!A1:C2", "values": [["=SUM(B1:C1)", 2, 3], [NSNull(), "", true]]]]]
            if let mode { args["valueInputOption"] = mode }
            _ = try DriveMCPServer.call("update_spreadsheet_values", args) { request in
                let payload = try body(request)
                expect(payload["valueInputOption"] as? String == (mode ?? "RAW"), "Cell writes require explicit formula interpretation")
                let data = payload["data"] as! [[String: Any]], values = data[0]["values"] as! [[Any]]
                expect(values[1][0] is NSNull && values[1][1] as? String == "", "Cell writes distinguish skipped cells from cleared cells")
                expect(request.url?.path == "/v4/spreadsheets/book/values:batchUpdate", "Cell updates target only selected ranges")
                return try json(["totalUpdatedCells": 5])
            }
        }
        _ = try DriveMCPServer.call("append_spreadsheet_values", ["fileId": "book", "range": "'A/B?#'!A1", "values": [[1]]]) { request in
            expect(request.url?.host == "sheets.googleapis.com" && request.url!.absoluteString.contains("%2F"), "Append encodes range path separators")
            expect(request.url!.fragment == nil && request.url!.query!.contains("insertDataOption=INSERT_ROWS"), "Append ranges cannot inject URL query or fragment")
            return try json([:])
        }
        _ = try DriveMCPServer.call("clear_spreadsheet_values", ["fileId": "book", "ranges": ["Sheet1!A1"]]) { request in
            expect(try body(request)["ranges"] as? [String] == ["Sheet1!A1"], "Clear targets explicit ranges without deleting worksheet metadata")
            return try json([:])
        }
        _ = try DriveMCPServer.call("copy_worksheet", ["fileId": "book", "sheetId": 12, "destinationSpreadsheetId": "destination"]) { request in
            expect(request.url?.path == "/v4/spreadsheets/book/sheets/12:copyTo", "Worksheet copy uses the numeric sheet ID")
            expect(try body(request)["destinationSpreadsheetId"] as? String == "destination", "Worksheet copy uses explicit destination")
            return try json([:])
        }
        for (name, host, path) in [("get_document", "docs.googleapis.com", "/v1/documents/doc"), ("get_presentation", "slides.googleapis.com", "/v1/presentations/doc")] {
            _ = try DriveMCPServer.call(name, ["fileId": "doc"]) { request in
                expect(request.url?.host == host && request.url?.path == path && request.httpMethod == "GET", "Native reads target the correct document API")
                if name == "get_document" { expect(request.url!.query == "includeTabsContent=true", "Docs reads include all tabs") }
                return try json(["revisionId": "revision"])
            }
        }
        for kind in ["document", "presentation"] {
            let scope = kind == "document" ? "tabIds" : "pageObjectIds"
            _ = try DriveMCPServer.call("replace_" + kind + "_text", ["fileId": "doc", "text": "Old", "replacement": "", "requiredRevisionId": "revision", scope: ["tab1"]]) { request in
                let payload = try body(request), operation = (payload["requests"] as! [[String: Any]])[0]["replaceAllText"] as! [String: Any]
                expect((payload["writeControl"] as? [String: String])?["requiredRevisionId"] == "revision", "Native text replacement can reject stale revisions")
                expect(operation["replaceText"] as? String == "" && (operation["containsText"] as! [String: Any])["matchCase"] as? Bool == true, "Text replacement supports deletion and defaults to literal case-sensitive matching")
                expect(kind == "document" ? (operation["tabsCriteria"] as? [String: [String]])?["tabIds"] == ["tab1"] : operation["pageObjectIds"] as? [String] == ["tab1"], "Text replacement keeps explicit tab or slide scope")
                return try json([:])
            }
        }
        for kind in ["spreadsheet", "document", "presentation"] {
            _ = try DriveMCPServer.call("batch_update_" + kind, ["fileId": "doc", "requests": [["operation": ["field": "value"]]]]) { request in
                expect(request.httpMethod == "POST" && request.url!.path.hasSuffix(":batchUpdate"), "Structural edits use native atomic batch update")
                expect((try body(request)["requests"] as? [[String: Any]])?.count == 1, "Structural edits preserve operation order")
                return try json([:])
            }
        }
        let bad: [(String, [String: Any])] = [
            ("get_document", ["fileId": "../invalid"]), ("read_spreadsheet_values", ["ranges": []]),
            ("read_spreadsheet_values", ["ranges": ["A1"], "valueRenderOption": "INVALID"]),
            ("get_spreadsheet", ["includeGridData": "true"]), ("copy_worksheet", ["sheetId": true, "destinationSpreadsheetId": "book"]),
            ("copy_worksheet", ["sheetId": -1, "destinationSpreadsheetId": "book"]),
            ("batch_update_document", ["requests": []]), ("batch_update_presentation", ["requests": [["a": [:], "b": [:]]]]),
            ("batch_update_spreadsheet", ["requests": Array(repeating: ["operation": [:]], count: 101)]),
            ("update_spreadsheet_values", ["data": [["range": "A1", "values": [[[:]]]]]]),
            ("update_spreadsheet_values", ["data": [["range": "A1", "values": [[1]], "majorDimension": "bad"]]]),
            ("replace_document_text", ["text": "", "replacement": "x"])
        ]
        for (name, args) in bad {
            var called = false
            let attempt = try? DriveMCPServer.call(name, ["fileId": "book"].merging(args) { _, b in b }) { _ in called = true; return try json([:]) }
            expect(attempt == nil && !called, "Malformed native edit fails before contacting Google")
        }
    }
}
