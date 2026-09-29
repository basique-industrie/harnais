import Domain
import Foundation

/// On-disk account registry. Atomic JSON replace with a `.backup` sibling.
public struct AccountRegistry: Sendable {
    public var file: AtomicJSONFile
    public var identity: AppIdentity

    public init(identity: AppIdentity = .current) {
        self.identity = identity
        self.file = AtomicJSONFile(fileURL: identity.accountsFileURL)
    }

    public init(fileURL: URL, identity: AppIdentity = .current) {
        self.identity = identity
        self.file = AtomicJSONFile(fileURL: fileURL)
    }

    public func load() throws -> AccountRegistryDocument {
        try file.withLock { try loadUnlocked() }
    }

    public func save(_ document: AccountRegistryDocument) throws {
        try file.withLock { try saveUnlocked(document) }
    }

    public func add(_ account: Account) throws {
        try file.withLock {
            var document = try loadUnlocked()
            if document.accounts.contains(where: { $0.provider == account.provider && $0.slug == account.slug }) {
                throw HarnaisError.duplicateSlug(account.slug)
            }
            document.accounts.append(account)
            try saveUnlocked(document)
        }
    }

    public func update(_ account: Account) throws {
        try file.withLock {
            var document = try loadUnlocked()
            guard let index = document.accounts.firstIndex(where: { $0.id == account.id }) else {
                throw HarnaisError.missingAccount
            }
            document.accounts[index] = account
            try saveUnlocked(document)
        }
    }

    public func remove(id: UUID) throws {
        try file.withLock {
            var document = try loadUnlocked()
            document.accounts.removeAll { $0.id == id }
            try saveUnlocked(document)
        }
    }

    public func accounts() throws -> [Account] {
        try load().accounts
    }

    private func loadUnlocked() throws -> AccountRegistryDocument {
        guard FileManager.default.fileExists(atPath: file.fileURL.path) else {
            return AccountRegistryDocument()
        }
        return try file.readUnlocked(AccountRegistryDocument.self)
    }

    private func saveUnlocked(_ document: AccountRegistryDocument) throws {
        try file.writeUnlocked(document)
    }
}
