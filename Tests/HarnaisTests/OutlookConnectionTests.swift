import AppKit
import Domain
import Foundation
import Infrastructure

enum OutlookConnectionTests {
    static func run(expect: (Bool, String) -> Void) throws {
        let gmailURL = try GmailAPI.requestURL(tool: "gmail_list_messages", arguments: ["limit": 999, "query": "from:example@example.com", "pageToken": "next&other=value"])
        let gmailQuery = URLComponents(url: gmailURL, resolvingAgainstBaseURL: false)!.queryItems!
        expect(gmailURL.host == "gmail.googleapis.com" && gmailURL.path == "/gmail/v1/users/me/messages", "Gmail requests stay in the authenticated mailbox")
        expect(gmailQuery.contains { $0.name == "maxResults" && $0.value == "50" }, "Gmail listing is bounded")
        expect(gmailQuery.contains { $0.name == "pageToken" && $0.value == "next&other=value" }, "Gmail pagination cannot inject query parameters")
        expect((try? GmailAPI.requestURL(tool: "gmail_get_message", arguments: ["id": "../../other/messages"])) == nil, "Gmail rejects path traversal")
        expect((try? GmailAPI.requestURL(tool: "gmail_send_message", arguments: [:])) == nil, "Gmail adapter has no mail sending operation")
        let payload = Data(#"{"payload":{"mimeType":"multipart/alternative","parts":[{"mimeType":"text/plain","body":{"data":"SGVsbG8"}}]}}"#.utf8)
        let readable = try JSONSerialization.jsonObject(with: GmailAPI.readableMessage(payload)) as! [String: Any]
        expect(readable["textBody"] as? String == "Hello", "Gmail decodes nested base64url plain text")
        let gmailServer = MailMCPServer(service: .gmail)
        let gmailList = gmailServer.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)) { _ in
            throw HarnaisError.processFailed("Inventory must not read mail")
        }!
        let gmailResult = try JSONSerialization.jsonObject(with: gmailList) as! [String: Any]
        let gmailTools = (gmailResult["result"] as! [String: Any])["tools"] as! [[String: Any]]
        expect(gmailTools.count == 3 && gmailTools.allSatisfy { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true }, "Gmail advertises only supported read-only tools")
        let catalog = try OfficialOAuthClients.decode(Data(#"{"outlook":{"clientId":"outlook-native-fixture","isPublicClient":true}}"#.utf8))
        expect(catalog["outlook"]?.isPublicClient == true && catalog["outlook"]?.clientSecret == nil, "Outlook public desktop registration decodes without a secret")
        if let outlook = try OfficialOAuthClients.record(for: .outlook) {
            expect(outlook.isPublicClient == true && outlook.clientSecret == nil && !outlook.clientId.isEmpty, "injected Outlook registration is a public desktop client without a secret")
        }
        expect(try OfficialOAuthClients.record(for: .gmail) == OfficialOAuthClients.record(for: .googleDrive), "Gmail and Drive share one Google product registration")
        expect(IntegrationKind.gmail.defaultScopes.contains("https://www.googleapis.com/auth/gmail.readonly"), "Gmail uses read-only mail scope")
        expect(!IntegrationKind.outlook.defaultScopes.contains { $0.contains("Write") || $0.contains("Send") }, "Outlook grants no mail mutation scopes")
        let url = try MailMCPServer.requestURL(tool: "outlook_list_messages", arguments: ["query": "subject:invoice", "limit": 900])
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        expect(url.host == "graph.microsoft.com" && query.contains { $0.name == "$top" && $0.value == "50" }, "Outlook list is bounded and fixed to Graph")
        for unsafe in ["https://evil.example/v1.0/me/messages", "https://graph.microsoft.com/v1.0/users/other/messages", "http://graph.microsoft.com/v1.0/me/messages", "https://user@graph.microsoft.com/v1.0/me/messages"] {
            expect((try? MailMCPServer.requestURL(tool: "outlook_list_messages", arguments: ["nextPage": unsafe])) == nil, "reject foreign or cross-user pagination")
        }
        for id in ["../users/other", "a/b", "a?x=1", ""] {
            expect((try? MailMCPServer.requestURL(tool: "outlook_get_message", arguments: ["id": id])) == nil, "reject message path injection")
        }
        let server = MailMCPServer()
        let list = server.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)) { _ in fatalError("Tool inventory must not access mail") }!
        let object = try JSONSerialization.jsonObject(with: list) as! [String: Any]
        expect(((object["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count == 2, "Outlook exposes list/search and read tools")
        let read = server.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"outlook_get_message","arguments":{"id":"AAMk_test="}}}"#.utf8)) { requested in
            expect(requested.path == "/v1.0/me/messages/AAMk_test=", "read addresses only signed-in mailbox")
            return Data(#"{"subject":"Fixture"}"#.utf8)
        }!
        expect(String(data: read, encoding: .utf8)!.contains("Fixture"), "Outlook tool returns requested response")
        let cancel = OAuthCancellation()
        let listener = OAuthCallbackServer()
        cancel.install { listener.cancel() }
        cancel.cancel()
        do { _ = try listener.waitForCode(timeout: 0.1); expect(false, "cancel unblocks browser wait") }
        catch { expect(error.localizedDescription.contains("cancelled"), "cancel unblocks browser wait") }
        do { try cancel.check(); expect(false, "cancel prevents authorization commit") }
        catch { expect(true, "cancel prevents authorization commit") }
    }
}
