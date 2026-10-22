import Foundation

/// A fresh, read-only description of the banked reset Harnais would redeem.
/// Built from a recent provider response before confirmation, never from the persisted quota feed.
public struct ResetPlan: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public var name: String
        public var percentRemaining: Double

        public init(name: String, percentRemaining: Double) {
            self.name = name
            self.percentRemaining = percentRemaining
        }
    }

    public var provider: ProviderKind
    /// Codex credit ID (nil lets the backend pick) or Claude grant ID.
    public var creditID: String?
    public var title: String
    public var availableCount: Int
    public var expiresAt: Date?
    /// Limits the provider says this reset clears. Empty means "every limit in use".
    public var clears: [String]
    public var windows: [Window]
    /// Why the reset cannot be used right now. Nil means it can.
    public var blocker: String?

    public init(
        provider: ProviderKind,
        creditID: String? = nil,
        title: String = "Banked reset",
        availableCount: Int,
        expiresAt: Date? = nil,
        clears: [String] = [],
        windows: [Window] = [],
        blocker: String? = nil
    ) {
        self.provider = provider
        self.creditID = creditID
        self.title = title
        self.availableCount = max(0, availableCount)
        self.expiresAt = expiresAt
        self.clears = clears
        self.windows = windows
        self.blocker = blocker ?? Self.blocker(provider: provider, availableCount: availableCount, windows: windows)
    }

    /// Codex's local weekly-quota policy. Claude eligibility comes from its grant flags,
    /// which can allow a reset before any quota is empty.
    public static func weeklyGate(_ windows: [Window]) -> String? {
        let weekly = windows.filter { $0.name.lowercased() == "7d" }
        let longer = windows.filter { $0.name.lowercased() != "5h" }
        let basis = !weekly.isEmpty ? weekly : (!longer.isEmpty ? longer : windows)
        guard let open = basis.filter({ $0.percentRemaining.rounded() > 0 }).max(by: { $0.percentRemaining < $1.percentRemaining })
        else { return nil }
        let quota = weekly.isEmpty ? "plan" : "weekly"
        return "Available once the \(quota) quota is empty. \(open.name) has \(Int(open.percentRemaining.rounded()))% left."
    }

    public static func blocker(provider: ProviderKind, availableCount: Int, windows: [Window]) -> String? {
        if availableCount <= 0 { return "No banked reset is available." }
        return provider == .claude ? nil : weeklyGate(windows)
    }

    public var dialogTitle: String {
        blocker == nil ? "Use a banked reset?" : "Banked reset unavailable"
    }

    public struct Row: Sendable, Equatable {
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// What the confirmation shows. A blocked plan keeps only the facts that explain why.
    public func detailRows(now: Date = Date()) -> [Row] {
        var rows: [Row] = []
        if blocker == nil {
            rows.append(Row(label: "Spends", value: "1 of \(availableCount) banked reset\(availableCount == 1 ? "" : "s")"))
            rows.append(Row(label: "Credit", value: title))
            rows.append(Row(label: "Resets", value: clears.isEmpty ? "Every limit in use" : clears.joined(separator: " · ")))
        }
        if !windows.isEmpty {
            rows.append(Row(label: "Now", value: windows.map { "\($0.name) \(Int($0.percentRemaining.rounded()))% left" }.joined(separator: " · ")))
        }
        if let expiry = ResetCredits(availableCount: 1, nextExpiresAt: expiresAt).expiryCaption(now: now) {
            rows.append(Row(label: "Expires", value: expiry.replacingOccurrences(of: "Next expires ", with: "")))
        }
        return rows
    }

    public func dialogMessage() -> String {
        blocker ?? "This spends one banked reset to restore the limits shown below."
    }
}

/// What happened to one redemption attempt.
public enum ResetOutcome: Sendable, Equatable {
    case reset(remaining: Int?)
    case alreadyRedeemed
    /// Nothing was in use; the provider kept the credit.
    case nothingToReset
    case noCredit
    case cooldown
    case ineligible
    /// The provider answered that it cannot say yet. The attempt may still land.
    case unavailable
    /// The request may or may not have been applied. Retrying reuses the same key.
    case unconfirmed(String)
    /// Nothing was sent.
    case notSent(String)

    public var succeeded: Bool {
        switch self {
        case .reset, .alreadyRedeemed: true
        default: false
        }
    }

    /// Only a final answer retires the idempotency key. Anything else must retry with it.
    public var retiresKey: Bool {
        switch self {
        case .unavailable, .unconfirmed: false
        default: true
        }
    }

    public var message: String {
        switch self {
        case .reset(let remaining):
            remaining.map { "Banked reset used. \($0) left. Refreshing limits." } ?? "Banked reset used. Refreshing limits."
        case .alreadyRedeemed: "This reset was already applied. Refreshing limits."
        case .nothingToReset: "Nothing to reset: no limit was in use. No banked reset was spent."
        case .noCredit: "No banked reset is available."
        case .cooldown: "A reset was used recently. Try again later."
        case .ineligible: "This account cannot use a banked reset right now."
        case .unavailable: "The provider could not confirm the reset. Refresh limits, then retry; the retry reuses the same request."
        case .unconfirmed(let detail): "\(detail) Refresh limits to check; a retry reuses the same request and cannot spend a second reset."
        case .notSent(let detail): detail
        }
    }
}
