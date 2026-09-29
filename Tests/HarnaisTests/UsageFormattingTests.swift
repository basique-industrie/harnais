import AppKit
import Domain
import Foundation
import Infrastructure

enum UsageFormattingTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        func expectEqual<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            expect(got == want, "\(message) (got \(got), want \(want))")
        }

        expect(QuotaWindowMath.duration(from: "5h") == 5 * 3_600, "5h window")
        expect(QuotaWindowMath.duration(from: "7d") == 7 * 86_400, "7d window")
        expect(QuotaWindowMath.duration(from: "session") == nil, "unparsed window")
        let reset = Date(timeIntervalSince1970: 1_000)
        let half = QuotaWindowMath.elapsedShare(
            resetsAt: reset,
            duration: 100,
            now: Date(timeIntervalSince1970: 950)
        )
        expect(abs((half ?? -1) - 0.5) < 0.0001, "elapsed half the window")
        expect(QuotaWindowMath.timeLeftPercent(elapsed: 0.25) == 75, "time-left hairline")
        expectEqual(QuotaWindowMath.pace(usedPercent: 80, elapsed: 0.5), .ahead, "ahead of pace")
        expectEqual(QuotaWindowMath.pace(usedPercent: 40, elapsed: 0.5), .under, "under pace")
        expectEqual(QuotaWindowMath.pace(usedPercent: 52, elapsed: 0.5), .on, "on pace")
        let english = QuotaReset.date(
            fromEnglishReset: "resets Sep 13 at 6:10pm (Europe/Paris)",
            now: Date(timeIntervalSince1970: 1_757_750_400)
        )
        expect(english != nil, "english Claude reset")
        expect(
            QuotaReset.date(fromEnglishReset: "resets Sep 19 at 8am (Europe/Paris)", now: Date()) != nil,
            "english Claude reset without minutes"
        )

        expectEqual(UsageFormat.windowTitle(FeedQuota(type: "time:Claude · Default 5h", percentRemaining: 90, compactTitle: "5h")), "Session", "5h is Session")
        expectEqual(UsageFormat.windowTitle(FeedQuota(type: "time:Claude · Default 7d", percentRemaining: 90, compactTitle: "7d")), "Weekly", "7d is Weekly")
        expectEqual(UsageFormat.shortWindowTitle(FeedQuota(type: "time:Claude · Default 5h", percentRemaining: 90, compactTitle: "5h")), "5h", "compact 5h stays 5h")
        expectEqual(UsageFormat.shortWindowTitle(FeedQuota(type: "time:Claude · Default session", percentRemaining: 90, compactTitle: "session")), "5h", "session shortens to 5h")
        expectEqual(QuotaWindowMath.pooledRemainingPercent([80, 10, 40]), 43, "pool remaining is the account mean, matching T3")
        expectEqual(QuotaWindowMath.pooledRemainingPercent([]), 0, "empty pool remaining is 0")
        expectEqual(QuotaWindowMath.pooledRemainingPercent([98, 100, 100]), 99, "T3 screenshot example shows 99 percent pooled remaining")
        expectEqual(QuotaWindowMath.refillDelta(currentRemaining: [98, 100, 100], resettingIndex: 0), 1, "T3 screenshot example shows one percent refill")
        expectEqual(
            QuotaWindowMath.refillDelta(currentRemaining: [80, 10, 40], resettingIndex: 1),
            30,
            "refill restores the resetting account's share of the pool"
        )
        expectEqual(
            QuotaWindowMath.refillDelta(currentRemaining: [10, 10], resettingIndex: 0),
            45,
            "refilling one of two equal lows restores half its used allowance"
        )
        expectEqual(LimitWindowFilter.weekly.title, "Plan", "weekly filter is labeled Plan")
        expectEqual(QuotaSeverity.of(percentRemaining: 43), .healthy, "healthy remaining")
        expectEqual(QuotaSeverity.of(percentRemaining: 25), .warning, "warning at 25")
        expectEqual(QuotaSeverity.of(percentRemaining: 9), .critical, "critical under 10")
        expectEqual(QuotaSeverity.of(percentRemaining: 0), .depleted, "depleted at 0")
        expectEqual(
            FeedQuota(type: "time:Claude 7d", percentRemaining: 40, compactTitle: "7d").windowKind,
            .weekly,
            "7d is weekly"
        )
        expectEqual(
            FeedQuota(type: "time:Claude 5h", percentRemaining: 40, compactTitle: "5h").windowKind,
            .session,
            "5h is session"
        )
        expect(
            LimitWindowFilter.weekly.includes(FeedQuota(type: "t", percentRemaining: 10, compactTitle: "7d")),
            "weekly filter keeps 7d"
        )
        expect(
            LimitWindowFilter.weekly.includes(FeedQuota(type: "t", percentRemaining: 10, compactTitle: "Models")),
            "weekly filter keeps Cursor plan windows"
        )
        expect(
            !LimitWindowFilter.weekly.includes(FeedQuota(type: "t", percentRemaining: 10, compactTitle: "5h")),
            "weekly filter hides 5h"
        )
        expectEqual(LimitWindowFilter.allCases.first, .weekly, "Plan is the default Limits filter")
        expectEqual(UsageFormat.tokens(11_500_000_000), "11.5B", "token billions")
        expectEqual(UsageFormat.tokens(898_000_000), "898M", "token millions")
        expectEqual(UsageMetric.allCases.first, .limits, "Limits is the first usage tab")
    }
}
