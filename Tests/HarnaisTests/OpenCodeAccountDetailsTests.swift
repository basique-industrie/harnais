import AppKit
import Domain
import Foundation
import Infrastructure

enum OpenCodeAccountDetailsTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        func parse(_ value: String) -> [ConnectedAccount] { OpenCodeAccountReader.parse(Data(value.utf8)) }
        let api = parse(#"{"opencode":{"type":"api","key":"private-fixture"}}"#)
        expect(api.count == 1 && api[0].providerName == "OpenCode Zen" && api[0].loginMethod == "API key", "OpenCode API login identifies provider and method")
        expect(api[0].email == nil && api[0].plan == nil, "API keys do not invent email or subscription metadata")
        expect(api[0].accountURL?.absoluteString == "https://opencode.ai/console/", "OpenCode login links to account console")
        expect(!String(describing: api).contains("private-fixture"), "display metadata never contains the credential")
        let claims: [String: Any] = [
            "https://api.openai.com/profile": ["email": "test@example.com"],
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"],
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let oauth = parse("{\"openai\":{\"type\":\"oauth\",\"access\":\"e30.\(payload).sig\"}}")
        expect(oauth.first?.email == "test@example.com" && oauth.first?.plan == "ChatGPT Plus", "OpenCode OAuth reads email and plan claims")
        expect(oauth.first?.loginMethod == "OAuth", "OpenCode OAuth method is distinct from API key")
        expect(parse(#"{"opencode":{"type":"api","key":""},"openai":{"type":"oauth","email":"stale@example.com"}}"#).isEmpty, "metadata without credentials is not a connected account")
        let mixed = parse(#"{"broken":null,"anthropic":{"type":"api","key":"fixture"},"opencode":{"type":"api","key":"fixture"}}"#)
        expect(mixed.map(\.id) == ["anthropic", "opencode"], "malformed entry does not hide valid OpenCode logins")
        expect(parse("not json").isEmpty, "invalid OpenCode auth file is handled")
        let custom = parse(#"{"custom-service":{"type":"api","key":"fixture"}}"#)
        expect(custom.first?.providerName == "custom-service" && custom.first?.accountURL == nil, "custom provider remains identifiable without a guessed URL")

        let home = root.appendingPathComponent("open-code-details")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let account = Account(provider: .opencode, label: "Personal", slug: "personal", homePath: home.path)
        let auth = home.appendingPathComponent("auth.json")
        try Data(#"{"opencode":{"type":"api","key":"fixture"}}"#.utf8).write(to: auth)
        let snapshot = ConnectionProbe().snapshot(account)
        expect(snapshot.connectedAccounts.count == 1 && snapshot.authLabel == "API key", "OpenCode account details are available on first paint")
        try Data(#"{"openai":{"type":"oauth","refresh":"fixture","email":"one@example.com"},"anthropic":{"type":"oauth","refresh":"fixture","email":"two@example.com"}}"#.utf8).write(to: auth)
        expect(AccountMetadata().email(for: account) == nil, "multiple OpenCode logins do not get assigned one provider's email")
        expect(AccountMetadata().planLabel(for: account) == "2 providers", "multiple OpenCode logins have a count summary")
    }
}
