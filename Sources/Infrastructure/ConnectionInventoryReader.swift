import Domain
import Foundation
import TOMLDecoder

/// Reads account-local configuration without starting servers or changing vendor files.
public struct ConnectionInventoryReader: Sendable {
    public var homeDirectory: URL
    public var identity: AppIdentity

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                identity: AppIdentity = .current) {
        self.homeDirectory = homeDirectory
        self.identity = identity
    }

    public func scan(accounts: [Account], connections: [IntegrationConnection]) -> [AccountConnectionInventory] {
        let health = connectionWarnings(connections)
        return accounts.map { account in
            var scan = Scan(accountID: account.id, sharedCommand: identity.binDirectory.appendingPathComponent("harnais").path)
            let environmentKey: String
            switch account.provider {
            case .claude: environmentKey = "CLAUDE_CONFIG_DIR"
            case .codex: environmentKey = "CODEX_HOME"
            case .cursor: environmentKey = "CURSOR_CONFIG_DIR"
            case .opencode: environmentKey = "XDG_DATA_HOME"
            }
            let homePath = account.env[environmentKey] ?? account.shadowHomePath ?? account.homePath
            let home = URL(fileURLWithPath: (homePath as NSString).expandingTildeInPath)
            switch account.provider {
            case .claude:
                let config = account.importedDefault && account.env["CLAUDE_CONFIG_DIR"] == nil
                    ? homeDirectory.appendingPathComponent(".claude.json")
                    : home.appendingPathComponent(".claude.json")
                let root = scan.read(config)
                scan.servers(root["mcpServers"], source: config)
                if let projects = root["projects"] as? [String: [String: Any]] {
                    for (project, settings) in projects.sorted(by: { $0.key < $1.key }) {
                        scan.servers(settings["mcpServers"], source: config, scope: "Project: \(project)")
                    }
                }
                let settingsURL = home.appendingPathComponent("settings.json")
                let settings = scan.read(settingsURL)
                scan.claudePlugins(home: home, settings: settings)
                scan.claudeMCPActivation(root: root)
                if settings["disableClaudeAiConnectors"] as? Bool == true {
                    scan.result.warnings.append("Claude.ai connectors are disabled in this account's settings.")
                }
                let authURL = home.appendingPathComponent("mcp-needs-auth-cache.json")
                let auth = scan.read(authURL)
                // Harnais authenticates its local adapter. A cached vendor OAuth
                // error for an older remote server with this name is unrelated.
                for index in scan.result.entries.indices where auth[scan.result.entries[index].name] != nil
                    && !scan.managedIDs.contains(scan.result.entries[index].id) {
                    scan.result.entries[index].warnings.append("Claude last reported that this server needs sign-in. Open Claude to check again.")
                }
            case .codex:
                let config = home.appendingPathComponent("config.toml")
                let root = scan.read(config)
                scan.servers(root["mcp_servers"], source: config, codexRuntime: true)
                let plugins = root["plugins"] as? [String: [String: Any]] ?? [:]
                let cached = scan.cachedPlugins(home: home, manifestDirectory: ".codex-plugin")
                for (name, settings) in plugins.sorted(by: { $0.key < $1.key }) {
                    let enabled = settings["enabled"] as? Bool
                    let path = cached[name]
                    var warnings: [String] = []
                    if enabled == false { warnings.append("Disabled in this account.") }
                    if path == nil { warnings.append("Plugin files were not found in this profile's cache.") }
                    scan.result.entries.append(InventoryEntry(name: name, kind: .plugin, source: config.path,
                        state: enabled == false ? "Disabled" : "Configured", warnings: warnings))
                    if let path { scan.pluginServers(at: path, name: name, enabled: enabled != false) }
                }
                for (name, path) in cached.sorted(by: { $0.key < $1.key }) where plugins[name] == nil {
                    scan.result.entries.append(InventoryEntry(name: name, kind: .plugin, source: path.path,
                        state: "Cached", warnings: ["Cached files do not confirm that this plugin is enabled."]))
                }
                if let apps = root["apps"] as? [String: [String: Any]] {
                    for (name, settings) in apps.sorted(by: { $0.key < $1.key }) where name != "_default" {
                        let disabled = settings["enabled"] as? Bool == false || apps["_default"]?["enabled"] as? Bool == false
                        scan.result.entries.append(InventoryEntry(name: name, kind: .integration, source: config.path,
                            state: disabled ? "Disabled" : "Configured",
                            warnings: disabled ? ["Disabled in this account."] : []))
                    }
                }
            case .cursor:
                let config = home.appendingPathComponent("mcp.json")
                scan.servers(scan.read(config)["mcpServers"], source: config)
                let cached = scan.cachedPlugins(home: home, manifestDirectory: ".cursor-plugin")
                for (name, path) in cached.sorted(by: { $0.key < $1.key }) {
                    scan.result.entries.append(InventoryEntry(name: name, kind: .plugin, source: path.path,
                        state: "Cached", warnings: ["Check whether this plugin is enabled in Cursor. Its cache does not record activation."]))
                    scan.pluginServers(at: path, name: name, enabled: false, cached: true)
                }
                scan.result.notes.append("Cursor workspace settings and cloud integrations are not included in this local inventory.")
            case .opencode:
                let configHome = account.env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                    ?? homeDirectory.appendingPathComponent(".config")
                var configs = [configHome.appendingPathComponent("opencode/opencode.json"),
                               configHome.appendingPathComponent("opencode/opencode.jsonc")]
                if let custom = account.env["OPENCODE_CONFIG"] { configs.append(URL(fileURLWithPath: custom)) }
                for config in configs {
                    let root = scan.read(config)
                    let mcp = root["mcp"] as? [String: Any]
                    scan.servers(mcp?["servers"] ?? root["mcp"], source: config)
                    if let plugins = root["plugin"] as? [String] {
                        for name in plugins {
                            // URLs can contain credentials. Display only the package or file name.
                            let display = name.contains("://") ? URL(string: name)?.lastPathComponent ?? "Remote plugin" : name
                            scan.result.entries.append(InventoryEntry(name: display, kind: .plugin,
                                source: config.path, state: "Configured"))
                        }
                    } else if root["plugin"] != nil {
                        scan.result.warnings.append("Could not read the plugin list in \(config.lastPathComponent).")
                    }
                }
                scan.result.notes.append("OpenCode project settings and provider-hosted integrations are not included in this local inventory.")
            }
            for connection in connections {
                let enabled = connection.isEnabled(for: account.id)
                let matching = scan.result.entries.indices.filter {
                    scan.result.entries[$0].kind == .mcp && scan.result.entries[$0].name == connection.mcpName
                        && scan.result.entries[$0].scope == "Account"
                }
                if matching.isEmpty {
                    var warnings = enabled ? health[connection.id] ?? [] : []
                    if enabled { warnings.append("Missing from this account. Sync shared connections to add it.") }
                    scan.result.entries.append(InventoryEntry(name: connection.mcpName, kind: .integration,
                        source: identity.integrationsFileURL.path, scope: "Shared by Harnais",
                        state: !enabled ? "Sync off" : "Missing", warnings: warnings))
                } else {
                    for index in matching {
                        let entry = scan.result.entries[index]
                        let managed = scan.managedIDs.contains(entry.id)
                        scan.result.entries[index].warnings += health[connection.id] ?? []
                        if managed {
                            scan.result.entries[index].kind = .integration
                            scan.result.entries[index].scope = "Shared by Harnais"
                            scan.result.entries[index].state = entry.isInactive ? "Disabled" : "Shared by Harnais"
                            if let report = ConnectionValidationStore(identity: identity).report(for: connection),
                               let check = report.results.first(where: { $0.accountID == account.id }),
                               (check.status != "passed" && check.status != "paused") || check.readCall == "failed" {
                                scan.result.entries[index].warnings.append("Last live check failed. \(check.reason ?? "The service rejected the request. Existing Added connections have not been replaced.")")
                            }
                            if !enabled {
                                scan.result.entries[index].warnings.append("Sync is off, but this shared entry is still configured.")
                            }
                        } else if enabled {
                            scan.result.entries[index].warnings.append("Uses this account's own configuration, not the shared Harnais login.")
                        }
                    }
                }
            }
            // A Harnais-owned wrapper is never Added, even if its registry row cannot be loaded.
            for index in scan.result.entries.indices where scan.managedIDs.contains(scan.result.entries[index].id)
                && !connections.contains(where: { $0.mcpName == scan.result.entries[index].name }) {
                scan.result.entries[index].scope = "Shared by Harnais"
                scan.result.entries[index].warnings.append("This Harnais adapter has no readable shared registry entry. Update Harnais or restore the connection registry.")
            }
            scan.result.entries.sort {
                if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
                if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return $0.id < $1.id
            }
            return scan.result
        }
    }

    private func connectionWarnings(_ connections: [IntegrationConnection]) -> [UUID: [String]] {
        let store = IntegrationCredentialStore(identity: identity)
        var result: [UUID: [String]] = [:]
        for connection in connections {
            var warnings: [String] = []
            do {
                if connection.kind.authKind == .oauth || connection.kind.authKind == .token {
                let secret = try store.load(for: connection)
                switch secret {
                case .oauth(let tokens):
                    if tokens.accessToken.isEmpty { warnings.append("Shared login has no access token. Sign in again.") }
                    if tokens.isExpired && (tokens.refreshToken ?? "").isEmpty {
                        warnings.append("Shared login has expired. Sign in again.")
                    }
                case .grafana(let tokens):
                    if tokens.token.isEmpty { warnings.append("Shared connection has no token.") }
                }
                }
            } catch {
                warnings.append("Shared credentials are missing or unreadable. Reconnect in Shared connections.")
            }
            if connection.kind == .grafana && GrafanaMCPProcess.binaryPath() == nil {
                warnings.append("mcp-grafana is not installed or cannot be found.")
            }
            if connection.kind == .whatsapp {
                let bridge = WhatsAppBridge(identity: identity)
                if (try? WhatsAppBridge.executable()) == nil { warnings.append("WhatsApp helper is missing. Reinstall Harnais.") }
                if !bridge.hasSavedSession { warnings.append("WhatsApp linked-device session is missing. Reconnect with your phone.") }
                if let data = try? Data(contentsOf: bridge.directory.appendingPathComponent("health.json")),
                   let health = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   ["unlinked", "timeout", "scan-qr", "link-failed"].contains(health["state"] ?? "") {
                    warnings.append("WhatsApp needs a new phone link. Choose Reconnect.")
                }
            }
            result[connection.id] = warnings
        }
        return result
    }
}

private struct Scan {
    var result: AccountConnectionInventory
    var managedIDs: Set<String> = []
    var sharedCommand: String

    init(accountID: UUID, sharedCommand: String) {
        result = AccountConnectionInventory(accountID: accountID)
        self.sharedCommand = sharedCommand
    }

    mutating func read(_ url: URL) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            if url.pathExtension == "toml" {
                return try Dictionary(TOMLTable(source: String(decoding: data, as: UTF8.self)))
            }
            guard let root = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return root
        } catch {
            // Parser diagnostics can echo credentials from the source. Never display them.
            result.warnings.append("Could not read \(url.path). Check the file's syntax and permissions.")
            return [:]
        }
    }

    mutating func servers(_ value: Any?, source: URL, scope: String = "Account", inheritedWarning: String? = nil, codexRuntime: Bool = false) {
        guard let value else { return }
        guard let servers = value as? [String: Any] else {
            result.warnings.append("Could not read the MCP server list in \(source.path).")
            return
        }
        for (name, value) in servers.sorted(by: { $0.key < $1.key }) {
            // A plugin can repeat its MCP declaration in its manifest and .mcp.json.
            if scope.hasPrefix("Plugin:"), result.entries.contains(where: { $0.name == name && $0.scope == scope && $0.kind == .mcp }) {
                continue
            }
            guard let settings = value as? [String: Any] else {
                result.entries.append(InventoryEntry(name: name, kind: .mcp, source: source.path, scope: scope,
                    state: "Invalid", warnings: ["This server's configuration is not an object."]))
                continue
            }
            var warnings = inheritedWarning.map { [$0] } ?? []
            let disabled = settings["enabled"] as? Bool == false || settings["disabled"] as? Bool == true
            if disabled { warnings.append("Disabled in this account.") }
            let commandArray = settings["command"] as? [String]
            let command = settings["command"] as? String ?? commandArray?.first
            let args = settings["args"] as? [String] ?? commandArray.map { Array($0.dropFirst()) } ?? []
            let remote = settings["url"] as? String
            if (command ?? "").isEmpty && (remote ?? "").isEmpty {
                warnings.append("No command or server URL is configured.")
            }
            if let command, command.hasPrefix("/"), !FileManager.default.isExecutableFile(atPath: command) {
                warnings.append("The configured executable is missing or is not executable.")
            }
            var entry = InventoryEntry(name: name, kind: .mcp, source: source.path, scope: scope,
                state: disabled ? "Disabled" : "Configured", warnings: warnings)
            entry.supportsLogin = remote?.isEmpty == false
            if codexRuntime, remote == nil { entry.providerRuntime = Self.bundledRuntime(command: command) }
            result.entries.append(entry)
            if let command, URL(fileURLWithPath: command).standardizedFileURL.path == sharedCommand,
               (args == ["mcp", "serve", name] || args == ["mcp", "serve", name, "--read-only"]) {
                managedIDs.insert(entry.id)
            }
        }
    }

    /// Exact provider executable locations observed in the desktop distribution.
    /// A similarly named third-party server is still Added.
    static func bundledRuntime(command: String?) -> String? {
        guard let command else { return nil }
        let computerUse = "Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
        if command == "./" + computerUse || command == "/Applications/" + computerUse ||
            command == "/Applications/ChatGPT.app/Contents/Resources/" + computerUse {
            return "Computer Use executable supplied by the Codex desktop app"
        }
        if command == "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl" {
            return "Node REPL executable supplied by the ChatGPT desktop app"
        }
        return nil
    }

    mutating func claudePlugins(home: URL, settings: [String: Any]) {
        let registry = home.appendingPathComponent("plugins/installed_plugins.json")
        let root = read(registry)
        let installed = root["plugins"] as? [String: [[String: Any]]] ?? [:]
        if root["plugins"] != nil && root["plugins"] as? [String: [[String: Any]]] == nil {
            result.warnings.append("Could not read the installed plugin registry in \(registry.path).")
        }
        let enabled = settings["enabledPlugins"] as? [String: Bool] ?? [:]
        for name in Set(installed.keys).union(enabled.keys).sorted() {
            let records = installed[name] ?? []
            let userRecords = records.filter { ($0["scope"] as? String ?? "user") == "user" }
            let isEnabled = enabled[name]
            var warnings: [String] = []
            if isEnabled == false { warnings.append("Disabled in this account.") }
            if isEnabled == true && userRecords.isEmpty { warnings.append("Enabled in settings, but no account installation was found.") }
            if isEnabled == nil { warnings.append("Installed plugin has no account enablement setting. Check its status in Claude.") }
            result.entries.append(InventoryEntry(name: name, kind: .plugin, source: registry.path,
                state: isEnabled == false ? "Disabled" : isEnabled == true ? "Enabled" : "Installed", warnings: warnings))
            let pluginIndex = result.entries.count - 1
            for record in records {
                guard let path = record["installPath"] as? String else { continue }
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: path) else {
                    result.entries[pluginIndex].warnings.append("Plugin installation files are missing.")
                    continue
                }
                let project = record["projectPath"] as? String
                pluginServers(at: url, name: name, enabled: isEnabled == true,
                              project: project)
            }
        }
    }

    /// Claude stores MCP switches per project, independently of plugin skills.
    /// Do not claim availability when every known project disables the transport.
    mutating func claudeMCPActivation(root: [String: Any]) {
        let projects = root["projects"] as? [String: [String: Any]] ?? [:]
        for index in result.entries.indices {
            let entry = result.entries[index]
            guard entry.kind == .mcp, !entry.isInactive else { continue }
            let identifier = entry.parentPlugin.map { "plugin:\($0.components(separatedBy: "@")[0]):\(entry.name)" } ?? entry.name
            let projectPath = entry.scope.hasPrefix("Project: ") ? String(entry.scope.dropFirst(9))
                : entry.scope.components(separatedBy: " · Project: ").dropFirst().first
            let settings = projectPath.map { projects[$0].map { [$0] } ?? [] } ?? Array(projects.values)
            guard !settings.isEmpty else { continue }
            let disabled = settings.filter { ($0["disabledMcpServers"] as? [String] ?? []).contains(identifier) }.count
            if disabled == settings.count {
                result.entries[index].state = "Disabled in known projects"
                result.entries[index].supportsLogin = false
                result.entries[index].activationDetail = "MCP disabled in all \(settings.count) known project(s). Plugin skills remain separate. New projects can have different settings."
            } else if disabled > 0 {
                result.entries[index].state = "Project dependent"
                result.entries[index].activationDetail = "MCP disabled in \(disabled) of \(settings.count) known projects. Check the current project's MCP settings."
            }
            if disabled > 0, entry.parentPlugin == nil {
                result.entries[index].warnings.append("This server is disabled in \(disabled) of \(settings.count) known projects. Check the project's MCP settings.")
            }
        }
    }

    /// Enumerates only marketplace/name/version, never arbitrary trees inside a plugin.
    mutating func cachedPlugins(home: URL, manifestDirectory: String) -> [String: URL] {
        let cache = home.appendingPathComponent("plugins/cache")
        var found: [String: URL] = [:]
        for marketplace in directories(cache) {
            for plugin in directories(marketplace) {
                let versions = directories(plugin).sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
                }
                if let version = versions.first(where: {
                    FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(manifestDirectory)/plugin.json").path)
                }) {
                    found["\(plugin.lastPathComponent)@\(marketplace.lastPathComponent)"] = version
                }
            }
        }
        return found
    }

    mutating func directories(_ url: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        } catch {
            result.warnings.append("Could not list plugin files in \(url.path). Check permissions.")
            return []
        }
    }

    mutating func pluginServers(at path: URL, name: String, enabled: Bool, cached: Bool = false, project: String? = nil) {
        let scope = project.map { "Plugin: \(name) · Project: \($0)" } ?? "Plugin: \(name)"
        let warning = cached ? "Bundled with a cached plugin. Activation has not been checked."
            : enabled ? nil : "The parent plugin is not enabled in this account's settings."
        var candidates = [path.appendingPathComponent(".mcp.json"), path.appendingPathComponent("mcp.json")]
        for directory in [".claude-plugin", ".codex-plugin", ".cursor-plugin"] {
            let manifestURL = path.appendingPathComponent("\(directory)/plugin.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            let manifest = read(manifestURL)
            if let relative = manifest["mcpServers"] as? String {
                candidates.append(path.appendingPathComponent(relative))
            } else if let inline = manifest["mcpServers"] as? [String: Any] {
                servers(inline, source: manifestURL, scope: scope, inheritedWarning: warning)
            }
        }
        var seen: Set<String> = []
        for file in candidates where seen.insert(file.standardizedFileURL.path).inserted {
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let root = read(file)
            servers(root["mcpServers"] ?? root, source: file, scope: scope, inheritedWarning: warning)
        }
    }

}
