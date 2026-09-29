import Foundation

public enum UsageMetric: String, CaseIterable, Sendable, Hashable {
    case limits
    case cost
    case tokens
}

public enum UsageRange: String, CaseIterable, Sendable, Hashable {
    case hours24
    case days7
    case days30
    case days90

    public var title: String {
        switch self {
        case .hours24: "Past 24h"
        case .days7: "7 days"
        case .days30: "30 days"
        case .days90: "90 days"
        }
    }

    public var shortTitle: String {
        switch self {
        case .hours24: "24h"
        case .days7: "7d"
        case .days30: "30d"
        case .days90: "90d"
        }
    }

    public var interval: TimeInterval {
        switch self {
        case .hours24: 24 * 3_600
        case .days7: 7 * 86_400
        case .days30: 30 * 86_400
        case .days90: 90 * 86_400
        }
    }

    public var usesHourlyBuckets: Bool { self == .hours24 }
}

public struct UsageEvent: Sendable, Equatable, Codable {
    public var date: Date
    public var provider: ProviderKind
    public var accountID: UUID
    public var sessionID: String
    public var model: String
    public var uncachedInput: Double
    public var cachedInput: Double
    public var cacheWrite: Double
    public var output: Double
    public var dedupeKey: String?
    /// Provider-reported USD, used when local JSONL pricing does not apply (Cursor dashboard).
    public var reportedCost: Double?

    public init(
        date: Date,
        provider: ProviderKind,
        accountID: UUID,
        sessionID: String,
        model: String,
        uncachedInput: Double,
        cachedInput: Double,
        cacheWrite: Double,
        output: Double,
        dedupeKey: String? = nil,
        reportedCost: Double? = nil
    ) {
        self.date = date
        self.provider = provider
        self.accountID = accountID
        self.sessionID = sessionID
        self.model = model
        self.uncachedInput = uncachedInput
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.output = output
        self.dedupeKey = dedupeKey
        self.reportedCost = reportedCost
    }

    public var processed: Double {
        uncachedInput + cachedInput + cacheWrite + output
    }
}

public struct UsageSlice: Sendable, Equatable, Identifiable {
    public var id: String { provider.rawValue }
    public var provider: ProviderKind
    public var sessions: Int
    public var cost: Double
    public var tokens: Double
}

public struct UsageDayPoint: Sendable, Equatable, Identifiable {
    public var id: String { "\(date.timeIntervalSince1970)-\(provider.rawValue)" }
    public var date: Date
    public var provider: ProviderKind
    public var cost: Double
    public var tokens: Double
}

public struct UsageBreakdownRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var provider: ProviderKind?
    public var cost: Double
    public var tokens: Double

    public init(id: String, title: String, provider: ProviderKind? = nil, cost: Double, tokens: Double) {
        self.id = id
        self.title = title
        self.provider = provider
        self.cost = cost
        self.tokens = tokens
    }
}

public struct UsageTotals: Sendable, Equatable {
    public var cost: Double
    public var processed: Double
    public var cachedInput: Double
    public var uncachedInput: Double
    public var output: Double
    public var cacheSavings: Double
    public var sessions: Int

    public static let empty = UsageTotals(
        cost: 0,
        processed: 0,
        cachedInput: 0,
        uncachedInput: 0,
        output: 0,
        cacheSavings: 0,
        sessions: 0
    )
}

public struct UsageSummary: Sendable, Equatable {
    public var events: [UsageEvent]

    public init(events: [UsageEvent] = []) {
        self.events = events
    }

    public func events(in range: UsageRange, now: Date = Date()) -> [UsageEvent] {
        let start = now.addingTimeInterval(-range.interval)
        return events.filter { $0.date >= start && $0.date <= now }
    }

    public func totals(in range: UsageRange, rates: ModelRates = .standard, now: Date = Date()) -> UsageTotals {
        let rows = events(in: range, now: now)
        var totals = UsageTotals.empty
        var sessions = Set<String>()
        for event in rows {
            let priced = rates.price(event)
            totals.cost += priced.cost
            totals.processed += event.processed
            totals.cachedInput += event.cachedInput
            totals.uncachedInput += event.uncachedInput
            totals.output += event.output
            totals.cacheSavings += priced.cacheSavings
            sessions.insert("\(event.provider.rawValue):\(event.sessionID)")
        }
        totals.sessions = sessions.count
        return totals
    }

    public func slices(in range: UsageRange, rates: ModelRates = .standard, now: Date = Date()) -> [UsageSlice] {
        let rows = events(in: range, now: now)
        return ProviderKind.allCases.compactMap { provider in
            let subset = rows.filter { $0.provider == provider }
            guard !subset.isEmpty else { return nil }
            let sessions = Set(subset.map(\.sessionID)).count
            let cost = subset.reduce(0.0) { $0 + rates.price($1).cost }
            let tokens = subset.reduce(0.0) { $0 + $1.processed }
            return UsageSlice(provider: provider, sessions: sessions, cost: cost, tokens: tokens)
        }
    }

    public func series(in range: UsageRange, rates: ModelRates = .standard, now: Date = Date()) -> [UsageDayPoint] {
        let rows = events(in: range, now: now)
        guard !rows.isEmpty else { return [] }
        let calendar = Calendar.current
        let start = now.addingTimeInterval(-range.interval)
        var cursor = range.usesHourlyBuckets
            ? calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: start)) ?? start
            : calendar.startOfDay(for: start)
        let step: Calendar.Component = range.usesHourlyBuckets ? .hour : .day
        var dates: [Date] = []
        while cursor <= now {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: step, value: 1, to: cursor) else { break }
            cursor = next
        }
        var buckets: [Date: [ProviderKind: (cost: Double, tokens: Double)]] = [:]
        for event in rows {
            let date = range.usesHourlyBuckets
                ? calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: event.date)) ?? event.date
                : calendar.startOfDay(for: event.date)
            var bucket = buckets[date] ?? [:]
            var cell = bucket[event.provider] ?? (0, 0)
            let priced = rates.price(event)
            cell.cost += priced.cost
            cell.tokens += event.processed
            bucket[event.provider] = cell
            buckets[date] = bucket
        }
        let active = Set(rows.map(\.provider))
        let painted = ProviderKind.allCases.filter(active.contains).sorted { left, right in
            let leftTokens = rows.filter { $0.provider == left }.reduce(0) { $0 + $1.processed }
            let rightTokens = rows.filter { $0.provider == right }.reduce(0) { $0 + $1.processed }
            return leftTokens > rightTokens
        }
        var points: [UsageDayPoint] = []
        for date in dates {
            let bucket = buckets[date] ?? [:]
            for provider in painted {
                let cell = bucket[provider] ?? (0, 0)
                points.append(UsageDayPoint(date: date, provider: provider, cost: cell.cost, tokens: cell.tokens))
            }
        }
        return points
    }

    public func modelBreakdown(in range: UsageRange, rates: ModelRates = .standard, now: Date = Date()) -> [UsageBreakdownRow] {
        let rows = events(in: range, now: now)
        var grouped: [String: (provider: ProviderKind, cost: Double, tokens: Double)] = [:]
        for event in rows {
            let key = event.model.isEmpty ? "<unknown>" : event.model
            var cell = grouped[key] ?? (event.provider, 0, 0)
            cell.cost += rates.price(event).cost
            cell.tokens += event.processed
            grouped[key] = cell
        }
        return grouped.map { key, value in
            UsageBreakdownRow(id: key, title: key, provider: value.provider, cost: value.cost, tokens: value.tokens)
        }
        .sorted { $0.cost > $1.cost }
    }

    public func dayBreakdown(in range: UsageRange, rates: ModelRates = .standard, now: Date = Date()) -> [UsageBreakdownRow] {
        let rows = series(in: range, rates: rates, now: now)
        var grouped: [Date: (cost: Double, tokens: Double)] = [:]
        for point in rows {
            var cell = grouped[point.date] ?? (0, 0)
            cell.cost += point.cost
            cell.tokens += point.tokens
            grouped[point.date] = cell
        }
        let formatter = DateFormatter()
        formatter.dateFormat = range.usesHourlyBuckets ? "MMM d HH:mm" : "MMM d"
        return grouped.keys.sorted(by: >).compactMap { date in
            guard let cell = grouped[date] else { return nil }
            return UsageBreakdownRow(
                id: date.timeIntervalSince1970.description,
                title: formatter.string(from: date),
                provider: nil,
                cost: cell.cost,
                tokens: cell.tokens
            )
        }
    }
}

public enum UsageFormat {
    public static func tokens(_ value: Double) -> String {
        func compact(_ number: Double, suffix: String) -> String {
            let formatted = String(format: "%.1f", number)
            if formatted.hasSuffix(".0") {
                return String(formatted.dropLast(2)) + suffix
            }
            return formatted + suffix
        }
        if value >= 1_000_000_000 { return compact(value / 1_000_000_000, suffix: "B") }
        if value >= 1_000_000 { return compact(value / 1_000_000, suffix: "M") }
        if value >= 1_000 { return compact(value / 1_000, suffix: "K") }
        return String(format: "%.0f", value)
    }

    public static func usd(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    public static func windowTitle(_ quota: FeedQuota) -> String {
        switch quota.windowTitle.lowercased() {
        case "5h", "session": "Session"
        case "7d", "weekly": "Weekly"
        case "30d", "monthly": "Monthly"
        case "fable": "Fable"
        case "opus": "Opus"
        case "sonnet": "Sonnet"
        default: quota.windowTitle
        }
    }

    /// Compact Limits column: keep 5h / 7d / Models instead of Session / Weekly.
    public static func shortWindowTitle(_ quota: FeedQuota) -> String {
        switch quota.windowTitle.lowercased() {
        case "session": "5h"
        case "weekly": "7d"
        default: quota.windowTitle
        }
    }

    public static func compactReset(_ quota: FeedQuota, now: Date = Date()) -> String? {
        if quota.awaitingFirstUse == true { return "Not started" }
        guard let caption = quota.resetCaption(now: now) else { return nil }
        if caption.hasPrefix("resets in ") {
            return String(caption.dropFirst("resets in ".count))
        }
        if caption == "resets now" { return "now" }
        return nil
    }
}
