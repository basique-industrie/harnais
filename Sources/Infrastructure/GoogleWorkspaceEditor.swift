import CoreFoundation
import Domain
import Foundation

/// Native editing APIs accept the existing Drive scopes; Google still enforces per-file access.
enum GoogleWorkspaceEditor {
    static func call(_ name: String, _ args: [String: Any], send: (URLRequest) throws -> Data) throws -> [String: Any] {
        func fail(_ message: String) -> HarnaisError { .processFailed(message) }
        func text(_ key: String, empty: Bool = false) throws -> String {
            guard let value = args[key] as? String, (empty || !value.isEmpty), value.utf8.count <= 1_000_000 else { throw fail("Provide a valid \(key).") }
            return value
        }
        func strings(_ key: String) throws -> [String] {
            guard let values = args[key] as? [String], !values.isEmpty, values.count <= 100,
                  values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 }) else { throw fail("Provide 1 to 100 nonempty strings in \(key).") }
            return values
        }
        func option(_ key: String, _ fallback: String, _ choices: [String]) throws -> String {
            guard args[key] == nil || args[key] is String else { throw fail("Invalid \(key).") }
            let value = args[key] as? String ?? fallback
            guard choices.contains(value) else { throw fail("Invalid \(key): choose \(choices.joined(separator: ", ")).") }
            return value
        }
        func flag(_ key: String, default fallback: Bool) throws -> Bool {
            guard let value = args[key] else { return fallback }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw fail("\(key) must be a boolean.") }
            return number.boolValue
        }
        func matrix(_ value: Any?) throws -> [[Any]] {
            guard let rows = value as? [[Any]], !rows.isEmpty, rows.count <= 50_000,
                  rows.reduce(0, { $0 + $1.count }) <= 100_000,
                  rows.joined().allSatisfy({ $0 is String || $0 is NSNumber || $0 is NSNull }) else { throw fail("Provide a matrix of at most 100,000 string, number, boolean or null cells.") }
            return rows
        }
        func requests() throws -> [[String: Any]] {
            guard let values = args["requests"] as? [[String: Any]], !values.isEmpty, values.count <= 100,
                  values.allSatisfy({ $0.count == 1 && $0.values.first is [String: Any] }) else { throw fail("Provide 1 to 100 Google API request objects, each with one operation.") }
            return values
        }
        func control(_ body: [String: Any]) throws -> [String: Any] {
            var body = body
            if args["requiredRevisionId"] != nil { body["writeControl"] = ["requiredRevisionId": try text("requiredRevisionId")] }
            return body
        }
        func perform(_ host: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) throws -> [String: Any] {
            var url = URLComponents(); url.scheme = "https"; url.host = host; url.path = path; url.queryItems = query.isEmpty ? nil : query
            guard let url = url.url else { throw fail("Invalid Google API request.") }
            var request = URLRequest(url: url)
            if let body {
                request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
                guard request.httpBody!.count <= 8 * 1024 * 1024 else { throw fail("Editing request exceeds 8 MB. Split it into smaller batches.") }
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            guard let result = try JSONSerialization.jsonObject(with: send(request)) as? [String: Any] else { throw fail("Invalid Google API response.") }
            return result
        }
        if ["create_spreadsheet", "create_document", "create_presentation"].contains(name) {
            var fields: [String: Any] = ["title": try text("title"), "mimeType": "application/vnd.google-apps." + name.dropFirst("create_".count)]
            if let parent = args["parentId"] { fields["parentId"] = try DriveMCPServer.identifier(parent) }
            return try DriveMCPServer.call("create_file", fields, send: send)
        }
        let id = try DriveMCPServer.identifier(args["fileId"])
        let sheets = "sheets.googleapis.com", sheetPath = "/v4/spreadsheets/" + id
        let docs = "docs.googleapis.com", docPath = "/v1/documents/" + id
        let slides = "slides.googleapis.com", slidePath = "/v1/presentations/" + id
        switch name {
        case "get_spreadsheet":
            var q = [URLQueryItem(name: "includeGridData", value: try flag("includeGridData", default: false) ? "true" : "false")]
            if args["ranges"] != nil { q += try strings("ranges").map { URLQueryItem(name: "ranges", value: $0) } }
            return try perform(sheets, sheetPath, query: q)
        case "read_spreadsheet_values":
            let q = try strings("ranges").map { URLQueryItem(name: "ranges", value: $0) } + [URLQueryItem(name: "valueRenderOption", value: try option("valueRenderOption", "FORMATTED_VALUE", ["FORMATTED_VALUE", "UNFORMATTED_VALUE", "FORMULA"]))]
            return try perform(sheets, sheetPath + "/values:batchGet", query: q)
        case "update_spreadsheet_values":
            guard let data = args["data"] as? [[String: Any]], !data.isEmpty, data.count <= 100 else { throw fail("Provide 1 to 100 range/value objects in data.") }
            var values: [[String: Any]] = []
            for entry in data {
                guard let range = entry["range"] as? String, !range.isEmpty, range.count <= 8192,
                      Set(entry.keys).isSubset(of: ["range", "values", "majorDimension"]) else { throw fail("Each data entry needs range and values, with optional majorDimension.") }
                var item: [String: Any] = ["range": range, "values": try matrix(entry["values"])]
                if let dimension = entry["majorDimension"] {
                    guard let dimension = dimension as? String, ["ROWS", "COLUMNS"].contains(dimension) else { throw fail("majorDimension must be ROWS or COLUMNS.") }
                    item["majorDimension"] = dimension
                }
                values.append(item)
            }
            return try perform(sheets, sheetPath + "/values:batchUpdate", body: ["data": values, "valueInputOption": try option("valueInputOption", "RAW", ["RAW", "USER_ENTERED"]), "includeValuesInResponse": true])
        case "append_spreadsheet_values":
            let range = try text("range")
            // URLComponents encodes ? and # in ranges; slashes are encoded as a single path segment.
            var url = URLComponents(); url.path = range
            let encoded = url.percentEncodedPath.replacingOccurrences(of: "/", with: "%2F")
            var target = URLComponents(string: "https://\(sheets)\(sheetPath)/values/")!
            target.percentEncodedPath += encoded + ":append"
            target.queryItems = [URLQueryItem(name: "valueInputOption", value: try option("valueInputOption", "RAW", ["RAW", "USER_ENTERED"])), URLQueryItem(name: "insertDataOption", value: "INSERT_ROWS"), URLQueryItem(name: "includeValuesInResponse", value: "true")]
            var request = URLRequest(url: target.url!); request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["range": range, "majorDimension": "ROWS", "values": try matrix(args["values"])])
            guard request.httpBody!.count <= 8 * 1024 * 1024 else { throw fail("Editing request exceeds 8 MB.") }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let result = try JSONSerialization.jsonObject(with: send(request)) as? [String: Any] else { throw fail("Invalid Google API response.") }
            return result
        case "clear_spreadsheet_values": return try perform(sheets, sheetPath + "/values:batchClear", body: ["ranges": try strings("ranges")])
        case "batch_update_spreadsheet": return try perform(sheets, sheetPath + ":batchUpdate", body: ["requests": try requests()])
        case "copy_worksheet":
            guard let number = args["sheetId"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0,
                  number.doubleValue <= Double(Int32.max), number.doubleValue.rounded() == number.doubleValue else { throw fail("sheetId must be a nonnegative integer.") }
            return try perform(sheets, sheetPath + "/sheets/\(number.intValue):copyTo", body: ["destinationSpreadsheetId": try DriveMCPServer.identifier(args["destinationSpreadsheetId"])])
        case "get_document": return try perform(docs, docPath, query: [URLQueryItem(name: "includeTabsContent", value: "true")])
        case "get_presentation": return try perform(slides, slidePath)
        case "replace_document_text", "replace_presentation_text":
            var replacement: [String: Any] = ["containsText": ["text": try text("text"), "matchCase": try flag("matchCase", default: true)], "replaceText": try text("replacement", empty: true)]
            if name == "replace_document_text", args["tabIds"] != nil { replacement["tabsCriteria"] = ["tabIds": try strings("tabIds")] }
            if name == "replace_presentation_text", args["pageObjectIds"] != nil { replacement["pageObjectIds"] = try strings("pageObjectIds") }
            return try perform(name == "replace_document_text" ? docs : slides, (name == "replace_document_text" ? docPath : slidePath) + ":batchUpdate", body: control(["requests": [["replaceAllText": replacement]]]))
        case "batch_update_document": return try perform(docs, docPath + ":batchUpdate", body: control(["requests": try requests()]))
        case "batch_update_presentation": return try perform(slides, slidePath + ":batchUpdate", body: control(["requests": try requests()]))
        default: throw fail("Unknown Google Workspace editing tool.")
        }
    }
}
