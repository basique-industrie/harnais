import AppKit
import Domain
import Foundation
import Infrastructure

enum RegistrationOwnershipTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let official = try OfficialOAuthClients.record(for: .googleDrive)
        let fixture = try OfficialOAuthClients.decode(Data(#"{"google-drive":{"clientId":"native-test-client","clientSecret":"installed-app-fixture","isPublicClient":true}}"#.utf8))
        expect(fixture["google-drive"]?.isPublicClient == true, "native Google product registration decodes")
        if let official {
            expect(official.isPublicClient == true && !official.clientId.isEmpty, "injected Google native product registration loads")
        }
        let old = try JSONDecoder().decode(OAuthClientRecord.self, from: Data(#"{"clientId":"old","clientSecret":"secret"}"#.utf8))
        expect(old.isPublicClient == nil, "legacy custom clients retain confidential behavior")
        do {
            _ = try OfficialOAuthClients.decode(Data(#"{"slack":{"clientId":"bad","clientSecret":"confidential","isPublicClient":true}}"#.utf8))
            expect(false, "reject confidential Slack secret in product catalog")
        } catch { expect(true, "reject confidential Slack secret in product catalog") }
        do {
            _ = try OfficialOAuthClients.decode(Data(#"{"google-drive":{"clientId":"web","clientSecret":"secret"}}"#.utf8))
            expect(false, "reject unclassified Google web client in product catalog")
        } catch { expect(true, "reject unclassified Google web client in product catalog") }
        let base = root.appendingPathComponent("registration-ownership")
        let service = IntegrationService(identity: AppIdentity(dataDirectory: base), homeDirectory: base)
        try service.saveOAuthClientRegistration(kind: .slack, scope: .personal, clientID: "personal-client", clientSecret: "personal-secret")
        try service.saveOAuthClientRegistration(kind: .slack, scope: .work, clientID: "work-client", clientSecret: "work-secret")
        expect(try service.clients.record(for: .slack, scope: .personal)?.clientId == "personal-client", "personal OAuth registration is independent")
        expect(try service.clients.record(for: .slack, scope: .work)?.clientSecret == "work-secret", "work OAuth registration has own secret")
        expect(try service.clients.record(for: .slack) == nil, "scoped registrations never overwrite legacy client")
        try service.saveOAuthClientRegistration(kind: .slack, scope: .work, clientID: "work-client", clientSecret: "")
        expect(try service.clients.record(for: .slack, scope: .work)?.clientSecret == "work-secret", "blank secret preserves same client only")
        do { try service.saveOAuthClientRegistration(kind: .slack, scope: .work, clientID: "different-client", clientSecret: ""); expect(false, "different app requires new secret") }
        catch { expect(true, "different app requires new secret") }
        try service.clients.upsert(kind: .googleDrive, record: OAuthClientRecord(clientId: "foreign-app", clientSecret: "foreign-secret"))
        if let official {
            expect(try service.resolveOAuthClient(kind: .googleDrive, mode: .harnais) == official, "official client ignores local imported app credentials")
        } else {
            do {
                _ = try service.resolveOAuthClient(kind: .googleDrive, mode: .harnais)
                expect(false, "source-only builds require an explicit custom registration")
            } catch {
                expect(true, "source-only builds do not adopt unrelated local credentials")
            }
        }
        expect(try service.resolveOAuthClient(kind: .slack, mode: .custom, registrationScope: .work)?.clientId == "work-client", "advanced mode resolves custom registration")
        let native = OAuthClientRecord(clientId: "native-work", isPublicClient: true, scopes: ["search:read.public", "chat:write"])
        try service.clients.upsert(kind: .slack, scope: .work, record: native)
        try service.saveOAuthClientRegistration(kind: .slack, scope: .work, clientID: "native-work", clientSecret: "")
        expect(try service.clients.record(for: .slack, scope: .work) == native, "saving native registration preserves public-client flag and scopes")
        let connection = IntegrationConnection(kind: .slack, label: "Work", slug: "work", mcpName: "slack")
        try service.credentials.save(.oauth(OAuthTokenSet(clientId: "native-work", accessToken: "fixture", scope: "search:read.public")), for: connection)
        expect(try service.reconnectClient(for: connection) == native, "reconnect preserves native client and updated custom scopes")
        try service.clients.upsert(kind: .slack, scope: .work, record: OAuthClientRecord(clientId: "unrelated", clientSecret: "foreign"))
        let retained = try service.reconnectClient(for: connection)
        expect(retained?.clientId == "native-work" && retained?.clientSecret == nil && retained?.scopes == ["search:read.public"], "reconnect never swaps app identity when saved registration changes")
        let workManifest = try JSONSerialization.jsonObject(with: Data(IntegrationKind.slack.slackAppManifest(scope: .work)!.utf8)) as! [String: Any]
        expect((workManifest["display_information"] as? [String: String])?["name"] == "Harnais Work", "manifest names correct registration owner")
        let oauth = workManifest["oauth_config"] as! [String: Any]
        expect(oauth["redirect_urls"] as? [String] == [IntegrationOAuth.redirectURI], "manifest callback matches runtime")
        let scopes = (oauth["scopes"] as! [String: [String]])["user"]!
        expect(scopes == IntegrationKind.slack.defaultScopes && !scopes.contains { $0.contains("write") }, "Slack starter app and runtime use same read permissions")
        expect(!IntegrationKind.googleDrive.defaultScopes.contains("https://www.googleapis.com/auth/drive"), "Drive does not request full-drive permission")
        expect(OAuthResource.contains(endpoint: IntegrationKind.slack.mcpURL, resource: "https://mcp.slack.com"), "Slack canonical root resource accepted")
        expect(!OAuthResource.contains(endpoint: URL(string: "https://example.com/mcp-other")!, resource: "https://example.com/mcp"), "resource path boundary checked")
        expect(!OAuthResource.contains(endpoint: IntegrationKind.slack.mcpURL, resource: "https://evil.example"), "foreign token audience rejected")
        let claude = Account(provider: .claude, label: "Work", slug: "work", homePath: base.path)
        let codex = Account(provider: .codex, label: "Work", slug: "work", homePath: base.path)
        let plugin = InventoryEntry(name: "slack@official", kind: .plugin, source: "/settings")
        let child = InventoryEntry(name: "slack", kind: .mcp, source: "/plugin", scope: "Plugin: slack@official")
        let direct = InventoryEntry(name: "slack", kind: .mcp, source: "/mcp")
        let catalog = CatalogConnection.build(accounts: [claude, codex], inventory: [
            AccountConnectionInventory(accountID: claude.id, entries: [plugin, child, direct]),
            AccountConnectionInventory(accountID: codex.id, entries: [plugin, child])])
        expect(catalog.count == 1, "same service groups provider plugins and direct MCP")
        expect(catalog.first?.providers.count == 2 && catalog.first?.accountCount == 2, "group counts unique providers and accounts")
        expect(catalog.first?.occurrences.count == 5, "group retains every plugin and direct configuration for separate management")
        expect(InventoryEntry.serviceName("atlassian-rovo@openai-curated-remote") == "atlassian", "Atlassian Rovo groups with Atlassian")
        expect(InventoryEntry.serviceName("grafana-prod") == "grafana", "Grafana environments group without merging credentials")
        expect(InventoryEntry.serviceName("aikido-cursor-plugin@cursor-public") == "aikido", "provider suffix does not become service identity")
    }
}
