import Foundation

public enum InventoryKind: String, CaseIterable, Sendable {
    case plugin = "Plugin"
    case integration = "Integration"
    case mcp = "MCP"
}

public enum ConnectionOrigin: String, CaseIterable, Sendable {
    case shared = "Shared"
    case added = "Added"
    case builtIn = "Built-in"
}

/// Display metadata only. Never contains commands, arguments, environment values or tokens.
public struct InventoryEntry: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: InventoryKind
    public var source: String
    public var scope: String
    public var state: String
    public var warnings: [String]
    public var supportsLogin = false
    /// Provider activation evidence, without credentials or project paths.
    public var activationDetail: String?
    /// Evidence from the configured executable, never inferred from the server name.
    public var providerRuntime: String?

    public var isCachedOnly: Bool {
        state == "Cached" || warnings.contains { $0 == "Bundled with a cached plugin. Activation has not been checked." }
    }
    public var isInactive: Bool {
        state == "Disabled" || state == "Disabled in known projects" ||
            warnings.contains { $0.hasPrefix("The parent plugin is not enabled") }
    }

    /// Cached and intentionally disabled plugins are inventory information, not failures.
    public var actionableWarnings: [String] {
        warnings.filter { warning in
            !["Disabled in this account.", "Installed plugin has no account enablement setting. Check its status in Claude.", "The parent plugin is not enabled in this account’s settings.",
              "The parent plugin is not enabled in this account's settings.",
              "Cached files do not confirm that this plugin is enabled.",
              "Check whether this plugin is enabled in Cursor. Its cache does not record activation.",
              "Bundled with a cached plugin. Activation has not been checked."].contains(warning)
        }
    }

    public var presentationState: String {
        if state == "Disabled in known projects" { return state }
        if isInactive { return "Disabled" }
        if state == "Cached" || parentPlugin != nil && warnings.contains(where: { $0.contains("Activation has not been checked") || $0.contains("cache does not record activation") }) { return "Activation unverified" }
        return state
    }

    public var parentPlugin: String? {
        guard scope.hasPrefix("Plugin: ") else { return nil }
        return String(scope.dropFirst(8).components(separatedBy: " · Project:")[0])
    }

    public var origin: ConnectionOrigin {
        if state == "Shared by Harnais" || scope == "Shared by Harnais" { return .shared }
        // Official marketplace plugins are still Added. Only the provider's bundled
        // distribution identifies a built-in plugin.
        if providerRuntime != nil { return .builtIn }
        if (parentPlugin ?? name).hasSuffix("@openai-bundled") || source.contains("/plugins/cache/openai-bundled/") {
            return .builtIn
        }
        return .added
    }

    public var catalogName: String { parentPlugin ?? name }

    public var displayName: String {
        Self.displayName(catalogName)
    }

    public static func displayName(_ name: String) -> String {
        let base = name.components(separatedBy: "@")[0]
        let names = ["clangd-lsp": "clangd LSP", "pyright-lsp": "Pyright LSP", "rust-analyzer-lsp": "rust-analyzer LSP", "swift-lsp": "Swift LSP", "ty-lsp": "ty LSP", "pdf": "PDF", "node-repl": "Node REPL", "openai-templates": "OpenAI Templates"]
        if let label = names[base] { return label }
        if let kind = IntegrationKind.allCases.first(where: { $0 != .custom && base == $0.rawValue }) {
            return kind.displayName
        }
        return base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// A presentation identity, never an assertion that credentials or capabilities match.
    public static func serviceName(_ name: String) -> String {
        var base = name.components(separatedBy: "@")[0].lowercased().replacingOccurrences(of: "_", with: "-")
        for suffix in ["-cursor-plugin", "-claude-plugin", "-codex-plugin"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        switch base {
        case "atlassian-rovo", "rovo", "jira", "confluence": return "atlassian"
        case "gdrive", "google-drive-mcp": return "google-drive"
        case "microsoft-outlook", "outlook-email": return "outlook"
        default:
            if base == "grafana" || base.hasPrefix("grafana-") { return "grafana" }
            return base
        }
    }

    public init(name: String, kind: InventoryKind, source: String, scope: String = "Account",
                state: String = "Configured", warnings: [String] = []) {
        self.id = "\(source)|\(scope)|\(kind.rawValue)|\(name)"
        self.name = name
        self.kind = kind
        self.source = source
        self.scope = scope
        self.state = state
        self.warnings = warnings
    }
}

public struct AccountConnectionInventory: Identifiable, Sendable, Equatable {
    public var accountID: UUID
    public var entries: [InventoryEntry]
    public var warnings: [String]
    public var id: UUID { accountID }
    public var notes: [String] = []
    public var warningCount: Int { warnings.count + entries.reduce(0) { $0 + $1.warnings.count } }

    public init(accountID: UUID, entries: [InventoryEntry] = [], warnings: [String] = []) {
        self.accountID = accountID
        self.entries = entries
        self.warnings = warnings
    }
}

public struct ConnectionOccurrence: Identifiable, Sendable {
    public var account: Account
    public var entry: InventoryEntry
    public var id: String { "\(account.id)|\(entry.id)" }
}

public struct CatalogConnection: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var origin: ConnectionOrigin
    public var occurrences: [ConnectionOccurrence]
    public var accountCount: Int { Set(occurrences.map { $0.account.id }).count }
    public var warningCount: Int { occurrences.filter { !$0.entry.actionableWarnings.isEmpty }.count }
    public var providers: [ProviderKind] {
        ProviderKind.allCases.filter { provider in occurrences.contains { $0.account.provider == provider } }
    }
    /// Consolidates presentation only; the related provider entries remain manageable.
    public func sharedConnection(in connections: [IntegrationConnection]) -> IntegrationConnection? {
        guard origin == .added else { return nil }
        return connections.first { $0.kind != .custom && $0.kind.rawValue == name }
    }
    public var displayName: String { InventoryEntry.displayName(name) }
    public var isProviderPlugin: Bool { occurrences.contains { $0.entry.kind == .plugin || $0.entry.parentPlugin != nil } }
    public var providerLabel: String { providers.map(\.displayName).joined(separator: ", ") }
    public var ownershipLabel: String {
        let kinds = InventoryKind.allCases.filter { kind in occurrences.contains { $0.entry.kind == kind } }
        return "\(providerLabel) · \(kinds.map(\.rawValue).joined(separator: " + "))"
    }

    public static func build(accounts: [Account], inventory: [AccountConnectionInventory]) -> [CatalogConnection] {
        var result: [String: CatalogConnection] = [:]
        for group in inventory {
            guard let account = accounts.first(where: { $0.id == group.accountID }) else { continue }
            for entry in group.entries where entry.origin != .shared {
                let name = InventoryEntry.serviceName(entry.catalogName)
                let key = "service|\(name)"
                if result[key] == nil {
                    result[key] = CatalogConnection(id: key, name: name,
                        origin: entry.origin, occurrences: [])
                }
                result[key]?.occurrences.append(ConnectionOccurrence(account: account, entry: entry))
                if entry.origin == .builtIn { result[key]?.origin = .builtIn }
            }
        }
        return result.values.sorted {
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}

/// Separates transport configurations from retained plugin capabilities and cache records.
/// Cache presence never establishes that a second connection is active.
public struct SharedProviderInventory: Sendable {
    public let configuredConnections: [ConnectionOccurrence]
    public let extensions: [ConnectionOccurrence]
    public let inactive: [ConnectionOccurrence]

    public init(occurrences: [ConnectionOccurrence]) {
        configuredConnections = occurrences.filter { $0.entry.kind != .plugin && !$0.entry.isCachedOnly && !$0.entry.isInactive }
        extensions = occurrences.filter { $0.entry.kind == .plugin && !$0.entry.isCachedOnly && !$0.entry.isInactive }
        inactive = occurrences.filter { $0.entry.isCachedOnly || $0.entry.isInactive }
    }
}
