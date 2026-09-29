import Domain
import Foundation
import TOMLDecoder

public enum ConnectionAction: String, CaseIterable, Sendable, Identifiable {
    case enable = "Enable", disable = "Disable", remove = "Remove"
    public var id: String { rawValue }
}

/// A reviewable, account-scoped action. Provider-owned registries are changed by
/// their CLI/UI; cache deletion is never used as a substitute for uninstalling.
public enum ConnectionActionRoute: Sendable {
    case configuration
    case command(LoginCommand)
    case provider(String, URL)
}

public extension ConnectionManagement {
    static func actionRoute(_ action: ConnectionAction, occurrence: ConnectionOccurrence,
                            isolation: IsolationEngine = IsolationEngine()) throws -> ConnectionActionRoute {
        let account = occurrence.account, entry = occurrence.entry
        guard entry.origin == .added else {
            throw HarnaisError.processFailed("Use the shared connection or provider controls for this installation.")
        }
        guard !entry.name.hasPrefix("-"), !entry.name.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else {
            throw HarnaisError.processFailed("Manage this installation in its provider; its identifier cannot be passed safely to a command.")
        }
        let plugin = entry.parentPlugin ?? (entry.kind == .plugin ? entry.name : nil)
        func command(_ args: [String]) throws -> ConnectionActionRoute {
            guard let binary = BinaryLocator.resolve(account.provider, override: account.binaryPath) else {
                throw HarnaisError.binaryNotFound(account.provider.defaultBinaryName)
            }
            var environment = isolation.spawnEnvironment(for: account)
            let profile = account.shadowHomePath ?? account.homePath
            if account.provider == .codex {
                environment["CODEX_HOME"] = account.env["CODEX_HOME"] ?? profile
            }
            if account.provider == .claude {
                if account.importedDefault && account.env["CLAUDE_CONFIG_DIR"] == nil {
                    environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
                } else { environment["CLAUDE_CONFIG_DIR"] = account.env["CLAUDE_CONFIG_DIR"] ?? profile }
            }
            return .command(LoginCommand(executable: binary, arguments: args,
                environment: environment, workingDirectory: profile))
        }
        if let plugin {
            guard !plugin.hasPrefix("-") else { throw LifecycleError.invalid }
            switch account.provider {
            case .claude:
                // Project plugins must be managed from their project, not at user scope.
                let registry = (try? Data(contentsOf: URL(fileURLWithPath: entry.source)))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let records = (registry?["plugins"] as? [String: [[String: Any]]])?[plugin] ?? []
                let projectOnly = !records.isEmpty && !records.contains { ($0["scope"] as? String ?? "user") == "user" }
                if entry.scope != "Account" || projectOnly {
                    return .provider("Open Claude in the installation's project, run /plugin, select \(plugin), then choose \(action.rawValue.lowercased()) at the displayed scope. Plugin actions also affect its skills, hooks and MCP servers.", URL(string: "https://code.claude.com/docs/en/discover-plugins")!)
                }
                return try command(["plugin", action == .remove ? "uninstall" : action.rawValue.lowercased(), plugin, "--scope", "user"] + (action == .remove ? ["--keep-data"] : []))
            case .codex:
                if action == .remove { return try command(["plugin", "remove", plugin]) }
                if entry.parentPlugin == nil { return .configuration }
                return .provider("Open the plugin in Codex and manage this MCP component there. Disabling the whole plugin also disables its skills and other components.", URL(string: "https://developers.openai.com/plugins/build/plugins")!)
            case .cursor:
                return .provider("In Cursor, open Customize → Plugins, find \(plugin), select the user or workspace scope, then \(action == .remove ? "uninstall it" : "change its enabled toggle"). Team-required plugins cannot be removed. Refresh Harnais afterward; cached files alone cannot confirm the result.", URL(string: "https://cursor.com/docs/plugins")!)
            case .opencode:
                return .provider("Open this account's OpenCode configuration and manage the package in the plugin list. Remove its list entry to stop loading it, then restart OpenCode. Keep the package name to add it again.", URL(string: "https://opencode.ai/docs/plugins/")!)
            }
        }
        if entry.kind == .mcp && entry.parentPlugin == nil {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: entry.source)) {
                let root: [String: Any]?
                if entry.source.hasSuffix(".toml") { root = try? Dictionary(TOMLTable(source: String(decoding: data, as: UTF8.self))) }
                else { root = (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any] }
                let servers = root?[account.provider == .codex ? "mcp_servers" : "mcpServers"] as? [String: [String: Any]]
                if let current = servers?[entry.name], isSharedAdapter(current) {
                    throw HarnaisError.processFailed("This installation now uses Harnais Shared. Refresh the inventory and manage it from Shared connections.")
                }
            }
            if account.provider == .codex && action == .remove { return try command(["mcp", "remove", entry.name]) }
            if account.provider == .claude {
                if action == .remove, entry.scope == "Account" {
                    return try command(["mcp", "remove", entry.name, "--scope", "user"])
                }
                return .provider("Open Claude in the affected project, run /mcp, select \(entry.name), then \(action.rawValue.lowercased()) it. Claude's MCP activation is project-specific; check each project that uses this account.", URL(string: "https://code.claude.com/docs/en/mcp")!)
            }
            return .configuration
        }
        return .provider("Open \(account.provider.displayName)'s connected apps settings, select \(entry.displayName), and \(action.rawValue.lowercased()) the connection. Refresh Harnais after completing the provider workflow.", URL(string: "https://developers.openai.com/plugins")!)
    }

    /// Returns backup path. Does not revoke credentials or touch another installation.
    static func applyConfigurationAction(_ action: ConnectionAction, occurrence: ConnectionOccurrence) throws -> URL {
        guard case .configuration = try actionRoute(action, occurrence: occurrence) else {
            throw HarnaisError.processFailed("This installation must be managed through its provider.")
        }
        let entry = occurrence.entry, account = occurrence.account
        let url = settingsURL(account: account, entry: entry)
        return try AtomicJSONFile(fileURL: url).withLock {
            let before = try Data(contentsOf: url)
            let after: Data
            do {
                if account.provider == .codex {
                    after = Data(try updatedTOML(String(decoding: before, as: UTF8.self),
                        section: entry.kind == .plugin ? "plugins" : "mcp_servers", name: entry.name, action: action).utf8)
                } else {
                    guard var root = try JSONSerialization.jsonObject(with: before, options: [.json5Allowed]) as? [String: Any] else { throw LifecycleError.invalid }
                    let key = account.provider == .opencode ? "mcp" : "mcpServers"
                    guard var container = root[key] as? [String: Any] else { throw LifecycleError.invalid }
                    let nested = account.provider == .opencode && container["servers"] is [String: Any]
                    var servers = nested ? container["servers"] as! [String: Any] : container
                    guard var server = servers[entry.name] as? [String: Any] else { throw LifecycleError.invalid }
                    guard !isSharedAdapter(server) else { throw LifecycleError.invalid }
                    if action == .remove { servers.removeValue(forKey: entry.name) }
                    else {
                        let enabledKey = account.provider == .opencode && !nested
                        server[enabledKey ? "enabled" : "disabled"] = enabledKey ? action == .enable : action == .disable
                        // Avoid contradictory legacy switches.
                        if server[enabledKey ? "disabled" : "enabled"] != nil {
                            server[enabledKey ? "disabled" : "enabled"] = enabledKey ? action == .disable : action == .enable
                        }
                        servers[entry.name] = server
                    }
                    if nested { container["servers"] = servers; root[key] = container } else { root[key] = servers }
                    after = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                }
            } catch {
                // Parser diagnostics can contain source values.
                throw HarnaisError.processFailed("Could not safely update this installation. Refresh the inventory or use the provider's settings. No changes were saved.")
            }
            guard try Data(contentsOf: url) == before else {
                throw HarnaisError.processFailed("Settings changed during this action. Refresh and try again.")
            }
            let backup = url.appendingPathExtension("harnais-" + UUID().uuidString + ".backup")
            guard FileManager.default.createFile(atPath: backup.path, contents: before, attributes: [.posixPermissions: 0o600]) else { throw LifecycleError.invalid }
            try after.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return backup
        }
    }

    private static func isSharedAdapter(_ server: [String: Any]) -> Bool {
        let args = server["args"] as? [String] ?? Array((server["command"] as? [String] ?? []).dropFirst())
        return args.starts(with: ["mcp", "serve"])
    }

    /// Edits conventional provider tables while keeping other text intact. Parsed
    /// equality verifies that even unusual strings/headers cannot alter other settings.
    private static func updatedTOML(_ text: String, section: String, name: String, action: ConnectionAction) throws -> String {
        var expected = try Dictionary(TOMLTable(source: text))
        var entries = expected[section] as? [String: Any] ?? [:]
        var target = entries[name] as? [String: Any] ?? [:]
        guard !isSharedAdapter(target), action != .remove || entries[name] != nil else { throw LifecycleError.invalid }
        if action == .remove { entries.removeValue(forKey: name) }
        else { target["enabled"] = action == .enable; entries[name] = target }
        expected[section] = entries
        var lines = text.components(separatedBy: "\n")
        var matched = false
        var inTarget = false
        var output: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inTarget = false
                if let table = try? Dictionary(TOMLTable(source: line + "\nharnais_probe = true")),
                   let group = table[section] as? [String: Any], let item = group[name] as? [String: Any],
                   item["harnais_probe"] as? Bool == true {
                    inTarget = true; matched = true
                    if action != .remove { output += [line, "enabled = \(action == .enable ? "true" : "false")"] }
                    continue
                }
            }
            if inTarget {
                if action == .remove { continue }
                if trimmed.range(of: #"^(enabled|"enabled"|'enabled')\s*="# , options: .regularExpression) != nil { continue }
            }
            output.append(line)
        }
        if !matched {
            guard action != .remove else { throw LifecycleError.invalid }
            output += ["", "[\(section).\(CodexMCPToml.quote(name))]", "enabled = \(action == .enable ? "true" : "false")"]
        }
        lines = output
        let result = lines.joined(separator: "\n")
        guard NSDictionary(dictionary: try Dictionary(TOMLTable(source: result))).isEqual(to: expected) else { throw LifecycleError.invalid }
        return result
    }
}

private enum LifecycleError: Error { case invalid }
