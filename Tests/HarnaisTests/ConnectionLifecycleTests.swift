import AppKit
import Domain
import Foundation
import Infrastructure

enum ConnectionLifecycleTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let base = root.appendingPathComponent("connection-lifecycle")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        func occurrence(_ account: Account, _ entry: InventoryEntry) -> ConnectionOccurrence {
            CatalogConnection.build(accounts: [account], inventory: [.init(accountID: account.id, entries: [entry])])[0].occurrences[0]
        }
        let cursor = Account(provider: .cursor, label: "Test", slug: "test", homePath: base.path, binaryPath: "/bin/echo")
        let file = base.appendingPathComponent("mcp.json")
        let original = Data(#"{"mcpServers":{"target":{"command":"/bin/echo","env":{"VALUE":"preserve-me"}},"neighbor":{"url":"https://example.com"}},"other":42}"#.utf8)
        try original.write(to: file)
        let target = occurrence(cursor, .init(name: "target", kind: .mcp, source: file.path))
        let backup = try ConnectionManagement.applyConfigurationAction(.disable, occurrence: target)
        expect(try Data(contentsOf: backup) == original, "lifecycle backup preserves original bytes")
        expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "lifecycle backup owner-only")
        func json() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any] }
        var servers = try json()["mcpServers"] as! [String: [String: Any]]
        expect(servers["target"]?["disabled"] as? Bool == true, "disable targeted Cursor MCP")
        expect((servers["target"]?["env"] as? [String: String])?["VALUE"] == "preserve-me" && servers["neighbor"] != nil, "disable preserves credentials and neighbor")
        _ = try ConnectionManagement.applyConfigurationAction(.enable, occurrence: target)
        servers = try json()["mcpServers"] as! [String: [String: Any]]
        expect(servers["target"]?["disabled"] as? Bool == false, "reenable Cursor MCP")
        _ = try ConnectionManagement.applyConfigurationAction(.remove, occurrence: target)
        servers = try json()["mcpServers"] as! [String: [String: Any]]
        let otherSetting = try json()["other"] as? Int
        expect(servers["target"] == nil && servers["neighbor"] != nil && otherSetting == 42, "remove only selected server")
        let shared = Data(#"{"mcpServers":{"target":{"command":"/harnais","args":["mcp","serve","target"]}}}"#.utf8)
        try shared.write(to: file)
        do { _ = try ConnectionManagement.applyConfigurationAction(.remove, occurrence: target); expect(false, "refuse stale Added entry now shared") }
        catch { expect(try Data(contentsOf: file) == shared, "refuse stale Added entry now shared") }
        let invalid = Data("{invalid".utf8); try invalid.write(to: file)
        do { _ = try ConnectionManagement.applyConfigurationAction(.disable, occurrence: target); expect(false, "invalid config unchanged") }
        catch { expect(try Data(contentsOf: file) == invalid, "invalid config unchanged") }

        let codex = Account(provider: .codex, label: "Test", slug: "test", homePath: base.path, binaryPath: "/bin/echo")
        let config = base.appendingPathComponent("config.toml")
        let toml = """
        # Preserve this comment
        model = "model-name"
        [plugins."pdf@openai-primary-runtime"]
        enabled = true # previously enabled
        [plugins."pdf@openai-primary-runtime".mcp_servers.server]
        enabled = false
        [mcp_servers.neighbor]
        command = "/bin/echo"
        """
        try Data(toml.utf8).write(to: config)
        let pdf = occurrence(codex, .init(name: "pdf@openai-primary-runtime", kind: .plugin, source: config.path))
        _ = try ConnectionManagement.applyConfigurationAction(.disable, occurrence: pdf)
        let disabled = try String(contentsOf: config, encoding: .utf8)
        expect(disabled.contains("# Preserve this comment") && disabled.contains("model = \"model-name\""), "TOML lifecycle preserves surrounding text")
        let reader = ConnectionInventoryReader(homeDirectory: base)
        expect(reader.scan(accounts: [codex], connections: [])[0].entries.first { $0.name == pdf.entry.name }?.isInactive == true, "Codex plugin disables in inventory")
        _ = try ConnectionManagement.applyConfigurationAction(.enable, occurrence: pdf)
        expect(reader.scan(accounts: [codex], connections: [])[0].entries.first { $0.name == pdf.entry.name }?.state == "Configured", "Codex plugin reenables")
        if case .command(let cmd) = try ConnectionManagement.actionRoute(.remove, occurrence: pdf) {
            expect(cmd.arguments == ["plugin", "remove", pdf.entry.name] && cmd.environment["CODEX_HOME"] == base.path, "Codex uninstall uses native CLI and isolated account")
        } else { expect(false, "Codex uninstall native route") }
        let cached = occurrence(codex, .init(name: "cached@other", kind: .plugin, source: base.appendingPathComponent("plugins/cache/other/cached/1").path, state: "Cached"))
        _ = try ConnectionManagement.applyConfigurationAction(.disable, occurrence: cached)
        expect(reader.scan(accounts: [codex], connections: [])[0].entries.first { $0.name == cached.entry.name }?.isInactive == true, "cached Codex plugin gets explicit disabled setting")
        let cursorPlugin = occurrence(cursor, .init(name: "aikido@cursor", kind: .plugin, source: "/cache", state: "Cached"))
        if case .provider = try ConnectionManagement.actionRoute(.remove, occurrence: cursorPlugin) { expect(true, "Cursor cache never deleted as uninstall") } else { expect(false, "Cursor cache never deleted as uninstall") }
        let claude = Account(provider: .claude, label: "Test", slug: "test", homePath: base.path, binaryPath: "/bin/echo")
        let claudePlugin = occurrence(claude, .init(name: "frontend-design@claude-plugins-official", kind: .plugin, source: "/registry"))
        if case .command(let cmd) = try ConnectionManagement.actionRoute(.remove, occurrence: claudePlugin) {
            expect(cmd.arguments == ["plugin", "uninstall", claudePlugin.entry.name, "--scope", "user", "--keep-data"], "Claude uninstall preserves plugin data and selects user scope")
        } else { expect(false, "Claude uninstall route") }
        let builtIn = InventoryEntry(name: "computer-use@openai-bundled", kind: .plugin, source: config.path)
        var runtime = InventoryEntry(name: "computer-use", kind: .mcp, source: config.path, state: "Disabled")
        runtime.providerRuntime = "Provider executable"
        let custom = InventoryEntry(name: "computer-use", kind: .mcp, source: "/custom")
        let grouped = CatalogConnection.build(accounts: [codex], inventory: [.init(accountID: codex.id, entries: [builtIn, runtime, custom])])
        expect(grouped.count == 1 && grouped[0].occurrences.count == 3, "same service appears once across origins without losing installations")
        expect(grouped[0].origin == .builtIn && custom.origin == .added, "grouping preserves custom installation origin")
        expect(grouped[0].activationSummary == "Partly disabled", "plugin cannot hide disabled runtime")
        do { _ = try ConnectionManagement.actionRoute(.remove, occurrence: occurrence(codex, builtIn)); expect(false, "builtin protected from Added actions") }
        catch { expect(true, "builtin protected from Added actions") }
        let runtimeConfig = """
        [mcp_servers.computer-use]
        command = "./Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
        [mcp_servers.node_repl]
        command = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"
        [mcp_servers.custom-computer-use]
        command = "/custom/SkyComputerUseClient"
        """
        try Data(runtimeConfig.utf8).write(to: config)
        let runtimeEntries = reader.scan(accounts: [codex], connections: [])[0].entries
        expect(runtimeEntries.first { $0.name == "computer-use" }?.origin == .builtIn && runtimeEntries.first { $0.name == "node_repl" }?.origin == .builtIn, "provider executable provenance classifies runtimes")
        expect(runtimeEntries.first { $0.name == "custom-computer-use" }?.origin == .added, "custom command remains added")
        let openCode = Account(provider: .opencode, label: "Test", slug: "test", homePath: base.path)
        for nested in [false, true] {
            let server: [String: Any] = ["type": "remote", "url": "https://example.com"]
            let mcp: [String: Any] = nested ? ["servers": ["target": server], "other": true] : ["target": server]
            try JSONSerialization.data(withJSONObject: ["mcp": mcp]).write(to: file)
            let op = occurrence(openCode, .init(name: "target", kind: .mcp, source: file.path))
            _ = try ConnectionManagement.applyConfigurationAction(.disable, occurrence: op)
            let updated = try json()["mcp"] as! [String: Any]
            let container = nested ? updated["servers"] as! [String: Any] : updated
            let changed = container["target"] as! [String: Any]
            expect(changed[nested ? "disabled" : "enabled"] as? Bool == nested, "OpenCode disable uses correct schema")
            _ = try ConnectionManagement.applyConfigurationAction(.remove, occurrence: op)
            expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("target"), "OpenCode remove handles schema")
        }
    }
}
