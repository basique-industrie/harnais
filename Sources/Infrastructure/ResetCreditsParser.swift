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
