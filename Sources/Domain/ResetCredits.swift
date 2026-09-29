import Foundation

/// Account-level banked resets, separate from a usage window's scheduled reset.
/// Nil in a snapshot means the provider did not report this information.
public struct ResetCredits: Codable, Sendable, Equatable {
    public var availableCount: Int
    public var nextExpiresAt: Date?

    public init(availableCount: Int, nextExpiresAt: Date? = nil) {
        self.availableCount = max(0, availableCount)
        self.nextExpiresAt = nextExpiresAt
    }

    public var caption: String {
        availableCount == 1 ? "1 banked reset available" : "\(availableCount) banked resets available"
    }

    public func expiryCaption(now: Date = Date()) -> String? {
        guard availableCount > 0, let nextExpiresAt else { return nil }
        guard nextExpiresAt > now else { return "Expiry reached · refresh limits" }
        return QuotaReset.caption(resetsAt: nextExpiresAt, now: now)?
            .replacingOccurrences(of: "resets", with: "Next expires")
    }
}
