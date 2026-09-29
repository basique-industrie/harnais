import Domain
import Foundation

public struct IntegrationRegistry: Sendable {
    public var file: AtomicJSONFile
    public var identity: AppIdentity

    public init(identity: AppIdentity = .current) {
        self.identity = identity
        self.file = AtomicJSONFile(fileURL: identity.integrationsFileURL)
    }

    public init(fileURL: URL, identity: AppIdentity = .current) {
        self.identity = identity
        self.file = AtomicJSONFile(fileURL: fileURL)
    }

    public func load() throws -> IntegrationRegistryDocument {
        try file.withLock { try loadUnlocked() }
    }

    public func save(_ document: IntegrationRegistryDocument) throws {
        try file.withLock { try saveUnlocked(document) }
    }

    public func connections() throws -> [IntegrationConnection] {
        try load().connections
    }

    public func connection(id: UUID) throws -> IntegrationConnection? {
        try connections().first { $0.id == id }
    }

    public func connection(mcpName: String) throws -> IntegrationConnection? {
        try connections().first { $0.mcpName == mcpName }
    }

    public func add(_ connection: IntegrationConnection) throws {
        try file.withLock {
            var document = try loadUnlocked()
            if document.connections.contains(where: { $0.kind == connection.kind && $0.slug == connection.slug }) {
                throw HarnaisError.duplicateIntegration(connection.slug)
            }
            if document.connections.contains(where: { $0.mcpName == connection.mcpName }) {
                throw HarnaisError.duplicateIntegration(connection.mcpName)
            }
            document.connections.append(connection)
            try saveUnlocked(document)
        }
    }

    public func update(_ connection: IntegrationConnection) throws {
        try file.withLock {
            var document = try loadUnlocked()
            guard let index = document.connections.firstIndex(where: { $0.id == connection.id }) else {
                throw HarnaisError.missingAccount
            }
            document.connections[index] = connection
            try saveUnlocked(document)
        }
    }

    public func remove(id: UUID) throws {
        try file.withLock {
            var document = try loadUnlocked()
            document.connections.removeAll { $0.id == id }
            try saveUnlocked(document)
        }
    }

    private func loadUnlocked() throws -> IntegrationRegistryDocument {
        guard FileManager.default.fileExists(atPath: file.fileURL.path) else {
            return IntegrationRegistryDocument()
        }
        return try file.readUnlocked(IntegrationRegistryDocument.self)
    }

    private func saveUnlocked(_ document: IntegrationRegistryDocument) throws {
        try file.writeUnlocked(document)
    }
}

public struct OAuthClientsStore: Sendable {
    public var file: AtomicJSONFile

    public init(identity: AppIdentity = .current) {
        self.file = AtomicJSONFile(fileURL: identity.oauthClientsFileURL)
    }

    public init(fileURL: URL) {
        self.file = AtomicJSONFile(fileURL: fileURL)
    }

    public func load() throws -> OAuthClientsDocument {
        guard FileManager.default.fileExists(atPath: file.fileURL.path) else {
            return OAuthClientsDocument()
        }
        return try file.read(OAuthClientsDocument.self)
    }

    public func save(_ document: OAuthClientsDocument) throws {
        try file.write(document)
    }

    public func record(for kind: IntegrationKind, scope: OAuthRegistrationScope? = nil) throws -> OAuthClientRecord? {
        try load().clients[Self.key(kind, scope: scope)]
    }

    private static func key(_ kind: IntegrationKind, scope: OAuthRegistrationScope?) -> String {
        scope.map { "\(kind.rawValue):\($0.rawValue)" } ?? kind.rawValue
    }

    public func upsert(kind: IntegrationKind, scope: OAuthRegistrationScope? = nil, record: OAuthClientRecord) throws {
        try file.withLock {
            var document = FileManager.default.fileExists(atPath: file.fileURL.path)
                ? try file.readUnlocked(OAuthClientsDocument.self) : OAuthClientsDocument()
            document.clients[Self.key(kind, scope: scope)] = record
            try file.writeUnlocked(document)
        }
    }
}

public struct MCPApplyStore: Sendable {
    public var file: AtomicJSONFile

    public init(identity: AppIdentity = .current) {
        self.file = AtomicJSONFile(fileURL: identity.mcpApplyFileURL)
    }

    public init(fileURL: URL) {
        self.file = AtomicJSONFile(fileURL: fileURL)
    }

    public func load() throws -> MCPApplyState {
        guard FileManager.default.fileExists(atPath: file.fileURL.path) else {
            return MCPApplyState()
        }
        return try file.read(MCPApplyState.self)
    }

    public func save(_ state: MCPApplyState) throws {
        try file.write(state)
    }
}
