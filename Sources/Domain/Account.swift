import Foundation

/// One named account profile. Secrets stay in the vendor store for `homePath`.
public struct Account: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var provider: ProviderKind
    public var label: String
    public var slug: String
    public var homePath: String
    public var shadowHomePath: String?
    public var binaryPath: String?
    public var env: [String: String]
    public var accountEmail: String?
    public var createdAt: Date
    public var lastLoginAt: Date?
    public var importedDefault: Bool
    public var codexMode: CodexIsolationMode?
    /// Optional fields keep existing registries compatible. Unknown future colors are ignored.
    public var accentColor: String?
    public var managesT3Color: Bool?

    public init(
        id: UUID = UUID(),
        provider: ProviderKind,
        label: String,
        slug: String,
        homePath: String,
        shadowHomePath: String? = nil,
        binaryPath: String? = nil,
        env: [String: String] = [:],
        accountEmail: String? = nil,
        createdAt: Date = Date(),
        lastLoginAt: Date? = nil,
        importedDefault: Bool = false,
        codexMode: CodexIsolationMode? = nil,
        accentColor: String? = nil,
        managesT3Color: Bool? = nil
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.slug = slug
        self.homePath = homePath
        self.shadowHomePath = shadowHomePath
        self.binaryPath = binaryPath
        self.env = env
        self.accountEmail = accountEmail
        self.createdAt = createdAt
        self.lastLoginAt = lastLoginAt
        self.importedDefault = importedDefault
        self.codexMode = codexMode
        self.accentColor = accentColor
        self.managesT3Color = managesT3Color
    }

    public var wrapperName: String {
        "\(provider.wrapperPrefix)-\(slug)"
    }

    public var t3InstanceID: String {
        "harnais_\(provider.rawValue)_\(slug)"
            .replacingOccurrences(of: "-", with: "_")
    }

    /// Sidebar chips and window titles: never lead with a one-letter name.
    public func displayLabel(email: String? = nil) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if AccountNaming.isReadable(trimmed) { return trimmed }
        if let mailbox = JWTPayload.mailbox(email) ?? JWTPayload.mailbox(accountEmail) {
            let local = mailbox.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map(String.init)
            if let local, AccountNaming.isReadable(local) { return local }
        }
        return provider.displayName
    }
}

/// How this account relates to T3 Settings → Providers.
public enum T3AccountPlacement: String, Sendable, Equatable {
    case nativeDefault
    case merged
    case notMerged
}

/// Sidebar and add-sheet grouping for multiple accounts of one CLI.
public struct AccountProviderGroup: Equatable, Sendable, Identifiable {
    public var provider: ProviderKind
    public var accounts: [Account]

    public var id: ProviderKind { provider }

    public init(provider: ProviderKind, accounts: [Account]) {
        self.provider = provider
        self.accounts = accounts
    }
}

public enum AccountNaming {
    public static func suggestedLabel(for provider: ProviderKind, existing: [Account]) -> String {
        let used = Set(
            existing
                .filter { $0.provider == provider }
                .map { $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        for candidate in ["Personal", "Work", "Home"] where !used.contains(candidate.lowercased()) {
            return candidate
        }
        return "Account"
    }

    public static func isReadable(_ label: String) -> Bool {
        label.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    /// Hide the mailbox line when the visible name already is that mailbox.
    public static func shouldShowMailbox(visibleName: String, email: String?) -> Bool {
        guard let email, !email.isEmpty else { return false }
        return visibleName.caseInsensitiveCompare(email) != .orderedSame
    }
}

public extension Array where Element == Account {
    func groupedByProvider() -> [AccountProviderGroup] {
        ProviderKind.allCases.compactMap { kind in
            let accounts = filter { $0.provider == kind }
            guard !accounts.isEmpty else { return nil }
            return AccountProviderGroup(provider: kind, accounts: accounts)
        }
    }
}

/// On-disk registry document.
public struct AccountRegistryDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var accounts: [Account]

    public init(schemaVersion: Int = 1, accounts: [Account] = []) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
    }
}
