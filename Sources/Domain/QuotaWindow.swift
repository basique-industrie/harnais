import Foundation

/// Pace against an even-spend clock, matching T3 Usage → Limits.
public enum QuotaPace: String, Sendable, Equatable {
    case ahead
    case on
    case under
}

/// Remaining quota band for Limits rows. Depleted is louder than healthy.
public enum QuotaSeverity: String, Sendable, Equatable {
    case healthy
    case warning
    case critical
    case depleted

    public static func of(percentRemaining: Double) -> QuotaSeverity {
        let remaining = min(max(percentRemaining, 0), 100)
        if remaining <= 0 { return .depleted }
        if remaining < 10 { return .critical }
        if remaining <= 25 { return .warning }
        return .healthy
    }
}

/// Window length, elapsed share, and pace for a subscription quota.
public enum QuotaWindowMath {
    public static func duration(from title: String?) -> TimeInterval? {
        guard let title else { return nil }
        let lower = title.lowercased()
        guard let match = lower.firstMatch(of: /(\d+)\s*(days?|hours?|mins?|minutes?|d|h|m)\b/) else {
            return nil
        }
        guard let amount = TimeInterval(match.output.1) else { return nil }
        switch String(match.output.2) {
        case "d", "day", "days": return amount * 86_400
        case "h", "hour", "hours": return amount * 3_600
        default: return amount * 60
        }
    }

    /// 0...1 through the window, or nil when length or reset is unknown.
    public static func elapsedShare(resetsAt: Date?, duration: TimeInterval?, now: Date = Date()) -> Double? {
        guard let resetsAt, let duration, duration > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return min(1, max(0, (duration - remaining) / duration))
    }

    /// Hairline on a remaining-fill bar: share of the window still left, 0...100.
    public static func timeLeftPercent(elapsed: Double?) -> Double? {
        guard let elapsed else { return nil }
        return (1 - elapsed) * 100
    }

    public static func pace(usedPercent: Double, elapsed: Double) -> QuotaPace {
        let gap = usedPercent - elapsed * 100
        if gap > 5 { return .ahead }
        if gap < -5 { return .under }
        return .on
    }

    /// T3 assigns an equal share of the pool to each account.
    public static func pooledRemainingPercent(_ remaining: [Double]) -> Int {
        guard !remaining.isEmpty else { return 0 }
        let sum = remaining.reduce(0.0) { $0 + min(max($1, 0), 100) }
        return Int((sum / Double(remaining.count)).rounded())
    }

    /// Contribution of one account's scheduled refill to the combined allowance.
    public static func refillDelta(currentRemaining: [Double], resettingIndex: Int) -> Int {
        guard currentRemaining.indices.contains(resettingIndex) else { return 0 }
        let used = 100 - min(max(currentRemaining[resettingIndex], 0), 100)
        return Int((used / Double(currentRemaining.count)).rounded())
    }
}

/// Session (5h) vs weekly/plan windows, for the Limits filter.
public enum QuotaWindowKind: String, Sendable, Equatable {
    case session
    case weekly
    case plan
}

/// Limits window filter. Plan is the default so a long account list stays readable.
public enum LimitWindowFilter: String, CaseIterable, Sendable, Hashable {
    case weekly
    case session
    case all

    public var title: String {
        switch self {
        case .weekly: "Plan"
        case .session: "Session"
        case .all: "All"
        }
    }

    public func includes(_ quota: FeedQuota) -> Bool {
        switch self {
        case .all: true
        case .weekly: quota.windowKind != .session
        case .session: quota.windowKind == .session
        }
    }
}

extension FeedQuota {
    public var usedPercent: Double {
        min(max(100 - percentRemaining, 0), 100)
    }

    public var windowTitle: String {
        compactTitle ?? type
    }

    public var windowKind: QuotaWindowKind {
        switch (compactTitle ?? windowTitle).lowercased() {
        case "5h", "session": .session
        case "7d", "weekly": .weekly
        case "30d", "monthly": .plan
        default: .plan
        }
    }

    public var windowDuration: TimeInterval? {
        QuotaWindowMath.duration(from: compactTitle) ?? QuotaWindowMath.duration(from: type)
    }

    public func elapsedShare(now: Date = Date()) -> Double? {
        if awaitingFirstUse == true { return nil }
        return QuotaWindowMath.elapsedShare(resetsAt: resetsAt, duration: windowDuration, now: now)
    }

    public func pace(now: Date = Date()) -> QuotaPace? {
        guard let elapsed = elapsedShare(now: now) else { return nil }
        return QuotaWindowMath.pace(usedPercent: usedPercent, elapsed: elapsed)
    }
}
