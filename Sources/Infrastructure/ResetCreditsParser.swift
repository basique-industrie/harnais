import Domain
import Foundation

/// Matches T3 Code's Codex summary and Claude cedar_ember grant rules.
public enum ResetCreditsParser {
    public static func codex(_ value: Any?) -> ResetCredits? {
        guard let block = value as? [String: Any],
              let count = integer(block["availableCount"])
        else { return nil }
        let expiries = (block["credits"] as? [[String: Any]] ?? []).compactMap { credit -> Date? in
            guard credit["status"] as? String == "available" else { return nil }
            return QuotaReset.date(from: credit["expiresAt"])
        }
        return ResetCredits(availableCount: count, nextExpiresAt: count > 0 ? expiries.min() : nil)
    }

    public static func claude(_ value: Any?, now: Date = Date()) -> ResetCredits? {
        guard let block = value as? [String: Any], bool(block["eligible"]) == true else { return nil }
        let grants = (block["grants"] as? [Any] ?? []).compactMap { raw -> (id: String, count: Int, expiry: Date?)? in
            guard let grant = raw as? [String: Any],
                  let id = grant["id"] as? String,
                  id.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression) != nil,
                  let count = integer(grant["resets_left"]), count >= 0,
                  bool(grant["usable_now"]) == true
            else { return nil }
            if let paused = grant["paused"], bool(paused) != false { return nil }
            var expiry: Date?
            if let rawExpiry = grant["ends_at"], !(rawExpiry is NSNull) {
                guard let string = rawExpiry as? String,
                      let date = strictTimestamp(string), date > now else { return nil }
                expiry = date
            }
            return (id, count, expiry)
        }
        guard let nextID = block["next_grant_id"] as? String,
              let next = grants.first(where: { $0.id == nextID })
        else { return ResetCredits(availableCount: 0) }
        var total = 0
        for grant in grants {
            let (sum, overflow) = total.addingReportingOverflow(grant.count)
            guard !overflow else { return nil }
            total = sum
        }
        return ResetCredits(availableCount: total, nextExpiresAt: next.expiry)
    }

    public struct CodexCredit: Sendable, Equatable {
        public var id: String
        public var title: String?
        public var expiresAt: Date?
    }

    /// Available Codex credits, soonest expiry first. Credits without an expiry go last.
    public static func codexCredits(_ value: Any?) -> [CodexCredit] {
        guard let block = value as? [String: Any] else { return [] }
        let credits = (block["credits"] as? [[String: Any]] ?? []).compactMap { credit -> CodexCredit? in
            guard credit["status"] as? String == "available", let id = credit["id"] as? String,
                  !id.isEmpty, id.count <= 128 else { return nil }
            return CodexCredit(id: id, title: credit["title"] as? String, expiresAt: QuotaReset.date(from: credit["expiresAt"]))
        }
        return credits.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// The one grant Claude will redeem next, with the rules that decide whether it can be used now.
    public struct ClaudeOffer: Sendable, Equatable {
        public var eligible: Bool
        public var atLimit: Bool
        public var cooldownUntil: Date?
        public var grantID: String?
        public var label: String?
        public var resetsLeft: Int
        public var expiresAt: Date?
        public var clears: [String]
        public var paused: Bool
        public var usableNow: Bool
        public var requiresLimit: Bool
    }

    public static func claudeOffer(_ value: Any?) -> ClaudeOffer? {
        guard let block = value as? [String: Any], let eligible = bool(block["eligible"]) else { return nil }
        var offer = ClaudeOffer(
            eligible: eligible, atLimit: bool(block["at_limit"]) ?? false,
            cooldownUntil: (block["cooldown_until"] as? String).flatMap(strictTimestamp),
            grantID: nil, label: nil, resetsLeft: 0, expiresAt: nil, clears: [],
            paused: false, usableNow: false, requiresLimit: true
        )
        guard let nextID = block["next_grant_id"] as? String,
              nextID.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression) != nil,
              let grant = (block["grants"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] })
                  .first(where: { $0["id"] as? String == nextID }),
              let left = integer(grant["resets_left"]), left >= 0
        else { return offer }
        offer.grantID = nextID
        offer.label = grant["label"] as? String
        offer.resetsLeft = left
        offer.clears = (grant["clears"] as? [String] ?? []).filter { Self.claudeLimitNames[$0] != nil }
        offer.paused = grant["paused"].map { bool($0) != false } ?? false
        offer.usableNow = bool(grant["usable_now"]) ?? false
        // Claude Code treats a missing flag as "only at a limit", the safe reading.
        offer.requiresLimit = bool(grant["use_requires_limit"]) ?? true
        if let rawExpiry = grant["ends_at"], !(rawExpiry is NSNull) {
            // An unparseable expiry must not look like "never expires".
            offer.expiresAt = (rawExpiry as? String).flatMap(strictTimestamp) ?? .distantPast
        }
        return offer
    }

    /// Claude limit type -> the short window name Harnais shows.
    public static let claudeLimitNames: [String: String] = [
        "five_hour": "5h", "seven_day": "7d", "seven_day_opus": "opus", "seven_day_sonnet": "sonnet",
        "seven_day_overage_included": "7d", "seven_day_cowork": "cowork",
        "seven_day_omelette": "omelette", "seven_day_oauth_apps": "oauth apps",
    ]

    private static func integer(_ value: Any?) -> Int? {
        guard let value, JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value]),
              let integers = try? JSONDecoder().decode([Int].self, from: data)
        else { return nil }
        return integers.first
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: [value]),
              let flags = try? JSONDecoder().decode([Bool].self, from: data)
        else { return nil }
        return flags.first
    }

    private static func strictTimestamp(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil,
              let date = QuotaReset.isoDate(value) else { return nil }
        // ISO8601DateFormatter normalizes invalid dates such as February 30.
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard parts.count == 3,
              let month = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let days = calendar.range(of: .day, in: .month, for: month), days.contains(parts[2])
        else { return nil }
        return date
    }
}
