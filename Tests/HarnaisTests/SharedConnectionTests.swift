import AppKit
import Domain
import Foundation
import Infrastructure

enum SharedConnectionTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let base = root.appendingPathComponent("sharing")
        let identity = AppIdentity(dataDirectory: base.appendingPathComponent("data"))
        let service = IntegrationService(identity: identity, homeDirectory: base)
        let store = service.credentials
        let connection = IntegrationConnection(kind: .custom, label: "Example", slug: "example", mcpName: "harnais-example",
            lastLoginAt: Date(), endpointURL: "https://example.com/mcp")
        try service.registry.add(connection)
        try store.save(.oauth(OAuthTokenSet(clientId: "client", accessToken: "old", refreshToken: "rotate",
            expiresAt: Date(timeIntervalSince1970: 0), resource: connection.mcpURL.absoluteString)), for: connection)
        let first = try store.authorizedTokens(for: connection) { tokens in
            var next = tokens; next.accessToken = "new"; next.refreshToken = "rotated"; next.expiresAt = Date().addingTimeInterval(3600)
            return next
        }
        expect(first.accessToken == "new", "shared credentials refresh expired access token")
        expect(VendorMCPProcess.validLoginURL(URL(string: "https://app.aikido.dev/settings/integrations/ide/mcp?state=test")!), "Aikido login accepts official callback page")
        expect(!VendorMCPProcess.validLoginURL(URL(string: "https://app.aikido.dev.evil.test/settings/integrations/ide/mcp")!), "Aikido login rejects lookalike host")
        expect(!VendorMCPProcess.validLoginURL(URL(string: "https://user:secret@app.aikido.dev/settings/integrations/ide/mcp")!), "Aikido login rejects credentials in URL")
        let cachedEntry = InventoryEntry(name: "aikido", kind: .plugin, source: "/cache", state: "Cached", warnings: ["Cached files do not confirm that this plugin is enabled."])
        expect(cachedEntry.actionableWarnings.isEmpty && !cachedEntry.warnings.isEmpty, "cache uncertainty remains visible without a false failure")
        let failedEntry = InventoryEntry(name: "aikido", kind: .mcp, source: "/config", warnings: ["Server executable not found."])
        expect(failedEntry.actionableWarnings.count == 1, "actual connection errors remain actionable")
        let vendorBase = base.appendingPathComponent("vendor-tests")
        let vendorService = IntegrationService(identity: AppIdentity(dataDirectory: vendorBase.appendingPathComponent("data")), homeDirectory: vendorBase)
        let diagrams = try vendorService.connectVendor(kind: .excalidraw, label: "Diagrams", accounts: [], openURL: { _ in fatalError("no login for Excalidraw") })
        expect(diagrams.kind.authKind == .none && diagrams.isSignedIn && diagrams.localCanvas != true, "remote Excalidraw needs no fake OAuth credentials")
        let canvas = try vendorService.connectVendor(kind: .excalidraw, label: "Canvas", localCanvas: true, accounts: [], openURL: { _ in fatalError("no login for canvas") })
        expect(canvas.localCanvas == true, "canvas mode survives registry storage")
        expect(try vendorService.registry.connection(mcpName: canvas.mcpName)?.localCanvas == true, "local canvas mode decodes from disk")

        let gmail = IntegrationConnection(kind: .gmail, label: "Mail", slug: "mail", mcpName: "mail")
        try store.save(.oauth(OAuthTokenSet(tokenEndpoint: "https://oauth2.googleapis.com/token", accessToken: "gmail", resource: "https://gmailmcp.googleapis.com/mcp/v1")), for: gmail)
        expect(try store.authorizedTokens(for: gmail) { $0 }.resource == nil, "legacy Google Gmail login migrates to stable API")
        try store.save(.oauth(OAuthTokenSet(tokenEndpoint: "https://other.example/token", accessToken: "wrong", resource: "https://gmailmcp.googleapis.com/mcp/v1")), for: gmail)
        do { _ = try store.authorizedTokens(for: gmail) { $0 }; expect(false, "foreign issuer cannot migrate Gmail") }
        catch { expect(true, "foreign issuer cannot migrate Gmail") }
        let second = try store.authorizedTokens(for: connection, rejectedAccessToken: "old") { _ in
            throw HarnaisError.processFailed("must reuse refreshed token")
        }
        expect(second.refreshToken == "rotated", "rejected stale token reuses another provider's refresh")
        let preserved = try service.updateSettings(connection, label: "Renamed", mcpName: connection.mcpName,
            endpoint: connection.mcpURL.absoluteString, token: "", clientID: "client", clientSecret: "", shared: false)
        expect(preserved.excludedFromApply && preserved.lastLoginAt != nil, "pause keeps shared login")
        expect(try store.load(for: preserved).oauth?.accessToken == "new", "ordinary settings preserve credentials")
        let changed = try service.updateSettings(preserved, label: "Renamed", mcpName: connection.mcpName,
            endpoint: "https://other.example.com/mcp", token: "", clientID: "new-client", clientSecret: "", shared: true)
        expect(changed.lastLoginAt == nil, "endpoint change invalidates login")
        expect(try store.load(for: changed).oauth?.refreshToken == nil, "endpoint change never reuses refresh token")
        do { _ = try store.authorizedTokens(for: changed) { $0 }; expect(false, "blank access rejected") }
        catch { expect(true, "blank access rejected") }
        for invalid in ["http://example.com/mcp", "https://user:secret@example.com/mcp", "https://example.com/mcp#fragment", "file:///tmp/server"] {
            expect((try? SharedMCPURL.parse(invalid)) == nil, "reject unsafe shared endpoint")
        }
        expect((try? SharedMCPURL.parse("http://127.0.0.1:9999/mcp")) != nil, "allow local test server")
        let account = Account(provider: .cursor, label: "Work", slug: "work", homePath: base.appendingPathComponent("profile").path, binaryPath: "/bin/echo")
        let plugin = InventoryEntry(name: "browser@openai-bundled", kind: .plugin, source: "/config.toml")
        let child = InventoryEntry(name: "browser-mcp", kind: .mcp, source: "/plugin/mcp.json", scope: "Plugin: browser@openai-bundled")
        let added = InventoryEntry(name: "pdf@openai-primary-runtime", kind: .plugin, source: "/config.toml")
        expect(plugin.origin == .builtIn && child.origin == .builtIn && added.origin == .added, "bundled differs from official added plugins")
        let catalog = CatalogConnection.build(accounts: [account], inventory: [AccountConnectionInventory(accountID: account.id, entries: [plugin, child, added])])
        expect(catalog.count == 2 && catalog.first { $0.origin == .builtIn }?.accountCount == 1, "group plugin and bundled servers without duplicate account counts")
        let related = CatalogConnection.build(accounts: [account], inventory: [AccountConnectionInventory(accountID: account.id,
            entries: [InventoryEntry(name: "excalidraw", kind: .mcp, source: "/old")])])[0]
        expect(related.sharedConnection(in: [diagrams])?.id == diagrams.id, "service entries consolidate under active shared connection")
        var pausedDiagrams = diagrams; pausedDiagrams.isExcludedFromApply = true
        expect(related.sharedConnection(in: [pausedDiagrams])?.id == pausedDiagrams.id, "paused shared service groups its retained provider tools in Manage")

        var remote = InventoryEntry(name: "example", kind: .mcp, source: base.appendingPathComponent("profile/mcp.json").path)
        remote.supportsLogin = true
        let login = try ConnectionManagement.loginCommand(account: account, entry: remote)
        expect(login.arguments == ["mcp", "login", "example"], "account login uses provider CLI arguments")
        let global = base.appendingPathComponent(".cursor/mcp.json")
        let profile = URL(fileURLWithPath: remote.source)
        try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"mcpServers":{"harnais-example":{"url":"https://existing.example.com/mcp"}}}"#.utf8)
        try original.write(to: profile)
        do {
            _ = try service.exporter.apply(connections: [connection], accounts: [account], commandPath: "/harnais", previousNames: [])
            expect(false, "sync must reject foreign server name")
        } catch {
            expect(!FileManager.default.fileExists(atPath: global.path), "preflight rejects before writing any destination")
            expect(try Data(contentsOf: profile) == original, "name collision preserves existing account config")
        }
        try Data(#"{"mcpServers":{"private":{"url":"https://example.com/mcp"}},"setting":42}"#.utf8).write(to: profile)
        _ = try service.exporter.apply(connections: [connection], accounts: [account], commandPath: "/harnais", previousNames: [])
        let text = try String(contentsOf: profile, encoding: .utf8)
        expect(text.contains("private") && text.contains("42") && text.contains("harnais-example"), "sync preserves unrelated config")
        expect(!text.contains("accessToken") && !text.contains("refreshToken"), "provider config contains no shared secrets")
        _ = try service.exporter.apply(connections: [], accounts: [account], commandPath: "/harnais", previousNames: [connection.mcpName])
        let removed = try String(contentsOf: profile, encoding: .utf8)
        expect(!removed.contains("harnais-example") && removed.contains("private"), "disconnect removes only owned wrappers")
        let v2 = base.appendingPathComponent("opencode.jsonc")
        try Data(#"{"mcp":{"servers":{"remote":{"type":"remote","url":"https://example.com/mcp"}}}}"#.utf8).write(to: v2)
        let openCode = Account(provider: .opencode, label: "Test", slug: "test", homePath: base.path, env: ["OPENCODE_CONFIG": v2.path])
        _ = try service.exporter.apply(connections: [connection], accounts: [openCode], commandPath: "/harnais", previousNames: [])
        let inventory = ConnectionInventoryReader(homeDirectory: base, identity: identity).scan(accounts: [openCode], connections: [])
        expect(inventory[0].entries.contains { $0.name == connection.mcpName }, "OpenCode nested MCP config exported and discovered")
        let entry = inventory[0].entries.first { $0.name == "remote" }!
        expect(ConnectionManagement.remoteEndpoint(entry, provider: .opencode) == "https://example.com/mcp", "share login reads nested endpoint only")
        var grafana = IntegrationConnection(kind: .grafana, label: "Prod", slug: "prod", mcpName: "harnais-grafana-prod")
        grafana.readOnlyAccountIDs = [account.id]
        _ = try service.exporter.apply(connections: [grafana], accounts: [account, openCode], commandPath: "/harnais", previousNames: [connection.mcpName])
        let restricted = try String(contentsOf: profile, encoding: .utf8)
        let unrestricted = try String(contentsOf: v2, encoding: .utf8)
        expect(restricted.contains("--read-only"), "migration preserves account-specific Grafana write restriction")
        expect(!unrestricted.contains("--read-only"), "restriction does not silently change another account's capabilities")
        _ = try service.exporter.apply(connections: [grafana], accounts: [account, openCode], commandPath: "/harnais", previousNames: [grafana.mcpName])
        _ = try service.exporter.apply(connections: [], accounts: [account, openCode], commandPath: "/harnais", previousNames: [grafana.mcpName])
        expect(!(try String(contentsOf: profile, encoding: .utf8)).contains(grafana.mcpName), "restricted wrapper remains owned across sync and disconnect")
    }
}
