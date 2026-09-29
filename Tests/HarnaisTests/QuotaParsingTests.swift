import AppKit
import Domain
import Foundation
import Infrastructure

enum QuotaParsingTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        func expectEqual<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            expect(got == want, "\(message) (got \(got), want \(want))")
        }

        let usage = """
        Current session
        42% used
        Resets 4pm
        Current week (all models)
        11% used
        Resets Sep 19 at 8am
        """
        let parsed = ClaudeQuotaProbe.parseUsage(usage)
        expect(parsed.contains(where: { $0.window == "5h" }), "Claude parser finds session")
        expect(parsed.contains(where: { $0.window == "7d" }), "Claude parser finds weekly")
        expect(abs((parsed.first { $0.window == "5h" }?.percentRemaining ?? -1) - 58) < 0.01, "Claude 42% used is 58% remaining")
        expect(abs((parsed.first { $0.window == "7d" }?.percentRemaining ?? -1) - 89) < 0.01, "Claude 11% used is 89% remaining")
        expect(parsed.first { $0.window == "5h" }?.resetText?.lowercased().contains("4pm") == true, "Claude session keeps its own reset")
        expect(parsed.first { $0.window == "7d" }?.resetText?.lowercased().contains("sep") == true, "Claude weekly keeps its own reset")

        let leftover = ClaudeQuotaProbe.parseUsage("""
        Current session
        0% used
        Resets 1pm
        Current week (all models)
        85% left
        """)
        expect(abs((leftover.first { $0.window == "5h" }?.percentRemaining ?? -1) - 100) < 0.01, "Claude 0% used is a full session")
        expect(abs((leftover.first { $0.window == "7d" }?.percentRemaining ?? -1) - 85) < 0.01, "Claude % left stays remaining")

        let apiReset = "2026-09-13T16:10:00Z"
        let claudeAPI = ClaudeQuotaProbe.parseAPI([
            "five_hour": ["utilization": 95, "resets_at": apiReset],
            "seven_day": ["utilization": 99, "resets_at": "2026-09-19T06:00:00Z"],
        ])
        expectEqual(claudeAPI.count, 2, "Claude API parser finds both windows")
        expect(abs((claudeAPI.first { $0.window == "5h" }?.percentRemaining ?? -1) - 5) < 0.01, "Claude API 5h remaining")
        expect(claudeAPI.first { $0.window == "5h" }?.resetsAt != nil, "Claude API 5h has reset date")

        let now = Date()
        let codexLimits = CodexQuotaProbe.parseRateLimits([
            "primary": [
                "usedPercent": 0,
                "resetsAt": now.addingTimeInterval(2 * 3600 + 15 * 60).timeIntervalSince1970,
            ],
            "secondary": [
                "used_percent": 40,
                "resetDescription": "resets in 4d",
            ],
        ])
        expectEqual(codexLimits.count, 2, "Codex parser finds both windows")
        expect(codexLimits.first { $0.window == "5h" }?.resetsAt != nil, "Codex 5h has reset date")
        expect(codexLimits.first { $0.window == "5h" }?.resetText?.contains("resets in") == true, "Codex 5h formats reset")
        expectEqual(codexLimits.first { $0.window == "7d" }?.resetText, "resets in 4d", "Codex 7d keeps description")

        let proNow = Date()
        let proPrimary = CodexQuotaProbe.parseRateLimits([
            "planType": "pro",
            "primary": [
                "usedPercent": 0,
                "resetsAt": proNow.addingTimeInterval(6 * 86_400 + 19 * 3600).timeIntervalSince1970,
            ],
        ], now: proNow)
        expectEqual(proPrimary.first?.window, "7d", "Codex Pro primary with a 6d reset is weekly")

        let durationWeekly = CodexQuotaProbe.parseRateLimits([
            "primary": [
                "usedPercent": 12,
                "windowDurationMins": 10_080,
                "resetsAt": proNow.addingTimeInterval(2 * 3600).timeIntervalSince1970,
            ],
        ], now: proNow)
        expectEqual(durationWeekly.first?.window, "7d", "Codex windowDurationMins 10080 is weekly")

        let plusSession = CodexQuotaProbe.parseRateLimits([
            "planType": "plus",
            "primary": [
                "usedPercent": 12,
                "windowDurationMins": 300,
                "resetsAt": proNow.addingTimeInterval(2 * 3600).timeIntervalSince1970,
            ],
            "secondary": [
                "usedPercent": 40,
                "windowDurationMins": 10_080,
            ],
        ], now: proNow)
        expect(plusSession.contains { $0.window == "5h" }, "Codex Plus keeps a 5h window")
        expect(plusSession.contains { $0.window == "7d" }, "Codex Plus keeps a 7d window")

        let freeMonthly = CodexQuotaProbe.parseRateLimits([
            "planType": "free",
            "primary": ["usedPercent": 80],
        ], now: proNow)
        expectEqual(freeMonthly.first?.window, "30d", "Codex Free primary is monthly")

        let inheritedPro = CodexQuotaProbe.parseRateLimits([
            "primary": [
                "usedPercent": 40,
                "resetsAt": proNow.addingTimeInterval(2 * 3600).timeIntervalSince1970,
            ],
        ], planType: "pro", now: proNow)
        expectEqual(inheritedPro.first?.window, "7d", "Codex Pro from auth.json still classifies primary as weekly")
        expect(abs((durationWeekly.first?.percentRemaining ?? -1) - 88) < 0.01, "Codex 12% used is 88% remaining")
        expectEqual(QuotaReset.remainingPercent(used: 0), 100, "Codex 0% used is full")
        expectEqual(QuotaReset.remainingPercent(used: 1), 99, "Codex usedPercent 1 is 1% used, not empty")
        expectEqual(QuotaReset.remainingPercent(used: 0.26), 74, "Codex fraction 0.26 is 26% used")
        expectEqual(QuotaReset.remainingPercent(used: 45), 55, "Codex 45% used is 55% remaining")
        expectEqual(QuotaReset.remainingPercent(used: 100), 0, "Codex 100% used is empty")

        let liveCodexJSON = Data("""
        {
          "rateLimits": {
            "limitId": "codex",
            "primary": { "usedPercent": 45, "windowDurationMins": 10080, "resetsAt": 1789901779 },
            "secondary": null,
            "planType": "pro"
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 45, "windowDurationMins": 10080, "resetsAt": 1789901779 },
              "planType": "pro"
            }
          }
        }
        """.utf8)
        let liveCodexObject = try JSONSerialization.jsonObject(with: liveCodexJSON) as? [String: Any] ?? [:]
        let liveCodex = CodexQuotaProbe.parseRateLimits(liveCodexObject, planType: "pro")
        expectEqual(liveCodex.count, 1, "Codex live payload keeps the weekly window")
        expectEqual(liveCodex.first?.window, "7d", "Codex live windowDurationMins 10080 is weekly")
        expect(abs((liveCodex.first?.percentRemaining ?? -1) - 55) < 0.01, "Codex live 45% used is 55% remaining")
        expect(liveCodex.first?.resetsAt != nil, "Codex live weekly keeps resetsAt")

        let cursorJSON: [String: Any] = [
            "membershipType": "ultra",
            "billingCycleEnd": "2026-09-17T00:00:00.000Z",
            "autoModelSelectedDisplayMessage": "You've used 25% of your included total usage",
            "namedModelSelectedDisplayMessage": "You've used 91% of your included API usage",
            "individualUsage": [
                "plan": [
                    "enabled": true,
                    "used": 40595,
                    "limit": 119198,
                    "remaining": 78603,
                    "autoPercentUsed": 25,
                    "apiPercentUsed": 91,
                ],
                "onDemand": ["enabled": false],
            ],
        ]
        let cursorPools = CursorQuotaProbe.parseSummary(cursorJSON)
        expectEqual(cursorPools.count, 2, "Cursor dashboard is two pools")
        expectEqual(cursorPools[0].window, "Models", "Cursor Models pool")
        expectEqual(cursorPools[1].window, "Other", "Cursor Other pool")
        expect(abs(cursorPools[0].percentRemaining - 75) < 0.01, "Cursor Models remaining")
        expect(abs(cursorPools[1].percentRemaining - 9) < 0.01, "Cursor Other remaining")
        expect(cursorPools[0].resetsAt != nil, "Cursor billing cycle becomes reset date")
        expect(
            QuotaReset.caption(resetsAt: now.addingTimeInterval(90 * 60), now: now) == "resets in 1h 30m",
            "reset caption uses hours and minutes"
        )

    }
}
