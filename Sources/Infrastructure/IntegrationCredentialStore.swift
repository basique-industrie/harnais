import Domain
import Foundation

public struct OAuthTokenSet: Codable, Sendable, Equatable {
    public var clientId: String?
    public var clientSecret: String?
    public var tokenEndpoint: String?
    public var authorizationEndpoint: String?
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var tokenType: String
    public var scope: String?
    public var resource: String?
    public var idToken: String?

    public init(
        clientId: String? = nil,
        clientSecret: String? = nil,
        tokenEndpoint: String? = nil,
        authorizationEndpoint: String? = nil,
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        tokenType: String = "Bearer",
        scope: String? = nil,
        resource: String? = nil,
        idToken: String? = nil
    ) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.tokenEndpoint = tokenEndpoint
        self.authorizationEndpoint = authorizationEndpoint
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.scope = scope
        self.resource = resource
        self.idToken = idToken
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

public struct GrafanaTokenSet: Codable, Sendable, Equatable {
    public var url: String
    public var token: String

    public init(url: String, token: String) {
        self.url = url
        self.token = token
    }
}

public enum IntegrationSecret: Sendable, Equatable {
    case oauth(OAuthTokenSet)
    case grafana(GrafanaTokenSet)

    public var oauth: OAuthTokenSet? {
        if case .oauth(let tokens) = self { return tokens }
        return nil
    }

    public var grafana: GrafanaTokenSet? {
        if case .grafana(let tokens) = self { return tokens }
        return nil
    }
}

// Natural format: {"oauth": {...}} / {"grafana": {...}}. The synthesized
// Codable used to wrap payloads in {"_0": ...}; the decoder still accepts
// those legacy files, but all new saves use the flat shape.
extension IntegrationSecret: Codable {
    private enum Key: String, CodingKey {
        case oauth
        case grafana
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .oauth(let tokens):
            try container.encode(tokens, forKey: .oauth)
        case .grafana(let tokens):
            try container.encode(tokens, forKey: .grafana)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        if container.contains(.oauth) {
            if let legacy = try? container.decode([String: OAuthTokenSet].self, forKey: .oauth),
               let tokens = legacy["_0"]
            {
                self = .oauth(tokens)
                return
            }
            self = .oauth(try container.decode(OAuthTokenSet.self, forKey: .oauth))
        } else if container.contains(.grafana) {
            if let legacy = try? container.decode([String: GrafanaTokenSet].self, forKey: .grafana),
               let tokens = legacy["_0"]
            {
                self = .grafana(tokens)
                return
            }
            self = .grafana(try container.decode(GrafanaTokenSet.self, forKey: .grafana))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected an 'oauth' or 'grafana' credential."
                )
            )
        }
    }
}

public struct IntegrationCredentialStore: Sendable {
    public var identity: AppIdentity

    public init(identity: AppIdentity = .current) {
        self.identity = identity
    }

    public func load(for connection: IntegrationConnection) throws -> IntegrationSecret {
        let url = identity.integrationCredentialsURL(kind: connection.kind, slug: connection.slug)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HarnaisError.notLoggedIn
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IntegrationSecret.self, from: data)
    }

    public func save(_ secret: IntegrationSecret, for connection: IntegrationConnection) throws {
        let url = identity.integrationCredentialsURL(kind: connection.kind, slug: connection.slug)
        try AtomicJSONFile(fileURL: url).withLock(timeout: 45) {
            try saveUnlocked(secret, for: connection)
        }
    }

    /// All provider processes use this lock. A rejected old token must not rotate
    /// a refresh token that another provider has already replaced.
    public func authorizedTokens(
        for connection: IntegrationConnection,
        rejectedAccessToken: String? = nil,
        refresh: (OAuthTokenSet) throws -> OAuthTokenSet
    ) throws -> OAuthTokenSet {
        let url = identity.integrationCredentialsURL(kind: connection.kind, slug: connection.slug)
        return try AtomicJSONFile(fileURL: url).withLock(timeout: 45) {
            guard var tokens = try load(for: connection).oauth, !tokens.accessToken.isEmpty else { throw HarnaisError.notLoggedIn }
            // Gmail and Drive moved from Google's preview MCP services to stable APIs.
            // Only migrate the known Google resource and Google token issuer.
            if connection.endpointURL == nil,
               (connection.kind == .gmail && tokens.resource == "https://gmailmcp.googleapis.com/mcp/v1" ||
                connection.kind == .googleDrive && tokens.resource == "https://drivemcp.googleapis.com/mcp/v1"),
               tokens.tokenEndpoint == "https://oauth2.googleapis.com/token" {
                tokens.resource = nil
                try saveUnlocked(.oauth(tokens), for: connection)
            }
            if let resource = tokens.resource, !OAuthResource.contains(endpoint: connection.mcpURL, resource: resource) {
                throw HarnaisError.oauthFailed("This login belongs to a different server. Sign in again in Harnais.")
            }
            if tokens.isExpired || (rejectedAccessToken != nil && rejectedAccessToken == tokens.accessToken) {
                tokens = try refresh(tokens)
                try saveUnlocked(.oauth(tokens), for: connection)
            }
            return tokens
        }
    }

    public func updateOAuth(for connection: IntegrationConnection,
                            update: (inout OAuthTokenSet) throws -> Void) throws -> OAuthTokenSet {
        let url = identity.integrationCredentialsURL(kind: connection.kind, slug: connection.slug)
        return try AtomicJSONFile(fileURL: url).withLock(timeout: 45) {
            var tokens = (try? load(for: connection).oauth) ?? OAuthTokenSet(accessToken: "")
            try update(&tokens)
            try saveUnlocked(.oauth(tokens), for: connection)
            return tokens
        }
    }

    private func saveUnlocked(_ secret: IntegrationSecret, for connection: IntegrationConnection) throws {
        let url = identity.integrationCredentialsURL(kind: connection.kind, slug: connection.slug)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(secret)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    }

    public func remove(for connection: IntegrationConnection) {
        let url = identity.integrationCredentialsURL(kind: connection.kind, slug: connection.slug)
        try? AtomicJSONFile(fileURL: url).withLock(timeout: 45) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
