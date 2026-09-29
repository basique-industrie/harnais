import AppKit
import Domain
import Foundation
import Infrastructure

enum ConnectionInventoryTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let base = root.appendingPathComponent("inventory")
        let identity = AppIdentity(dataDirectory: base.appendingPathComponent("harnais"))
        let reader = ConnectionInventoryReader(homeDirectory: base, identity: identity)
        func write(_ path: String, _ text: String) throws {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let personal = Account(provider: .claude, label: "Personal", slug: "personal",
            homePath: base.appendingPathComponent(".claude").path, importedDefault: true)
        let work = Account(provider: .claude, label: "Work", slug: "work", homePath: base.appendingPathComponent("work").path)
        let codex = Account(provider: .codex, label: "Codex", slug: "codex", homePath: base.appendingPathComponent(".codex").path,
            shadowHomePath: base.appendingPathComponent("shadow").path)
        let cursor = Account(provider: .cursor, label: "Cursor", slug: "cursor", homePath: base.appendingPathComponent("cursor").path)
        let opencode = Account(provider: .opencode, label: "OpenCode", slug: "opencode", homePath: base.appendingPathComponent("data").path,
            env: ["XDG_CONFIG_HOME": base.appendingPathComponent("xdg").path])
        try write(".claude.json", #"{"mcpServers":{"personal-only":{"url":"https://example.com/mcp?token=VERY_SECRET"}},"projects":{"/project":{"mcpServers":{"project-only":{"command":"echo"}}}}}"#)
        try write("work/.claude.json", #"{"mcpServers":{"work-only":{"command":"echo"},"disabled":{"command":"echo","disabled":true},"invalid":false}}"#)
        try write("work/settings.json", #"{"enabledPlugins":{"test@local":false,"missing@local":true},"disableClaudeAiConnectors":true}"#)
        let install = base.appendingPathComponent("work/plugin").path
        try write("work/plugins/installed_plugins.json", """
        {"version":2,"plugins":{"test@local":[{"scope":"user","installPath":"\(install)"}]}}
        """)
        try write("work/plugin/.mcp.json", #"{"mcpServers":{"bundled":{"url":"https://example.com/mcp"}}}"#)
        try write("work/plugin/.claude-plugin/plugin.json", #"{"mcpServers":{"bundled":{"url":"https://example.com/mcp"}}}"#)
        try write("work/mcp-needs-auth-cache.json", #"{"work-only":{"timestamp":1}}"#)
        try write(".codex/config.toml", "[mcp_servers.wrong_home]\ncommand = 'echo'")
        try write("shadow/config.toml", """
        # Quoted names, inline tables, nested env and multiline arrays must all parse.
        [mcp_servers."server.with.dots"]
        command = "echo"
        args = [
          "VERY_SECRET",
        ]
        enabled = false
        [mcp_servers."server.with.dots".env]
        TOKEN = "VERY_SECRET"
        [plugins]
        "sample@local" = { enabled = true }
        [apps."app_example"]
        enabled = false
        """)
        try write("shadow/plugins/cache/local/sample/1.0/.codex-plugin/plugin.json", #"{"name":"sample"}"#)
        try write("cursor/mcp.json", #"{"mcpServers":{"missing-command":{"command":"/does/not/exist"}}}"#)
        try write("cursor/plugins/cache/local/cached/1/.cursor-plugin/plugin.json", #"{"name":"cached","mcpServers":"mcp.json"}"#)
        try write("cursor/plugins/cache/local/cached/1/mcp.json", #"{"mcpServers":{"cached-server":{"url":"https://example.com"}}}"#)
        try write("xdg/opencode/opencode.jsonc", """
        {
            // Preserve URL slashes and allow trailing commas.
            "mcp": {"jsonc-server": {"type":"remote", "url":"https://example.com/mcp", "enabled":false,},},
            "plugin": ["opencode-auth@1.0", "https://user:VERY_SECRET@example.com/plugin.js"],
        }
        """)
        let accounts = [personal, work, codex, cursor, opencode]
        let result = reader.scan(accounts: accounts, connections: [])
        expect(result.count == 5, "inventory includes every account")
        expect(result[0].entries.contains { $0.name == "personal-only" }, "default Claude reads ~/.claude.json")
        expect(!result[1].entries.contains { $0.name == "personal-only" }, "isolated Claude does not inherit default MCPs")
        expect(result[0].entries.contains { $0.name == "project-only" && $0.scope == "Project: /project" }, "project MCP scope is explicit")
        expect(result[1].entries.contains { $0.name == "disabled" && $0.state == "Disabled" && !$0.warnings.isEmpty }, "disabled server warning")
        expect(result[1].entries.contains { $0.name == "invalid" && $0.state == "Invalid" }, "malformed entry survives as warning")
        expect(result[1].entries.contains { $0.name == "missing@local" && !$0.warnings.isEmpty }, "missing plugin install warning")
        expect(result[1].entries.filter { $0.name == "bundled" }.count == 1, "duplicate bundled MCP declarations appear once")
        expect(result[1].entries.contains { $0.name == "bundled" && $0.scope.hasPrefix("Plugin:") && !$0.warnings.isEmpty }, "bundled MCP inherits disabled plugin warning")
        expect(result[1].entries.contains { $0.name == "work-only" && $0.warnings.contains { $0.contains("needs sign-in") } }, "cached auth warning is attributed to server")
        expect(result[1].warnings.contains { $0.contains("connectors are disabled") }, "account connector policy warning")
        expect(result[2].entries.contains { $0.name == "server.with.dots" && $0.state == "Disabled" }, "TOML preserves quoted dotted server names")
        expect(!result[2].entries.contains { $0.name == "wrong_home" }, "Codex inventory uses shadow home")
        expect(result[2].entries.contains { $0.name == "sample@local" && $0.warnings.isEmpty }, "Codex plugin config matches installed cache")
        expect(result[2].entries.contains { $0.name == "app_example" && $0.kind == .integration && $0.state == "Disabled" }, "Codex app preferences are integrations")
        expect(result[3].entries.contains { $0.name == "missing-command" && !$0.warnings.isEmpty }, "missing executable warning")
        expect(result[3].entries.contains { $0.name == "cached@local" && $0.state == "Cached" }, "cached Cursor plugin is not claimed as enabled")
        expect(result[3].entries.filter { $0.name == "cached-server" }.count == 1, "manifest and default MCP path are deduplicated")
        expect(result[4].entries.contains { $0.name == "jsonc-server" && $0.state == "Disabled" }, "OpenCode JSONC and XDG isolation")
        expect(result[4].entries.contains { $0.name == "opencode-auth@1.0" && $0.kind == .plugin }, "OpenCode plugin packages")
        expect(!String(describing: result).contains("VERY_SECRET"), "inventory never exposes server arguments, tokens, URLs or env")
        expect(Set(result.flatMap(\.entries).map(\.id)).count == result.flatMap(\.entries).count, "stable unique entry IDs")

        let shared = IntegrationConnection(kind: .slack, label: "Work", slug: "work", mcpName: "shared", lastLoginAt: Date())
        let store = IntegrationCredentialStore(identity: identity)
        try store.save(.oauth(OAuthTokenSet(accessToken: "VERY_SECRET", expiresAt: Date(timeIntervalSince1970: 0))), for: shared)
        let command = identity.binDirectory.appendingPathComponent("harnais").path
        let sharedJSON = """
        {"mcpServers":{"shared":{"command":"\(command)","args":["mcp","serve","shared"]}}}
        """
        try write("cursor/mcp.json", sharedJSON)
        try write("work/.claude.json", #"{"mcpServers":{"shared":{"url":"https://different.example.com"}}}"#)
        let withShared = reader.scan(accounts: [cursor, personal, work], connections: [shared])
        expect(withShared[0].entries.contains { $0.name == "shared" && $0.state == "Shared by Harnais" }, "shared wrapper verified from actual file")
        expect(withShared[0].entries.contains { $0.name == "shared" && $0.warnings.contains { $0.contains("expired") } }, "expired shared credentials warning")
        expect(withShared[1].entries.contains { $0.name == "shared" && $0.state == "Missing" }, "shared integration missing on another account")
        expect(withShared[2].entries.contains { $0.name == "shared" && $0.warnings.contains { $0.contains("own configuration") } }, "same name is not proof of shared login")
        try write("work/.claude.json", sharedJSON)
        try write("work/mcp-needs-auth-cache.json", #"{"shared":{"timestamp":1}}"#)
        let migrated = reader.scan(accounts: [work], connections: [shared])[0]
        expect(!migrated.entries.contains { $0.name == "shared" && $0.warnings.contains { $0.contains("needs sign-in") } }, "migrated local adapter does not inherit stale vendor OAuth warning")
        expect(migrated.entries.contains { $0.name == "shared" && $0.warnings.contains { $0.contains("expired") } }, "migration still exposes actual shared credential failures")
        expect(try String(contentsOf: base.appendingPathComponent("cursor/mcp.json"), encoding: .utf8) == sharedJSON, "inventory does not modify account settings")
        var excluded = shared
        excluded.isExcludedFromApply = true
        let off = reader.scan(accounts: [personal], connections: [excluded])[0]
        expect(off.entries.contains { $0.name == "shared" && $0.state == "Sync off" && !$0.warnings.contains { $0.contains("Missing from") } }, "excluded integration is not reported as missing")
        try write("shadow/config.toml", "token = 'VERY_SECRET'\n[invalid")
        try write("cursor/mcp.json", "{\"token\":\"VERY_SECRET\", broken")
        let broken = reader.scan(accounts: [codex, cursor, personal], connections: [])
        expect(!broken[0].warnings.isEmpty && !broken[1].warnings.isEmpty, "malformed TOML and JSON are visible warnings")
        expect(!String(describing: broken).contains("VERY_SECRET"), "parser errors do not echo credentials")
        expect(broken[2].entries.contains { $0.name == "personal-only" }, "one corrupt profile does not prevent other accounts loading")
        let activation = Account(provider: .claude, label: "Activation", slug: "activation", homePath: base.appendingPathComponent("activation").path)
        try write("activation/settings.json", #"{"enabledPlugins":{"test@local":true}}"#)
        try write("activation/plugins/installed_plugins.json", """
        {"version":2,"plugins":{"test@local":[{"scope":"user","installPath":"\(install)"}]}}
        """)
        let disabledProjects = """
        {"mcpServers":{"shared":{"command":"\(command)","args":["mcp","serve","shared"]}},
         "projects":{"/one":{"disabledMcpServers":["plugin:test:bundled","shared"]},"/two":{"disabledMcpServers":["plugin:test:bundled","shared"]}}}
        """
        try write("activation/.claude.json", disabledProjects)
        let activationEntries = reader.scan(accounts: [activation], connections: [shared])[0].entries
        let pluginMCP = activationEntries.first { $0.name == "bundled" }!
        expect(pluginMCP.state == "Disabled in known projects" && pluginMCP.isInactive && !pluginMCP.supportsLogin, "plugin transport respects all known project disable switches")
        expect(activationEntries.contains { $0.name == "test@local" && $0.state == "Enabled" }, "disabled plugin MCP does not disable retained skills")
        expect(activationEntries.contains { $0.name == "shared" && $0.state == "Disabled" && $0.origin == .shared }, "disabled shared transport remains classified Shared")
        expect(pluginMCP.activationDetail?.contains("2 known") == true, "plugin state reports coverage without claiming global disable")
        try write("activation/.claude.json", #"{"projects":{"/one":{"disabledMcpServers":["plugin:test:bundled"]},"/two":{}}}"#)
        let mixed = reader.scan(accounts: [activation], connections: [])[0].entries.first { $0.name == "bundled" }!
        expect(mixed.state == "Project dependent" && !mixed.isInactive, "mixed project activation is not hidden as inactive")
        try write("activation/.claude.json", #"{"projects":{}}"#)
        expect(reader.scan(accounts: [activation], connections: [])[0].entries.first { $0.name == "bundled" }?.state == "Configured", "no known project cannot establish a plugin is disabled")
        let cachedPlugin = InventoryEntry(name: "aikido@cursor", kind: .plugin, source: "/cache", state: "Cached")
        let cachedMCP = InventoryEntry(name: "aikido", kind: .mcp, source: "/cache/mcp.json", scope: "Plugin: aikido@cursor", warnings: ["Bundled with a cached plugin. Activation has not been checked."])
        let retained = InventoryEntry(name: "slack@claude", kind: .plugin, source: "/installed", state: "Enabled")
        let fallback = InventoryEntry(name: "google-drive", kind: .mcp, source: "/config")
        let groups = SharedProviderInventory(occurrences: CatalogConnection.build(accounts: [activation], inventory: [AccountConnectionInventory(accountID: activation.id, entries: [cachedPlugin, cachedMCP, pluginMCP, retained, fallback])]).flatMap(\.occurrences))
        expect(groups.configuredConnections.count == 1 && groups.configuredConnections[0].entry.name == "google-drive", "only independently configured transports appear as separate connections")
        expect(groups.extensions.count == 1 && groups.inactive.count == 3, "retained plugin capabilities and inactive/cache records are separate")

        let empty = Account(provider: .cursor, label: "Empty", slug: "empty", homePath: base.appendingPathComponent("empty").path)
        expect(reader.scan(accounts: [empty], connections: [])[0].entries.isEmpty, "missing config produces empty inventory")
        expect(!FileManager.default.fileExists(atPath: empty.homePath), "read-only scan does not create config directories")
    }
}
