import Foundation

/// Stable quota payload Iles (and the optional Iles extension) consume.
public struct QuotaFeed: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var capturedAt: Date
    public var accounts: [AccountQuotaSnapshot]

    public init(schemaVersion: Int = 1, capturedAt: Date = Date(), accounts: [AccountQuotaSnapshot] = []) {
        self.schemaVersion = schemaVersion
        self.capturedAt = capturedAt
        self.accounts = accounts
    }
}

public struct AccountQuotaSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var provider: String
    public var label: String
    public var email: String?
    public var quotas: [FeedQuota]
    public var error: String?
    public var resetCredits: ResetCredits?

    public init(
        id: String,
        provider: String,
        label: String,
        email: String? = nil,
        quotas: [FeedQuota] = [],
        error: String? = nil,
        resetCredits: ResetCredits? = nil
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.email = email
        self.quotas = quotas
        self.error = error
        self.resetCredits = resetCredits
    }
}

public struct FeedQuota: Codable, Sendable, Equatable {
    public var type: String
    public var percentRemaining: Double
    public var resetsAt: Date?
    public var resetText: String?
    public var group: String?
    public var compactTitle: String?
    public var menuBarTitle: String?
    public var awaitingFirstUse: Bool?

    public init(
        type: String,
        percentRemaining: Double,
        resetsAt: Date? = nil,
        resetText: String? = nil,
        group: String? = nil,
        compactTitle: String? = nil,
        menuBarTitle: String? = nil,
        awaitingFirstUse: Bool? = nil
    ) {
        self.type = type
        self.percentRemaining = percentRemaining
        self.resetsAt = resetsAt
        self.resetText = resetText
        self.group = group
        self.compactTitle = compactTitle
        self.menuBarTitle = menuBarTitle
        self.awaitingFirstUse = awaitingFirstUse
    }
}

public struct ProbeQuota: Sendable, Equatable {
    public var window: String
    public var percentRemaining: Double
    public var resetsAt: Date?
    public var resetText: String?

    public init(window: String, percentRemaining: Double, resetsAt: Date? = nil, resetText: String? = nil) {
        self.window = window
        self.percentRemaining = percentRemaining
        self.resetsAt = resetsAt
        self.resetText = resetText
    }
}

public struct ProbeResult: Sendable, Equatable {
    public var email: String?
    public var quotas: [ProbeQuota]
    public var error: String?
    public var resetCredits: ResetCredits?

    public init(email: String? = nil, quotas: [ProbeQuota] = [], error: String? = nil, resetCredits: ResetCredits? = nil) {
        self.email = email
        self.quotas = quotas
        self.error = error
        self.resetCredits = resetCredits
    }
}
