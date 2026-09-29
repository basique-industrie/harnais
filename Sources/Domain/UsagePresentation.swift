import Foundation

/// Small, immutable summaries prepared off the UI thread when the usage scan changes.
/// Switching a tab, metric, or range never needs the raw transcript events.
public struct UsagePresentation: Sendable {
    public let capturedAt: Date?
    public let eventCount: Int
    private let reports: [UsageRange: UsageReport]

    public init() {
        capturedAt = nil
        eventCount = 0
        reports = [:]
    }

    public init(summary: UsageSummary, rates: ModelRates = .standard, now: Date = Date(), calendar: Calendar = .current) {
        capturedAt = now
        eventCount = summary.events.count
        var prices: [String: ModelPrice] = [:]
        var dates: [Int: (day: Date, hour: Date)] = [:]
        let start = now.addingTimeInterval(-UsageRange.days90.interval)
        let prepared: [PreparedUsageEvent] = summary.events.compactMap { event in
            guard event.date >= start, event.date <= now else { return nil }
            let priced: (cost: Double, cacheSavings: Double)
            if let reported = event.reportedCost {
                priced = (reported, 0)
            } else {
                let price = prices[event.model] ?? rates.price(for: event.model)
                prices[event.model] = price
                priced = price.cost(uncached: event.uncachedInput, cached: event.cachedInput,
                                    cacheWrite: event.cacheWrite, output: event.output)
            }
            // Calendar conversion is expensive; all events in a UTC minute share a local bucket.
            // Minute keys also support time zones whose offsets are not whole hours.
            let key = Int(floor(event.date.timeIntervalSince1970 / 60))
            let bucket = dates[key] ?? (
                day: calendar.startOfDay(for: event.date),
                hour: calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: event.date)) ?? event.date
            )
            dates[key] = bucket
            return PreparedUsageEvent(event: event, cost: priced.cost, savings: priced.cacheSavings,
                                      day: bucket.day, hour: bucket.hour)
        }
        reports = Dictionary(uniqueKeysWithValues: UsageRange.allCases.map { range in
            (range, UsageReport(events: prepared, range: range, now: now, calendar: calendar))
        })
    }

    public func report(for range: UsageRange) -> UsageReport { reports[range] ?? .empty }
}

public struct UsageReport: Sendable {
    public var totals: UsageTotals = .empty
    public var slices: [UsageSlice] = []
    public var points: [UsageDayPoint] = []
    public var models: [UsageBreakdownRow] = []
    public var days: [UsageBreakdownRow] = []
    /// IDs are resolved against the current registry by the view, so renames take effect immediately.
    public var accounts: [UsageBreakdownRow] = []
    public static let empty = UsageReport()

    private init() {}

    fileprivate init(events: [PreparedUsageEvent], range: UsageRange, now: Date, calendar: Calendar) {
        let start = now.addingTimeInterval(-range.interval)
        var sessions = Set<String>()
        var providerSessions: [ProviderKind: Set<String>] = [:]
        var providerTotals: [ProviderKind: UsageCell] = [:]
        var modelTotals: [String: UsageCell] = [:]
        var accountTotals: [UUID: UsageCell] = [:]
        var buckets: [Date: [ProviderKind: UsageCell]] = [:]
        for row in events where row.event.date >= start {
            let event = row.event
            totals.cost += row.cost
            totals.processed += event.processed
            totals.cachedInput += event.cachedInput
            totals.uncachedInput += event.uncachedInput
            totals.output += event.output
            totals.cacheSavings += row.savings
            sessions.insert("\(event.provider.rawValue):\(event.sessionID)")
            providerSessions[event.provider, default: []].insert(event.sessionID)
            providerTotals[event.provider, default: UsageCell(provider: event.provider)].add(row)
            let model = event.model.isEmpty ? "<unknown>" : event.model
            modelTotals[model, default: UsageCell(provider: event.provider)].add(row)
            accountTotals[event.accountID, default: UsageCell(provider: event.provider)].add(row)
            let date = range.usesHourlyBuckets ? row.hour : row.day
            buckets[date, default: [:]][event.provider, default: UsageCell(provider: event.provider)].add(row)
        }
        totals.sessions = sessions.count
        slices = ProviderKind.allCases.compactMap { provider in
            guard let cell = providerTotals[provider] else { return nil }
            return UsageSlice(provider: provider, sessions: providerSessions[provider]?.count ?? 0,
                              cost: cell.cost, tokens: cell.tokens)
        }
        models = modelTotals.map { id, cell in cell.row(id: id) }.sorted(by: Self.byCost)
        accounts = accountTotals.map { id, cell in cell.row(id: id.uuidString) }.sorted(by: Self.byCost)
        guard !sessions.isEmpty else { return }
        let providers = slices.sorted { lhs, rhs in
            lhs.tokens == rhs.tokens ? lhs.id < rhs.id : lhs.tokens > rhs.tokens
        }.map(\.provider)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = range.usesHourlyBuckets ? "MMM d HH:mm" : "MMM d"
        var cursor = range.usesHourlyBuckets
            ? calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: start)) ?? start
            : calendar.startOfDay(for: start)
        while cursor <= now {
            var cost = 0.0
            var tokens = 0.0
            for provider in providers {
                let cell = buckets[cursor]?[provider] ?? UsageCell(provider: provider)
                points.append(UsageDayPoint(date: cursor, provider: provider, cost: cell.cost, tokens: cell.tokens))
                cost += cell.cost
                tokens += cell.tokens
            }
            days.append(UsageBreakdownRow(id: cursor.timeIntervalSince1970.description,
                                          title: formatter.string(from: cursor), cost: cost, tokens: tokens))
            guard let next = calendar.date(byAdding: range.usesHourlyBuckets ? .hour : .day,
                                           value: 1, to: cursor) else { break }
            cursor = next
        }
        days.reverse()
    }

    private static func byCost(_ lhs: UsageBreakdownRow, _ rhs: UsageBreakdownRow) -> Bool {
        lhs.cost == rhs.cost ? lhs.id < rhs.id : lhs.cost > rhs.cost
    }
}

private struct PreparedUsageEvent {
    let event: UsageEvent
    let cost: Double
    let savings: Double
    let day: Date
    let hour: Date
}

private struct UsageCell {
    let provider: ProviderKind
    var cost = 0.0
    var tokens = 0.0

    mutating func add(_ row: PreparedUsageEvent) {
        cost += row.cost
        tokens += row.event.processed
    }

    func row(id: String) -> UsageBreakdownRow {
        UsageBreakdownRow(id: id, title: id, provider: provider, cost: cost, tokens: tokens)
    }
}
