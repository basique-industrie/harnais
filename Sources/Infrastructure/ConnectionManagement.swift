import Domain
import Foundation
import TOMLDecoder

public enum ConnectionManagement {
    public static func settingsURL(account: Account, entry: InventoryEntry) -> URL {
        let home = URL(fileURLWithPath: account.shadowHomePath ?? account.homePath)
        if entry.kind == .plugin || entry.parentPlugin != nil || entry.source.contains("/plugins/cache/") {
            switch account.provider {
            case .claude:
                return URL(fileURLWithPath: account.env["CLAUDE_CONFIG_DIR"] ?? home.path).appendingPathComponent("settings.json")
            case .codex:
                return URL(fileURLWithPath: account.env["CODEX_HOME"] ?? home.path).appendingPathComponent("config.toml")
            case .cursor:
                return URL(fileURLWithPath: account.env["CURSOR_CONFIG_DIR"] ?? home.path).appendingPathComponent("mcp.json")
            case .opencode:
                return URL(fileURLWithPath: entry.source)
            }
        }
        return URL(fileURLWithPath: entry.source)
    }

    /// Read only the endpoint for migration. Never copy another client's OAuth credentials.
    public static func remoteEndpoint(_ entry: InventoryEntry, provider: ProviderKind) -> String? {
        guard entry.supportsLogin, let data = try? Data(contentsOf: URL(fileURLWithPath: entry.source)) else { return nil }
        let root: [String: Any]?
        if entry.source.hasSuffix(".toml") {
            root = try? Dictionary(TOMLTable(source: String(decoding: data, as: UTF8.self)))
        } else {
            root = (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any]
        }
        guard let root else { return nil }
        var container = root
        if entry.scope.hasPrefix("Project: ") {
            let project = String(entry.scope.dropFirst(9))
            container = (root["projects"] as? [String: [String: Any]])?[project] ?? [:]
        }
        var servers = container["mcp_servers"] as? [String: Any]
            ?? container["mcpServers"] as? [String: Any]
            ?? container["mcp"] as? [String: Any] ?? container
        if provider == .opencode, let nested = servers["servers"] as? [String: Any] { servers = nested }
        let settings = servers[entry.name] as? [String: Any]
        guard let url = settings?["url"] as? String, (try? SharedMCPURL.parse(url)) != nil else { return nil }
        return url
    }

    public static func loginCommand(account: Account, entry: InventoryEntry,
                                    isolation: IsolationEngine = IsolationEngine()) throws -> LoginCommand {
        guard entry.origin != .shared, entry.supportsLogin else {
            throw HarnaisError.processFailed("This connection does not advertise a separate OAuth login. Configure credentials in its settings.")
        }
        guard let binary = BinaryLocator.resolve(account.provider, override: account.binaryPath) else {
            throw HarnaisError.binaryNotFound(account.provider.defaultBinaryName)
        }
        var name = entry.name
        if let plugin = entry.parentPlugin {
            guard account.provider == .claude else {
                throw HarnaisError.processFailed("Manage this plugin's sign-in inside \(account.provider.displayName).")
            }
            name = "plugin:\(plugin.components(separatedBy: "@")[0]):\(entry.name)"
        }
        let arguments = ["mcp", account.provider == .opencode ? "auth" : "login", name]
        let project = entry.scope.components(separatedBy: "Project: ").dropFirst().first
        let directory = project ?? account.shadowHomePath ?? account.homePath
        return LoginCommand(executable: binary, arguments: arguments,
                            environment: isolation.spawnEnvironment(for: account), workingDirectory: directory)
    }
}
