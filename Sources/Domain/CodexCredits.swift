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
        formattedBalance()
    }

    public func formattedBalance(locale: Locale = .current) -> String {
        if unlimited { return "Unlimited" }
        if !hasCredits { return "0" }
        guard let balance, let amount = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX")),
              !amount.isNaN, amount >= 0 else { return "Available" }
        let style = Decimal.FormatStyle.number
            .grouping(.automatic)
            .precision(.fractionLength(0...2))
            .locale(locale)
        // A small positive balance must not look depleted after rounding.
        let minimumDisplayed = Decimal(1) / 100
        if amount > 0, amount < minimumDisplayed {
            return "< " + minimumDisplayed.formatted(style)
        }
        return amount.formatted(style)
    }
}
