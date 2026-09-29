import AppKit
import Domain
import Foundation
import Infrastructure

enum CodexWeekTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let week: TimeInterval = 7 * 86_400
        var state = CodexWindowState()
        state.observe(remaining: 100, reset: now.addingTimeInterval(week), now: now)
        expect(!state.awaitingFirstUse, "one full allowance does not prove an unused week")
        state.observe(remaining: 100, reset: now.addingTimeInterval(week + 10), now: now.addingTimeInterval(10))
        expect(!state.awaitingFirstUse && state.observedAt == now, "rapid refresh retains the earlier observation")
        state.observe(remaining: 100, reset: now.addingTimeInterval(week + 70), now: now.addingTimeInterval(70))
        expect(state.awaitingFirstUse, "moving full-week estimate confirms an unused window")
        expect(state.reserveAttempt(manual: false, now: now.addingTimeInterval(70)), "unused week reserves one automatic attempt")
        expect(!state.reserveAttempt(manual: false, now: now.addingTimeInterval(140)), "refresh cannot duplicate an automatic attempt")
        expect(!state.reserveAttempt(manual: true, now: now.addingTimeInterval(90)), "double-click cannot start twice")
        let encoded = try JSONEncoder().encode(state)
        var restored = try JSONDecoder().decode(CodexWindowState.self, from: encoded)
        expect(!restored.reserveAttempt(manual: false, now: now.addingTimeInterval(200)), "restart preserves the attempt guard")
        expect(restored.reserveAttempt(manual: true, now: now.addingTimeInterval(200)), "manual retry is allowed after cooldown")
        restored.observe(remaining: 99, reset: now.addingTimeInterval(week + 200), now: now.addingTimeInterval(210))
        expect(!restored.awaitingFirstUse && !restored.attempted, "actual use clears pending state and arms the next cycle")
        restored.observe(remaining: 100, reset: now.addingTimeInterval(2 * week), now: now.addingTimeInterval(week))
        restored.observe(remaining: 100, reset: now.addingTimeInterval(2 * week + 70), now: now.addingTimeInterval(week + 70))
        expect(restored.awaitingFirstUse && restored.reserveAttempt(manual: false, now: now.addingTimeInterval(week + 70)), "a later unused week can start automatically")

        var active = CodexWindowState()
        active.observe(remaining: 100, reset: now.addingTimeInterval(week), now: now)
        active.observe(remaining: 100, reset: now.addingTimeInterval(week), now: now.addingTimeInterval(70))
        expect(!active.awaitingFirstUse, "rounded zero usage with a fixed anchor remains active")
        var missing = CodexWindowState()
        missing.observe(remaining: 100, reset: nil, now: now)
        missing.observe(remaining: 100, reset: nil, now: now.addingTimeInterval(70))
        expect(missing.awaitingFirstUse, "two full weekly readings without an anchor allow starting")
        var usedMissing = CodexWindowState()
        usedMissing.observe(remaining: 90, reset: nil, now: now)
        usedMissing.observe(remaining: 90, reset: nil, now: now.addingTimeInterval(70))
        expect(!usedMissing.awaitingFirstUse, "missing reset time on a used window does not send a request")
        var quota = FeedQuota(type: "weekly", percentRemaining: 100, resetsAt: now.addingTimeInterval(week), compactTitle: "7d", awaitingFirstUse: true)
        expect(UsageFormat.compactReset(quota, now: now) == "Not started", "unused quota shows status instead of a moving countdown")
        expect(quota.elapsedShare(now: now) == nil, "unused window has no pace clock")
        quota.awaitingFirstUse = nil
        expect(UsageFormat.compactReset(quota, now: now) == "7d 0h", "active quota retains its countdown")
        let legacy = try JSONDecoder().decode(HarnaisSettingsDocument.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        expect(legacy.autoStartCodexWeeks != true, "automatic mode is opt-in for existing installations")
        let args = CodexWeekStarter.arguments(directory: root)
        expect(args.contains("--ephemeral") && args.contains("--ignore-user-config") && args.contains("project_doc_max_bytes=0"), "starter excludes saved conversations and user/project instructions")
        expect(args.contains("read-only") && args.contains("never") && args.contains("features.shell_tool=false"), "starter does not permit shell execution or write access")
        expect(!args.joined(separator: " ").contains("rateLimitResetCredit/consume"), "starting a week never redeems a banked reset")

        let starter = CodexWeekStarter(identity: AppIdentity(dataDirectory: root.appendingPathComponent("week-monitor")))
        let account = Account(provider: .codex, label: "Test", slug: "test", homePath: "/fixture/codex")
        func result(_ time: Date) -> ProbeResult { ProbeResult(quotas: [ProbeQuota(window: "7d", percentRemaining: 100, resetsAt: time.addingTimeInterval(week))]) }
        _ = try starter.observe(account: account, result: result(now), now: now)
        _ = try starter.observe(account: account, result: result(now.addingTimeInterval(70)), now: now.addingTimeInterval(70))
        do {
            _ = try starter.start(account: account, now: now.addingTimeInterval(70), sendRequest: { _ in throw HarnaisError.processFailed("fixture failure") })
            expect(false, "failed starter reports the error")
        } catch { expect(true, "failed starter reports the error") }
        expect(try !starter.start(account: account, now: now.addingTimeInterval(140), sendRequest: { _ in fatalError("must not retry automatically") }), "failed automatic attempt does not retry every minute")
        expect(starter.states()[CodexWeekStarter.key(for: account)]?.message?.contains("Could not start") == true, "failure remains visible for manual retry")
        expect(try starter.start(account: account, manual: true, now: now.addingTimeInterval(140), sendRequest: { _ in }), "manual retry invokes the request after failure")
        expect(starter.states()[CodexWeekStarter.key(for: account)]?.awaitingFirstUse == false, "successful request clears pending display while confirming")
        let badResult = try starter.observe(account: account, result: ProbeResult(error: "offline"), now: now.addingTimeInterval(210))
        expect(badResult == nil, "probe errors cannot trigger a new window")
        let silent = try ProcessRunner().openSession(executable: "/bin/sh", arguments: ["-c", "sleep 2"], environment: [:])
        defer { silent.terminate() }
        let waitStarted = Date()
        do { _ = try silent.waitForResult(id: 42, timeout: 0.1); expect(false, "silent RPC process times out") }
        catch { expect(Date().timeIntervalSince(waitStarted) < 1, "silent RPC process respects the timeout") }
        let sessionOnly = try starter.observe(account: account, result: ProbeResult(quotas: [ProbeQuota(window: "5h", percentRemaining: 100)]), now: now)
        expect(sessionOnly == nil, "session windows do not trigger weekly starts")
    }
}
