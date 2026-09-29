import AppKit
import Domain
import Foundation
import Infrastructure

enum UsagePresentationTests {
    static func run(expect: (Bool, String) -> Void) {
        let now = QuotaReset.isoDate("2026-09-28T08:00:00Z")!
        let first = UUID(), second = UUID()
        func event(_ hours: Double, provider: ProviderKind = .claude, account: UUID? = nil,
                   model: String = "claude-opus-5", reported: Double? = nil) -> UsageEvent {
            UsageEvent(date: now.addingTimeInterval(-hours * 3600), provider: provider,
                       accountID: account ?? first, sessionID: "shared-session", model: model,
                       uncachedInput: 100, cachedInput: 200, cacheWrite: 50, output: 20, reportedCost: reported)
        }
        let summary = UsageSummary(events: [
            event(0), event(1), event(24), event(24.01), event(168), event(720),
            event(721), event(2160), event(2161), event(-1),
            event(2, provider: .codex, account: second, model: "gpt-6-astra"),
            event(3, provider: .cursor, account: second, model: "gpt-6-astra", reported: 7.5),
            event(4, model: "unknown-model"),
        ])
        let presentation = UsagePresentation(summary: summary, now: now)
        for range in UsageRange.allCases {
            let report = presentation.report(for: range)
            expect(report.totals == summary.totals(in: range, now: now), "cached totals preserve raw aggregation for \(range)")
            expect(report.slices == summary.slices(in: range, now: now), "cached providers preserve costs, tokens and session deduplication for \(range)")
            expect(report.points.sorted { $0.id < $1.id } == summary.series(in: range, now: now).sorted { $0.id < $1.id }, "cached chart preserves buckets and zero-filled gaps for \(range)")
            expect(report.models.sorted { $0.id < $1.id } == summary.modelBreakdown(in: range, now: now).sorted { $0.id < $1.id }, "cached models preserve unknown pricing and reported cost for \(range)")
            expect(report.days == summary.dayBreakdown(in: range, now: now), "cached time breakdown matches chart totals for \(range)")
            let firstCost = summary.events(in: range, now: now).filter { $0.accountID == first }.reduce(0.0) { $0 + ModelRates.standard.price($1).cost }
            expect(report.accounts.first { $0.id == first.uuidString }?.cost == firstCost, "cached account totals keep account identity for \(range)")
        }
        let empty = UsagePresentation(summary: UsageSummary(), now: now)
        expect(empty.capturedAt == now && empty.report(for: .days30).points.isEmpty, "loaded empty usage is distinct from initial loading")
        expect(UsagePresentation().capturedAt == nil, "initial usage presentation has no fabricated load timestamp")
    }

    static func benchmark(cacheURL: URL) throws {
        guard let summary = SessionUsageScanner().load(cacheURL: cacheURL) else {
            throw HarnaisError.processFailed("No usage cache at the supplied path")
        }
        let now = Date()
        let legacyStart = Date()
        let totals = summary.totals(in: .days30, now: now)
        let points = summary.series(in: .days30, now: now)
        let slices = summary.slices(in: .days30, now: now)
        let models = summary.modelBreakdown(in: .days30, now: now)
        let legacyMS = Date().timeIntervalSince(legacyStart) * 1000
        let prepareStart = Date()
        let presentation = UsagePresentation(summary: summary, now: now)
        let prepareMS = Date().timeIntervalSince(prepareStart) * 1000
        let lookupStart = Date()
        var consumed = 0
        for index in 0..<1000 {
            let report = presentation.report(for: UsageRange.allCases[index % UsageRange.allCases.count])
            consumed += report.points.count + report.models.count + report.slices.count + report.totals.sessions
        }
        let lookupMS = Date().timeIntervalSince(lookupStart) * 1000 / 1000
        let report = presentation.report(for: .days30)
        let matches = abs(report.totals.cost - totals.cost) < 0.000001 && report.points.count == points.count
            && report.slices.count == slices.count && report.models.count == models.count
        print("Usage benchmark: \(summary.events.count) events")
        print(String(format: "Previous 30-day render aggregation: %.2f ms", legacyMS))
        print(String(format: "Background preparation for all four ranges: %.2f ms", prepareMS))
        print(String(format: "Cached range lookup: %.5f ms", lookupMS))
        print("Summary matches: \(matches); consumed: \(consumed)")
        guard matches else { throw HarnaisError.processFailed("Usage benchmark summary mismatch") }
    }
}
