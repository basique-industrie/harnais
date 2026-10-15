import Foundation

/// Extra Codex usage credits, separate from subscription quotas and banked resets.
/// The provider reports credit units, not an API-platform currency balance.
public struct CodexCredits: Codable, Sendable, Equatable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String? = nil) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }

    public var balanceLabel: String {
        if unlimited { return "Unlimited" }
        if !hasCredits { return "0" }
        return balance ?? "Available"
    }
}
