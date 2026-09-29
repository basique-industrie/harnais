import Foundation

/// A full allowance is not enough to identify an unused window: the API can round
/// small usage down to zero. Confirm a moving seven-day estimate across readings.
public struct CodexWindowState: Codable, Sendable, Equatable {
    public var observedAt: Date?
    public var resetAt: Date?
    public var wasFull = false
    public var awaitingFirstUse = false
    public var attempted = false
    public var lastAttemptAt: Date?
    public var message: String?

    public init() {}

    public mutating func observe(remaining: Double, reset: Date?, now: Date) {
        let week: TimeInterval = 7 * 86_400
        let full = remaining == 100
        let elapsed = observedAt.map { now.timeIntervalSince($0) } ?? 0
        let candidate = full && (reset == nil || abs(reset!.timeIntervalSince(now) - week) < 90)
        let previousCandidate = wasFull && (resetAt == nil || observedAt.map { abs(resetAt!.timeIntervalSince($0) - week) < 90 } == true)
        let movedWithClock: Bool
        if let reset, let resetAt {
            movedWithClock = abs(reset.timeIntervalSince(resetAt) - elapsed) < 15
        } else { movedWithClock = reset == nil && resetAt == nil }
        let confirmed = candidate && previousCandidate && elapsed >= 60 && movedWithClock
        let fixedAnchor = reset != nil && resetAt != nil && elapsed >= 60
            && abs(reset!.timeIntervalSince(resetAt!)) < 2
        let active = !full || (reset.map { $0.timeIntervalSince(now) < week - 120 && $0 > now } ?? false) || fixedAnchor
        if active {
            awaitingFirstUse = false
            attempted = false
        } else if confirmed {
            awaitingFirstUse = true
        } else if !candidate {
            awaitingFirstUse = false
        }
        // Keep the earlier reading when refreshes are too close to distinguish drift.
        if observedAt == nil || elapsed >= 60 || active {
            observedAt = now
            resetAt = reset
            wasFull = full
        }
    }

    public mutating func reserveAttempt(manual: Bool, now: Date) -> Bool {
        guard awaitingFirstUse, manual || !attempted,
              lastAttemptAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return false }
        attempted = true
        lastAttemptAt = now
        message = "Starting weekly window…"
        return true
    }
}
