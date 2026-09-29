import Domain
import Foundation

/// Creates accounts, materializes homes, and writes wrappers.
public struct AccountService: Sendable {
    public var registry: AccountRegistry
    public var isolation: IsolationEngine
    public var wrappers: WrapperGenerator
    public var metadata: AccountMetadata

    public init(
        registry: AccountRegistry? = nil,
        isolation: IsolationEngine = IsolationEngine(),
        wrappers: WrapperGenerator = WrapperGenerator()
    ) {
        self.registry = registry ?? AccountRegistry()
        self.isolation = isolation
        self.wrappers = wrappers
        self.metadata = AccountMetadata()
    }

    public func create(
        provider: ProviderKind,
        label: String,
        importDefault: Bool = false,
        codexMode: CodexIsolationMode = .isolated
    ) throws -> Account {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HarnaisError.invalidLabel }
        let slug = Slug.make(from: trimmed)
        let plan = isolation.plan(
            provider: provider,
            slug: slug,
            importDefault: importDefault,
            codexMode: provider == .codex ? codexMode : .isolated
        )
        try isolation.materialize(plan)
        let binary = BinaryLocator.resolve(provider, override: nil)
        var account = Account(
            provider: provider,
            label: trimmed,
            slug: slug,
            homePath: plan.homePath,
            shadowHomePath: plan.shadowHomePath,
            binaryPath: binary,
            env: plan.env,
            importedDefault: plan.importedDefault,
            codexMode: plan.codexMode
        )
        account.accountEmail = metadata.email(for: account)
        try registry.add(account)
        if let binary {
            _ = try wrappers.write(for: account, binaryPath: binary)
        }
        return account
    }

    public func importDefaults() throws -> [Account] {
        var imported: [Account] = []
        let existing = try registry.accounts()
        let homes: [(ProviderKind, String)] = [
            (.claude, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path),
            (.codex, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path),
            (.cursor, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor").path),
            (.opencode, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode").path),
        ]
        for (provider, path) in homes {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if existing.contains(where: { $0.provider == provider && $0.importedDefault }) {
                continue
            }
            let account = try create(provider: provider, label: "Default", importDefault: true)
            imported.append(account)
        }
        return imported
    }

    public func rename(_ account: Account, label: String) throws -> Account {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HarnaisError.invalidLabel }
        var updated = account
        updated.label = trimmed
        try registry.update(updated)
        return updated
    }

    public func refreshMetadata(_ account: Account) throws -> Account {
        var updated = account
        updated.accountEmail = metadata.email(for: account)
        if metadata.appearsSignedIn(account) {
            updated.lastLoginAt = Date()
        }
        try registry.update(updated)
        if let binary = BinaryLocator.resolve(account.provider, override: account.binaryPath) {
            _ = try wrappers.write(for: updated, binaryPath: binary)
        }
        return updated
    }

    public func remove(_ account: Account) throws {
        try registry.remove(id: account.id)
        wrappers.remove(for: account)
        isolation.removeManagedHomes(for: account)
    }
}
