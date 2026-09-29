import Foundation

/// Hosted MCP products Harnais can own across Claude, Codex, Cursor, and T3.
public enum IntegrationKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case googleDrive = "google-drive"
    case gmail
    case whatsapp
    case aikido
    case excalidraw
    case outlook
    case slack
    case grafana
    case atlassian
    case custom = "custom-mcp"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .googleDrive: "Google Drive"
        case .gmail: "Gmail"
        case .whatsapp: "WhatsApp"
        case .aikido: "Aikido"
        case .excalidraw: "Excalidraw"
        case .outlook: "Outlook"
        case .slack: "Slack"
        case .grafana: "Grafana"
        case .atlassian: "Atlassian"
        case .custom: "Custom MCP"
        }
    }

    public var summary: String {
        switch self {
        case .whatsapp: "Search chats and send requested messages through one linked device."
        case .aikido: "Scan code and review security issues with one Aikido login."
        case .excalidraw: "Create diagrams with the official server or your existing local canvas."
        case .custom:
            "Connect a remote MCP server once and share its login."
        case .gmail:
            "Search and read Gmail from your coding accounts."
        case .outlook:
            "Search and read Outlook mail from your coding accounts."
        case .googleDrive:
            "Search and read Drive files from every harness."
        case .slack:
            "Search and read Slack from your coding accounts."
        case .grafana:
            "Query Grafana datasources, dashboards, and incidents."
        case .atlassian:
            "Jira and Confluence through Atlassian’s MCP server."
        }
    }

    public var authKind: IntegrationAuthKind {
        switch self {
        case .grafana: .token
        case .aikido, .whatsapp: .vendor
        case .excalidraw: .none
        case .googleDrive, .gmail, .outlook, .slack, .atlassian, .custom: .oauth
        }
    }

    public var canonicalMcpName: String { rawValue }

    public var mcpURL: URL {
        switch self {
        case .whatsapp: URL(string: "https://www.whatsapp.com")!
        case .aikido: URL(string: "https://app.aikido.dev")!
        case .excalidraw: URL(string: "https://mcp.excalidraw.com/mcp")!
        case .gmail: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
        case .outlook: URL(string: "https://graph.microsoft.com/v1.0/me")!
        case .googleDrive: URL(string: "https://www.googleapis.com/drive/v3")!
        case .slack: URL(string: "https://mcp.slack.com/mcp")!
        case .grafana: URL(string: "https://grafana.com")!
        case .atlassian: URL(string: "https://mcp.atlassian.com/v2/mcp")!
        case .custom: URL(string: "https://example.invalid/mcp")!
        }
    }

    public var defaultScopes: [String] {
        switch self {
        case .gmail:
            ["https://www.googleapis.com/auth/gmail.readonly", "openid", "email"]
        case .outlook:
            ["https://graph.microsoft.com/Mail.Read", "openid", "profile", "email", "offline_access"]
        case .googleDrive:
            [
                "https://www.googleapis.com/auth/drive.readonly",
                "https://www.googleapis.com/auth/drive.file",
                "openid",
                "email",
            ]
        case .slack:
            ["search:read.public", "search:read.private", "search:read.im", "search:read.mpim",
             "search:read.files", "search:read.users", "files:read", "channels:history", "groups:history",
             "im:history", "mpim:history", "users:read", "users:read.email", "emoji:read"]
        case .grafana, .aikido, .excalidraw, .whatsapp:
            []
        case .atlassian, .custom:
            []
        }
    }

    public var needsRegisteredOAuthClient: Bool {
        switch self {
        case .googleDrive, .gmail, .outlook, .slack: true
        case .atlassian, .grafana, .custom, .aikido, .excalidraw, .whatsapp: false
        }
    }

    public var clientSecretRequired: Bool {
        switch self {
        case .googleDrive, .gmail, .slack: true
        case .outlook, .atlassian, .grafana, .custom, .aikido, .excalidraw, .whatsapp: false
        }
    }

    public var oauthSetupHint: String {
        switch self {
        case .whatsapp: "Link Harnais from WhatsApp on your phone. One local session is shared with your selected accounts. Uses the unofficial whatsmeow client, not Meta's Business API."
        case .aikido: "Aikido manages browser sign-in and stores the shared login in macOS Keychain. No Harnais OAuth registration is needed."
        case .excalidraw: "The official diagram server needs no login. Local canvas mode preserves the separate canvas tools."
        case .gmail:
            "Use the Harnais Google app with Gmail read-only access. Custom apps need Gmail API enabled. While Google verification is pending, add your account as a test user."
        case .outlook:
            "Use a Microsoft Entra public desktop client with delegated Mail.Read permission and the Harnais loopback callback."
        case .googleDrive:
            "Use the Harnais Google app with Drive, Sheets, Docs and Slides APIs enabled. No Developer Preview is needed. During Google testing, add your account as a test user. Default permissions read Drive and edit files created or opened with Harnais."
        case .slack:
            "Create an internal Slack app named Harnais for your workspace. Under OAuth & Permissions, add \(IntegrationOAuth.redirectURI) exactly (127.0.0.1, not localhost), then paste its Client ID and Secret. IDs imported from Cursor belong to Cursor's app and are rejected here."
        case .custom:
            "Use a Streamable HTTP endpoint. Harnais signs in with its own OAuth client. If the server does not support registration, provide a client ID registered for the redirect below."
        case .atlassian:
            "Harnais registers itself with Atlassian on first sign-in."
        case .grafana:
            "Paste a Grafana URL and a service-account token. Install mcp-grafana on PATH."
        }
    }
}

public enum IntegrationAuthKind: String, Codable, Sendable {
    case vendor
    case none
    case oauth
    case token
}

public enum IntegrationOAuth {
    public static let callbackPort: UInt16 = 8788
    public static let redirectURI = "http://127.0.0.1:8788/callback"
}

public enum IntegrationDebug {
    /// Local e2e / test aid: when set, `harnais mcp serve` proxies every
    /// kind to this URL instead of the vendor endpoint. Never set in
    /// production; nothing else reads it.
    public static var mcpURLOverride: URL? {
        ProcessInfo.processInfo.environment["HARNAIS_MCP_URL_OVERRIDE"].flatMap(URL.init(string:))
    }
}

/// One signed-in MCP connection. Secrets live beside this row, not inside it.
public struct IntegrationConnection: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var kind: IntegrationKind
    public var label: String
    public var slug: String
    public var mcpName: String
    public var createdAt: Date
    public var lastLoginAt: Date?
    public var accountLabel: String?
    public var grafanaURL: String?
    public var endpointURL: String?
    /// Preserve the existing canvas server separately from the official remote diagram service.
    public var localCanvas: Bool?
    /// Preserve account-specific Grafana write restrictions during migration.
    public var readOnlyAccountIDs: [UUID]?
    /// Account opt-outs persist across syncs. Missing in older registries means all accounts.
    public var excludedAccountIDs: [UUID]?

    public var mcpURL: URL { endpointURL.flatMap(URL.init(string:)) ?? kind.mcpURL }
    /// When true, "Sync to harnesses" skips this connection. Nil decodes as
    /// false so registries written before this field keep working.
    public var isExcludedFromApply: Bool?

    public init(
        id: UUID = UUID(),
        kind: IntegrationKind,
        label: String,
        slug: String,
        mcpName: String,
        createdAt: Date = Date(),
        lastLoginAt: Date? = nil,
        accountLabel: String? = nil,
        grafanaURL: String? = nil,
        endpointURL: String? = nil,
        isExcludedFromApply: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.slug = slug
        self.mcpName = mcpName
        self.createdAt = createdAt
        self.lastLoginAt = lastLoginAt
        self.accountLabel = accountLabel
        self.grafanaURL = grafanaURL
        self.endpointURL = endpointURL
        self.isExcludedFromApply = isExcludedFromApply
    }

    public var isSignedIn: Bool { lastLoginAt != nil }

    public var excludedFromApply: Bool { isExcludedFromApply ?? false }
    public func isEnabled(for accountID: UUID) -> Bool {
        !excludedFromApply && !(excludedAccountIDs ?? []).contains(accountID)
    }
}

public struct IntegrationRegistryDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var connections: [IntegrationConnection]

    public init(schemaVersion: Int = 1, connections: [IntegrationConnection] = []) {
        self.schemaVersion = schemaVersion
        self.connections = connections
    }
}

public enum OAuthConnectionMode: String, Sendable {
    case harnais
    case custom
}

public struct OAuthClientRecord: Codable, Sendable, Equatable {
    public var clientId: String
    public var clientSecret: String?

    /// Only native registrations can omit a confidential client secret.
    public var isPublicClient: Bool?
    /// Explicit scope set for a custom registration; nil uses the service defaults.
    public var scopes: [String]?

    public init(clientId: String, clientSecret: String? = nil, isPublicClient: Bool? = nil, scopes: [String]? = nil) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.isPublicClient = isPublicClient
        self.scopes = scopes
    }
}

public struct OAuthClientsDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var clients: [String: OAuthClientRecord]

    public init(schemaVersion: Int = 1, clients: [String: OAuthClientRecord] = [:]) {
        self.schemaVersion = schemaVersion
        self.clients = clients
    }

    public func record(for kind: IntegrationKind) -> OAuthClientRecord? {
        clients[kind.rawValue]
    }
}

public struct MCPApplyState: Codable, Sendable, Equatable {
    public var mcpNames: [String]
    public var commandPath: String?
    public var appliedAt: Date?
    /// Harness files written by the last apply. Nil for states saved before
    /// this field existed; the probe treats it as "unknown", not "none".
    public var files: [String]?

    public init(mcpNames: [String] = [], commandPath: String? = nil, appliedAt: Date? = nil, files: [String]? = nil) {
        self.mcpNames = mcpNames
        self.commandPath = commandPath
        self.appliedAt = appliedAt
        self.files = files
    }
}

public struct MCPApplyReport: Sendable, Equatable {
    public var files: [String]
    public var mcpNames: [String]
    public var commandPath: String

    public init(files: [String], mcpNames: [String], commandPath: String) {
        self.files = files
        self.mcpNames = mcpNames
        self.commandPath = commandPath
    }

    public var summary: String {
        if mcpNames.isEmpty {
            return "Removed Harnais MCP entries from \(files.count) harness file\(files.count == 1 ? "" : "s")."
        }
        let names = mcpNames.joined(separator: ", ")
        return "Wired \(names) into \(files.count) harness file\(files.count == 1 ? "" : "s")."
    }
}

public enum IntegrationNaming {
    public static func suggestedLabel(for kind: IntegrationKind, existing: [IntegrationConnection]) -> String {
        let used = Set(
            existing
                .filter { $0.kind == kind }
                .map { $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        let candidates: [String]
        switch kind {
        case .grafana:
            candidates = ["Prod", "Staging", "Ephemeral", "Personal"]
        case .googleDrive, .gmail, .outlook, .slack, .atlassian, .custom, .aikido, .excalidraw, .whatsapp:
            candidates = ["Personal", "Work", "Home"]
        }
        return candidates.first { !used.contains($0.lowercased()) } ?? "Account"
    }

    public static func humanizeMcpName(_ name: String, kind: IntegrationKind) -> String {
        let prefix = kind.canonicalMcpName
        if name == prefix { return "Default" }
        if name.hasPrefix(prefix + "-") {
            let rest = String(name.dropFirst(prefix.count + 1))
            if rest.isEmpty { return "Default" }
            return rest.split(separator: "-").map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: " ")
        }
        return name
    }

    public static func assignMcpName(
        kind: IntegrationKind,
        slug: String,
        existing: [IntegrationConnection],
        preferred: String? = nil
    ) -> String {
        let taken = Set(existing.map(\.mcpName))
        if let preferred, !preferred.isEmpty, !taken.contains(preferred) {
            return preferred
        }
        if !taken.contains(kind.canonicalMcpName) {
            return kind.canonicalMcpName
        }
        var candidate = "\(kind.canonicalMcpName)-\(slug)"
        var index = 2
        while taken.contains(candidate) {
            candidate = "\(kind.canonicalMcpName)-\(slug)-\(index)"
            index += 1
        }
        return candidate
    }
}
