import AppKit
import Domain
import Foundation
import Infrastructure

enum UsageTranscriptTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let fixtureAccount = Account(provider: .claude, label: "Work", slug: "work", homePath: "/tmp")
        let claudeLine = """
        {"type":"assistant","timestamp":"2026-09-01T08:43:01.480Z","message":{"id":"msg_1","model":"claude-fable-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":50,"output_tokens":10}},"requestId":"req_1"}
        """
        let parsedClaude = SessionUsageScanner.parseClaudeLine(claudeLine, account: fixtureAccount, sessionID: "abc")
        expect(parsedClaude?.model == "claude-fable-5", "claude usage model")
        expect(parsedClaude?.cachedInput == 50, "claude cache read")
        expect(parsedClaude?.output == 10, "claude output")
        expect(parsedClaude?.dedupeKey == "msg_1:req_1", "claude dedupe key")
        let skippedClaude = SessionUsageScanner.parseClaudeLine(
            claudeLine.replacingOccurrences(of: "\"type\":\"assistant\"", with: "\"type\":\"user\""),
            account: fixtureAccount,
            sessionID: "abc"
        )
        expect(skippedClaude == nil, "non-assistant Claude lines are ignored")

        let codexAccount = Account(provider: .codex, label: "Default", slug: "default", homePath: "/tmp")
        let turnContext = """
        {"timestamp":"2026-09-05T08:59:30.000Z","type":"turn_context","payload":{"model":"gpt-6-astra"}}
        """
        let tokenCount = """
        {"timestamp":"2026-09-05T08:59:36.348Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":24440,"cached_input_tokens":13824,"cache_write_input_tokens":0,"output_tokens":121}}}}
        """
        var codexState = SessionUsageScanner.CodexFileState(sessionID: "sess")
        _ = SessionUsageScanner.consumeCodexLine(turnContext, account: codexAccount, state: &codexState)
        let parsedCodex = SessionUsageScanner.consumeCodexLine(tokenCount, account: codexAccount, state: &codexState)
        expect(parsedCodex?.uncachedInput == 24440 - 13824, "codex uncached is input minus cached")
        expect(parsedCodex?.cachedInput == 13824, "codex cached")
        expect(parsedCodex?.model == "gpt-6-astra", "codex model from turn_context")
        let duplicate = SessionUsageScanner.consumeCodexLine(tokenCount, account: codexAccount, state: &codexState)
        expect(duplicate == nil, "identical consecutive Codex token_count events are skipped")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("harnais-scan-\(UUID().uuidString)")
        let sessions = tmp.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var transcript = Data(repeating: UInt8(ascii: "A"), count: 80_000)
        transcript.append(0x0A)
        transcript.append(contentsOf: Data(turnContext.utf8))
        transcript.append(0x0A)
        transcript.append(contentsOf: Data(tokenCount.utf8))
        transcript.append(0x0A)
        try transcript.write(to: sessions.appendingPathComponent("rollout.jsonl"))
        let scanned = SessionUsageScanner().scan(accounts: [
            Account(provider: .codex, label: "Tmp", slug: "tmp", homePath: tmp.path)
        ])
        expect(scanned.events.count == 1, "Codex scanner skips giant lines and keeps token_count")
        try? FileManager.default.removeItem(at: tmp)
        let priced = ModelRates.standard.price(for: "claude-opus-5")
        expect(abs(priced.input - 5e-6) < 1e-12, "opus input rate")
        expect(ModelRates.standard.price(for: "codex-auto-review").input == 0, "unknown models are unpriced")

        let usageNow = Date()
        let summary = UsageSummary(events: [
            UsageEvent(
                date: usageNow.addingTimeInterval(-3600),
                provider: .claude,
                accountID: fixtureAccount.id,
                sessionID: "s1",
                model: "claude-fable-5",
                uncachedInput: 100,
                cachedInput: 0,
                cacheWrite: 0,
                output: 20
            )
        ])
        expect(summary.totals(in: UsageRange.hours24, now: usageNow).sessions == 1, "one session in 24h")
        expect(summary.totals(in: UsageRange.hours24, now: usageNow).processed == 120, "processed tokens")
        expect(summary.series(in: .days30, now: usageNow).count >= 30, "daily series fills the window")
        let scale = UsageChartMath.niceScale(peak: 900)
        expect(scale.max == 1_000, "nice scale rounds peak up")
        expect(scale.ticks.contains(0) && scale.ticks.contains(1_000), "nice scale includes 0 and max")
        for peak in [1122.71, 999.0, 1.0, 0.04, 1_400_000_000.0, 37.5, 5000.0, 100.001] {
            let result = UsageChartMath.niceScale(peak: peak)
            expect(result.max >= peak, "nice scale covers peak \(peak)")
            expect(result.ticks.first == 0, "nice scale starts at 0 for \(peak)")
            expect(result.ticks.last == result.max, "nice scale ends at max for \(peak)")
        }
        let emptyScale = UsageChartMath.niceScale(peak: 0)
        expect(emptyScale.max == 0 && emptyScale.ticks == [0], "nice scale with no data")
        let flat = UsageChartMath.smoothCurve([
            UsageChartMath.Point(x: 0, y: 10),
            UsageChartMath.Point(x: 10, y: 10),
            UsageChartMath.Point(x: 20, y: 10),
        ])
        expect(flat.count == 2, "flat series has two cubics")
        expect(flat.allSatisfy { $0.c1.y == 10 && $0.c2.y == 10 }, "flat series stays level")
    }
}
