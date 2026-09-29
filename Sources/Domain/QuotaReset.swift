import Foundation

/// Shared reset clock for quota probes and the editor.
public enum QuotaReset {
    public static func date(from value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let string = value as? String {
            if let iso = isoDate(string) { return iso }
            if let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return date(from: number)
            }
            return nil
        }
        guard let number = double(value) else { return nil }
        if number > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: number / 1000)
        }
        if number > 1_000_000_000 {
            return Date(timeIntervalSince1970: number)
        }
        return nil
    }

    public static func date(afterSeconds value: Any?, now: Date = Date()) -> Date? {
        guard let seconds = double(value), seconds > 0 else { return nil }
        return now.addingTimeInterval(seconds)
    }

    public static func isoDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return isoParser.date(from: trimmed)
    }

    private static let isoParser = ISODateParser()

    private final class ISODateParser: @unchecked Sendable {
        private let lock = NSLock()
        private let fractional = ISO8601DateFormatter()
        private let whole = ISO8601DateFormatter()

        init() {
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            whole.formatOptions = [.withInternetDateTime]
        }

        func date(from string: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return fractional.date(from: string) ?? whole.date(from: string)
        }
    }

    public static func caption(resetsAt: Date?, fallback: String? = nil, now: Date = Date()) -> String? {
        if let resetsAt {
            let seconds = resetsAt.timeIntervalSince(now)
            if seconds <= 0 { return "resets now" }
            let days = Int(seconds / 86_400)
            let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3_600)
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60)
            if days > 0 { return "resets in \(days)d \(hours)h" }
            if hours > 0 { return "resets in \(hours)h \(minutes)m" }
            if minutes > 0 { return "resets in \(minutes)m" }
            return "resets now"
        }
        let trimmed = fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// `resets Sep 13 at 6:10pm (Europe/Paris)` from Claude CLI `/usage`.
    public static func date(fromEnglishReset text: String?, now: Date = Date()) -> Date? {
        guard var text else { return nil }
        let lower = text.lowercased()
        guard let resetsRange = lower.range(of: "resets ") else { return nil }
        text = String(text[resetsRange.upperBound...])
        var timeZone = TimeZone.current
        if let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            let identifier = String(text[text.index(after: open)..<close])
            if let parsed = TimeZone(identifier: identifier) {
                timeZone = parsed
            }
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: " at ", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "pm", with: "PM", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "am", with: "AM", options: .caseInsensitive)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.defaultDate = now
        for format in ["MMM d h:mma", "MMM d h:mm a", "MMM d ha", "MMMM d h:mma", "MMMM d h:mm a", "MMMM d ha"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }

    public static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    public static func jsonRPCID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    /// Codex `usedPercent` is 0–100. Values in (0, 1) are legacy 0–1 fractions.
    /// `1` is 1% used, not an empty bar.
    public static func remainingPercent(used: Double) -> Double {
        let usedPercent = (used > 0 && used < 1) ? used * 100 : used
        return min(max(100 - usedPercent, 0), 100)
    }
}

extension FeedQuota {
    public func resetCaption(now: Date = Date()) -> String? {
        if awaitingFirstUse == true { return "Starts with first use" }
        return QuotaReset.caption(resetsAt: resetsAt, fallback: resetText, now: now)
    }
}
