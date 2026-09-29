import AppKit
import Domain
import Foundation
import Infrastructure

enum DriveConnectionTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        expect(DriveMCPServer.tools.count == 29, "Drive exposes thirteen file tools and sixteen native editing tools")
        expect(try DriveMCPServer.query("title contains 'owner title' and parentId = 'root' and owner != 'me'") == "name contains 'owner title' and ('root' in parents) and not ('me' in owners)", "Drive translates fields without rewriting quoted content")
        expect((try? DriveMCPServer.query("parentId contains 'root'")) == nil, "Drive rejects unsupported parent operators")
        for id in ["../other", "x?alt=media", "", "a/b"] {
            expect((try? DriveMCPServer.call("get_file_metadata", ["fileId": id]) { _ in throw HarnaisError.notLoggedIn }) == nil, "Drive rejects path injection")
        }
        let list = try DriveMCPServer.call("search_files", ["query": "title = 'Fixture'", "pageSize": 900, "pageToken": "cursor"]) { request in
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            expect(q.contains { $0.name == "pageSize" && $0.value == "100" }, "Drive bounds page size")
            expect(q.contains { $0.name == "q" && $0.value == "trashed = false and (name = 'Fixture')" }, "Drive query excludes trash")
            expect(q.contains { $0.name == "pageToken" && $0.value == "cursor" }, "Drive passes pagination token")
            expect(request.url!.host == "www.googleapis.com", "Drive targets stable Google API")
            return try data(["files": [["id": "fixture", "name": "Fixture"]], "nextPageToken": "next"])
        }
        expect(list["next_page_token"] as? String == "next", "Drive exposes compatible pagination")
        expect((list["files"] as? [[String: Any]])?.first?["title"] as? String == "Fixture", "Drive exposes compatible title")
        var permissionPages = 0
        let permissions = try DriveMCPServer.call("get_file_permissions", ["fileId": "fixture"]) { request in
            permissionPages += 1
            if permissionPages == 1 { return try data(["permissions": [["id": "one"]], "nextPageToken": "page2"]) }
            expect(request.url!.query!.contains("pageToken=page2"), "Drive permission listing follows pagination")
            return try data(["permissions": [["id": "two"]]])
        }
        expect((permissions["permissions"] as? [[String: Any]])?.count == 2, "Drive permission listing keeps later pages")
        var writes: [URLRequest] = []
        _ = try DriveMCPServer.call("create_file", ["title": "Fixture", "textContent": "Hello", "contentMimeType": "text/plain"]) { request in
            writes.append(request)
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            expect(request.url!.path == "/upload/drive/v3/files" && request.httpMethod == "POST", "Drive uploads through multipart endpoint")
            expect(body.replacingOccurrences(of: "\\/", with: "/").contains("application/vnd.google-apps.document") && body.contains("Hello"), "Drive converts eligible content unless disabled")
            return try data(["id": "fixture", "name": "Fixture"])
        }
        expect((try? DriveMCPServer.call("create_file", ["title": "Fixture", "base64Content": "invalid?", "contentMimeType": "text/plain"]) { _ in throw HarnaisError.notLoggedIn }) == nil, "Drive rejects malformed upload")
        _ = try DriveMCPServer.call("copy_file", ["fileId": "fixture", "parentId": "target"]) { request in
            if request.httpMethod == "GET" { return try data(["name": "Original"]) }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            expect(body["name"] as? String == "Copy of Original" && body["parents"] as? [String] == ["target"], "Drive copy preserves title convention and destination")
            return try data(["id": "copy"])
        }
        _ = try DriveMCPServer.call("update_file", ["fileId": "fixture", "parentId": "new", "title": "Renamed"]) { request in
            if request.httpMethod == "GET" { return try data(["parents": ["old"]]) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            expect(request.httpMethod == "PATCH" && query.contains { $0.name == "removeParents" && $0.value == "old" }, "Drive moves using existing parents")
            return try data(["id": "fixture"])
        }
        _ = try DriveMCPServer.call("trash_file", ["fileId": "fixture"]) { request in
            expect(request.httpMethod == "PATCH" && String(decoding: request.httpBody!, as: UTF8.self).contains("true"), "Drive trashes without permanently deleting")
            return try data(["id": "fixture", "trashed": true])
        }
        var shareCalls = 0
        _ = try DriveMCPServer.call("share_file", ["fileId": "fixture", "emailAddress": "test@example.invalid", "role": "reader"]) { request in
            shareCalls += 1
            expect(request.httpMethod == "GET", "Drive never downgrades existing permission")
            return try data(["permissions": [["id": "perm", "emailAddress": "test@example.invalid", "role": "writer"]]])
        }
        expect(shareCalls == 1, "Existing stronger sharing permission makes no write")
        _ = try DriveMCPServer.call("share_file", ["fileId": "fixture", "emailAddress": "test@example.invalid", "role": "writer"]) { request in
            if request.httpMethod == "GET" { return try data(["permissions": [["id": "perm", "emailAddress": "test@example.invalid", "role": "reader"]]]) }
            expect(request.httpMethod == "PATCH" && request.url!.path.hasSuffix("/permissions/perm"), "Drive upgrades existing permission instead of duplicating it")
            return try data(["id": "perm", "role": "writer"])
        }
        let read = try DriveMCPServer.call("read_file_content", ["fileId": "fixture", "includeComments": true]) { request in
            if request.url!.path.hasSuffix("/export") { return Data("Fixture content".utf8) }
            if request.url!.path.hasSuffix("/comments") { return try data(["comments": [["id": "c", "content": "Comment"]]]) }
            return try data(["id": "fixture", "name": "Fixture", "mimeType": "application/vnd.google-apps.document"])
        }
        expect(read["content"] as? String == "Fixture content" && (read["comments"] as? [[String: Any]])?.count == 1, "Drive exports native text and includes requested comments")
        let download = try DriveMCPServer.call("download_file_content", ["fileId": "fixture"]) { request in
            if request.url!.query?.contains("alt=media") == true { return Data([0, 1, 2]) }
            return try data(["mimeType": "application/octet-stream"])
        }
        expect(download["base64Content"] as? String == "AAEC", "Drive preserves binary download bytes")
        let error = DriveMCPServer().handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_file_metadata","arguments":{"fileId":"fixture"}}}"#.utf8)) { _ in throw HarnaisError.notLoggedIn }!
        let response = try JSONSerialization.jsonObject(with: error) as! [String: Any]
        expect((response["result"] as? [String: Any])?["isError"] as? Bool == true, "Drive reports tool failures without a protocol crash")

        let identity = AppIdentity(bundleIdentifier: "test.drive", dataDirectory: root.appendingPathComponent("drive-migration"))
        let service = IntegrationService(identity: identity, homeDirectory: root)
        let connection = IntegrationConnection(kind: .googleDrive, label: "Personal", slug: "personal", mcpName: "drive")
        try service.registry.add(connection)
        var tokens = OAuthTokenSet(clientId: "native-client", tokenEndpoint: "https://oauth2.googleapis.com/token", accessToken: "fixture", resource: "https://drivemcp.googleapis.com/mcp/v1")
        try service.credentials.save(.oauth(tokens), for: connection)
        let migrated = try service.credentials.authorizedTokens(for: connection) { _ in throw HarnaisError.notLoggedIn }
        expect(migrated.resource == nil && migrated.accessToken == "fixture", "Drive migrates only known preview audience without losing consent")
        tokens.resource = "https://other.invalid/mcp"
        try service.credentials.save(.oauth(tokens), for: connection)
        expect((try? service.credentials.authorizedTokens(for: connection) { $0 }) == nil, "Drive refuses unrelated OAuth audience")
        _ = try service.updateSettings(connection, label: "Personal", mcpName: "drive", endpoint: connection.mcpURL.absoluteString, token: "", clientID: "native-client", clientSecret: "", shared: true)
        expect((try? service.credentials.authorizedTokens(for: connection) { $0 }) == nil, "Saving Drive settings cannot bypass OAuth audience validation")
        tokens.resource = nil
        try service.credentials.save(.oauth(tokens), for: connection)
        try service.clients.upsert(kind: .googleDrive, record: OAuthClientRecord(clientId: "native-client", isPublicClient: true, scopes: ["fixture-scope"]))
        _ = try service.updateSettings(connection, label: "Personal", mcpName: "drive", endpoint: connection.mcpURL.absoluteString, token: "", clientID: "native-client", clientSecret: "", shared: true)
        expect(try service.credentials.load(for: connection).oauth?.resource == nil, "Saving stable API settings does not introduce an OAuth resource parameter")
        let client = try service.clients.record(for: .googleDrive)
        expect(client?.isPublicClient == true && client?.scopes == ["fixture-scope"], "Manage save preserves native client type and custom scopes")
    }
}

// Exercise lifecycle mutations only in disposable profiles, never real registrations.
