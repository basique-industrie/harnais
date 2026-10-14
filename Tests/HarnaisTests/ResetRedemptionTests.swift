import Domain
import Foundation
import Infrastructure

/// Redemption tests use injected transports only. They must never reach a provider:
/// a real consume call spends a real banked reset.
enum ResetRedemptionTests {
    /// Records every call so a test can prove what was (not) sent.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(method: String, params: [String: Any]?)] = []
        private var _requests: [URLRequest] = []
        var calls: [(method: String, params: [String: Any]?)] { lock.withLock { _calls } }
        var requests: [URLRequest] { lock.withLock { _requests } }
        func record(_ method: String, _ params: [String: Any]?) { lock.withLock { _calls.append((method, params)) } }
        func record(_ request: URLRequest) { lock.withLock { _requests.append(request) } }
    }

    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let now = QuotaReset.isoDate("2026-10-14T08:00:00Z")!
        let expiry = now.addingTimeInterval(2 * 86_400)
        let dataDirectory = root.appendingPathComponent("reset-redemption")
        let identity = AppIdentity(bundleIdentifier: AppIdentity.developmentBundleIdentifier, dataDirectory: dataDirectory)
        let store = ResetAttemptStore(identity: identity)
        let codexAccount = Account(provider: .codex, label: "Codex", slug: "codex", homePath: "/tmp/codex")
        let claudeAccount = Account(provider: .claude, label: "Claude", slug: "claude", homePath: "/tmp/claude")

        // MARK: plan

        let plan = ResetPlan(provider: .codex, creditID: "c1", title: "Full reset", availableCount: 3,
                             expiresAt: expiry, windows: [.init(name: "5h", percentRemaining: 40), .init(name: "7d", percentRemaining: 0)])
        expect(plan.blocker == nil, "an empty weekly quota can be reset, whatever the session has left")
        let rows = plan.detailRows(now: now)
        expect(rows.first == .init(label: "Spends", value: "1 of 3 banked resets"), "dialog states the cost")
        expect(rows.contains(.init(label: "Now", value: "5h 40% left · 7d 0% left")), "dialog shows current usage")
        expect(rows.contains(.init(label: "Expires", value: "in 2d 0h")), "dialog shows the expiry")
        expect(plan.dialogTitle == "Use a banked reset?", "unblocked plan asks for confirmation")

        let partly = ResetPlan(provider: .codex, availableCount: 3, windows: [.init(name: "7d", percentRemaining: 66)])
        expect(partly.blocker == "Available once the weekly quota is empty. 7d has 66% left.", "a weekly quota with allowance left blocks the reset")
        expect(partly.detailRows(now: now).allSatisfy { $0.label != "Spends" }, "a blocked plan shows only why")
        expect(ResetPlan.weeklyGate([.init(name: "5h", percentRemaining: 0), .init(name: "7d", percentRemaining: 40)]) != nil,
               "an empty session does not unlock the reset")
        expect(ResetPlan.weeklyGate([.init(name: "5h", percentRemaining: 100), .init(name: "7d", percentRemaining: 0)]) == nil,
               "an empty weekly quota unlocks the reset")
        expect(ResetPlan.weeklyGate([.init(name: "7d", percentRemaining: 0.4)]) == nil, "a weekly quota that rounds to 0% counts as empty")
        expect(ResetPlan.weeklyGate([.init(name: "7d", percentRemaining: 0.6)]) != nil, "a weekly quota that rounds to 1% is not empty")
        expect(ResetPlan.weeklyGate([.init(name: "30d", percentRemaining: 10)])?.contains("plan quota") == true, "monthly plans gate on the plan quota")
        expect(ResetPlan.weeklyGate([]) == nil, "unknown usage is left to the live check")
        expect(ResetPlan(provider: .codex, availableCount: 0, windows: []).blocker != nil, "zero credits block the reset")
        let unused = partly

        // MARK: Codex

        nonisolated(unsafe) let creditsBlock: [String: Any] = [
            "availableCount": 2,
            "credits": [
                ["id": "late", "status": "available", "expiresAt": expiry.addingTimeInterval(3600).timeIntervalSince1970, "title": "Full reset"],
                ["id": "gone", "status": "redeemed", "expiresAt": now.timeIntervalSince1970],
                ["id": "soon", "status": "available", "expiresAt": expiry.timeIntervalSince1970, "title": "Full reset"],
            ],
        ]
        expect(ResetCreditsParser.codexCredits(creditsBlock).map(\.id) == ["soon", "late"], "Codex credits are ordered by expiry and skip redeemed ones")

        func codex(_ recorder: Recorder, consume: @escaping @Sendable ([String: Any]?) throws -> [String: Any]) -> ResetCreditRedeemer {
            ResetCreditRedeemer(attempts: store, codexCall: { _, _, method, params in
                recorder.record(method, params)
                if method == "account/rateLimits/read" {
                    return ["rateLimits": ["secondary": ["usedPercent": 100, "windowDurationMins": 10080]],
                            "rateLimitResetCredits": creditsBlock]
                }
                return try consume(params)
            }, organizationID: { _ in nil })
        }
        struct Dropped: Error {}

        let planned = Recorder()
        let codexPlan = try codex(planned) { _ in throw Dropped() }.plan(for: codexAccount, environment: [:], now: now)
        expect(planned.calls.map { $0.method } == ["account/rateLimits/read"], "planning only reads limits")
        expect(codexPlan.creditID == "soon" && codexPlan.availableCount == 2, "plan targets the soonest-expiring credit")
        expect(codexPlan.windows == [.init(name: "7d", percentRemaining: 0)], "plan shows live usage")
        expect(store.pendingKey(for: ResetAttemptStore.scope(provider: .codex, accountID: codexAccount.id, creditID: "soon")) == nil,
               "planning stores no idempotency key")

        let scope = ResetAttemptStore.scope(provider: .codex, accountID: codexAccount.id, creditID: "soon")
        let lost = Recorder()
        let first = codex(lost) { _ in throw Dropped() }.redeem(codexPlan, account: codexAccount, environment: [:])
        guard case .unconfirmed = first else { expect(false, "a dropped Codex session is unconfirmed, not failed"); return }
        let heldKey = store.pendingKey(for: scope)
        expect(heldKey != nil, "an unconfirmed attempt keeps its idempotency key")
        expect(lost.calls.last?.method == "account/rateLimitResetCredit/consume", "Codex uses the consume RPC")
        expect(lost.calls.last?.params?["creditId"] as? String == "soon", "Codex consumes the planned credit")
        expect(lost.calls.last?.params?["idempotencyKey"] as? String == heldKey, "Codex sends the stored key")

        let retry = Recorder()
        let again = codex(retry) { _ in ["outcome": "alreadyRedeemed"] }.redeem(codexPlan, account: codexAccount, environment: [:])
        expect(again == .alreadyRedeemed, "a retried attempt reports the credit as already applied")
        expect(retry.calls.last?.params?["idempotencyKey"] as? String == heldKey, "a retry reuses the same key")
        expect(store.pendingKey(for: scope) == nil, "a final answer retires the key")

        for (raw, want) in [("reset", ResetOutcome.reset(remaining: 1)), ("nothingToReset", .nothingToReset), ("noCredit", .noCredit)] {
            let result = codex(Recorder()) { _ in ["outcome": raw] }.redeem(codexPlan, account: codexAccount, environment: [:])
            expect(result == want, "Codex outcome \(raw) maps to \(want)")
            expect(store.pendingKey(for: scope) == nil, "Codex outcome \(raw) retires the key")
        }
        let odd = codex(Recorder()) { _ in ["outcome": "somethingNew"] }.redeem(codexPlan, account: codexAccount, environment: [:])
        expect(odd.message.contains("unexpected") && store.pendingKey(for: scope) != nil, "an unknown Codex outcome is unconfirmed and keeps the key")
        store.finish(scope)

        let blockedRecorder = Recorder()
        let blocked = codex(blockedRecorder) { _ in ["outcome": "reset"] }.redeem(unused, account: codexAccount, environment: [:])
        expect(blocked == .notSent(unused.blocker!) && blockedRecorder.calls.isEmpty, "a blocked plan never reaches the provider")
        let wrongAccount = codex(blockedRecorder) { _ in ["outcome": "reset"] }.redeem(codexPlan, account: claudeAccount, environment: [:])
        expect(wrongAccount.succeeded == false && blockedRecorder.calls.isEmpty, "a plan cannot be redeemed on another provider's account")

        // MARK: Claude

        let org = "11111111-2222-3333-4444-555555555555"
        func offer(_ edits: [String: Any] = [:], block: [String: Any] = [:]) -> Data {
            let grant: [String: Any] = [
                "id": "next", "label": "Weekly reset", "resets_left": 1, "usable_now": true, "use_requires_limit": true,
                "ends_at": "2026-10-16T08:00:00Z", "clears": ["five_hour", "seven_day"],
            ].merging(edits) { _, new in new }
            let cedar: [String: Any] = ["eligible": true, "at_limit": true, "next_grant_id": "next", "grants": [grant]]
                .merging(block) { _, new in new }
            let usage: [String: Any] = ["five_hour": ["utilization": 100], "seven_day": ["utilization": 100],
                                        "seven_day_opus": ["utilization": 5], "cedar_ember": cedar]
            return try! JSONSerialization.data(withJSONObject: usage)
        }
        func claude(_ recorder: Recorder, usage: Data, status: Int = 200, post: @escaping @Sendable () throws -> (Data, Int)) -> ResetCreditRedeemer {
            ResetCreditRedeemer(attempts: store, http: { request in
                recorder.record(request)
                if request.httpMethod == "GET" { return (usage, 200) }
                return try post()
            }, claudeRequest: { _, _, url, method in
                var request = URLRequest(url: url)
                request.httpMethod = method
                return request
            }, organizationID: { _ in org })
        }

        let usageRecorder = Recorder()
        let claudePlan = try claude(usageRecorder, usage: offer()) { throw Dropped() }.plan(for: claudeAccount, environment: [:], now: now)
        expect(usageRecorder.requests.count == 1 && usageRecorder.requests[0].httpMethod == "GET", "Claude planning is a single GET")
        expect(claudePlan.blocker == nil && claudePlan.creditID == "next", "an at-limit Claude account can use its next grant")
        expect(claudePlan.clears == ["5h", "7d"], "plan names the limits the grant clears")
        expect(claudePlan.windows.map(\.name) == ["5h", "7d", "opus"], "plan shows every limit, so the weekly gate sees the weekly quota")

        func blocker(_ edits: [String: Any] = [:], block: [String: Any] = [:]) throws -> String? {
            try claude(Recorder(), usage: offer(edits, block: block)) { throw Dropped() }
                .plan(for: claudeAccount, environment: [:], now: now).blocker
        }
        expect(try blocker(block: ["at_limit": false])?.contains("reached a limit") == true, "a limit-only grant waits for a limit")
        expect(try blocker(["use_requires_limit": false], block: ["at_limit": false]) == nil, "an anytime grant is usable once the weekly quota is empty")
        expect(try blocker(["paused": true]) != nil, "a paused grant is blocked")
        expect(try blocker(["usable_now": false]) != nil, "a not-yet-usable grant is blocked")
        expect(try blocker(["ends_at": "2026-10-01T00:00:00Z"]) != nil, "an expired grant is blocked")
        expect(try blocker(["ends_at": "garbled"]) != nil, "an unreadable expiry is not treated as never expiring")
        expect(try blocker(block: ["cooldown_until": "2026-10-14T09:00:00Z"])?.contains("recently") == true, "a cooldown blocks the reset")
        expect(try blocker(block: ["eligible": false]) != nil, "an ineligible account is blocked")
        expect(try blocker(["resets_left": 0]) != nil, "a spent grant is blocked")

        let weeklyLeft = try? JSONSerialization.jsonObject(with: offer()) as? [String: Any]
        var partlyUsed = weeklyLeft ?? [:]
        partlyUsed["seven_day"] = ["utilization": 34]
        let partialPlan = try claude(Recorder(), usage: JSONSerialization.data(withJSONObject: partlyUsed)) { throw Dropped() }
            .plan(for: claudeAccount, environment: [:], now: now)
        expect(partialPlan.blocker?.contains("weekly quota is empty") == true && partialPlan.blocker?.contains("66%") == true,
               "Claude with weekly allowance left is blocked even when its grant is usable")

        let claudeScope = ResetAttemptStore.scope(provider: .claude, accountID: claudeAccount.id, creditID: "next")
        func post(_ result: String, extra: [String: Any] = [:]) -> @Sendable () throws -> (Data, Int) {
            let data = try! JSONSerialization.data(withJSONObject: ["result": result].merging(extra) { _, new in new })
            return { (data, 200) }
        }
        let sent = Recorder()
        let done = claude(sent, usage: offer(), post: post("reset", extra: ["resets_left": 0])).redeem(claudePlan, account: claudeAccount, environment: [:])
        expect(done == .reset(remaining: 0), "Claude reset reports the credits left")
        let request = sent.requests.first
        expect(request?.url?.absoluteString == "https://api.anthropic.com/api/organizations/\(org)/reset_rate_limits", "Claude posts to the organization reset endpoint")
        let body = request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        expect(body?["program"] == "cedar_ember" && body?["grant_id"] == "next", "Claude body names the program and grant")
        expect(body?["request_id"]?.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil, "Claude request id matches the accepted format")
        expect(store.pendingKey(for: claudeScope) == nil, "a Claude reset retires the key")

        let mapping: [(String, ResetOutcome)] = [("already_used", .alreadyRedeemed), ("not_limited", .nothingToReset),
                                                 ("cooldown", .cooldown), ("ineligible", .ineligible)]
        for (raw, want) in mapping {
            let result = claude(Recorder(), usage: offer(), post: post(raw)).redeem(claudePlan, account: claudeAccount, environment: [:])
            expect(result == want, "Claude result \(raw) maps to \(want)")
        }
        let unavailable = claude(Recorder(), usage: offer(), post: post("unavailable")).redeem(claudePlan, account: claudeAccount, environment: [:])
        expect(unavailable == .unavailable && store.pendingKey(for: claudeScope) != nil, "Claude unavailable keeps the key for a safe retry")
        let key = store.pendingKey(for: claudeScope)
        let retried = Recorder()
        _ = claude(retried, usage: offer(), post: post("already_used")).redeem(claudePlan, account: claudeAccount, environment: [:])
        let retryBody = retried.requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        expect(retryBody?["request_id"] == key, "a Claude retry reuses the same request id")
        expect(store.pendingKey(for: claudeScope) == nil, "the retry's final answer retires the key")

        let limited = claude(Recorder(), usage: offer(), post: { (Data(), 429) }).redeem(claudePlan, account: claudeAccount, environment: [:])
        guard case .unconfirmed = limited else { expect(false, "Claude 429 is unconfirmed"); return }
        expect(store.pendingKey(for: claudeScope) != nil, "Claude 429 keeps the key")
        store.finish(claudeScope)
        let denied = claude(Recorder(), usage: offer(), post: { (Data(), 401) }).redeem(claudePlan, account: claudeAccount, environment: [:])
        guard case .notSent = denied else { expect(false, "Claude 401 asks to sign in again"); return }
        let network = claude(Recorder(), usage: offer()) { throw Dropped() }.redeem(claudePlan, account: claudeAccount, environment: [:])
        guard case .unconfirmed = network else { expect(false, "a dropped Claude request is unconfirmed"); return }
        store.finish(claudeScope)

        let noOrg = ResetCreditRedeemer(attempts: store, http: { _ in throw Dropped() }, claudeRequest: { _, _, url, _ in URLRequest(url: url) },
                                        organizationID: { _ in nil })
        let missing = noOrg.redeem(claudePlan, account: claudeAccount, environment: [:])
        guard case .notSent = missing else { expect(false, "a missing organization sends nothing"); return }

        let storeFile = dataDirectory.appendingPathComponent("reset-attempts.json")
        expect(try (FileManager.default.attributesOfItem(atPath: storeFile.path)[.posixPermissions] as? Int) == 0o600, "attempt store is owner-only")
        expect(ResetOutcome.reset(remaining: 2).message.contains("2 left"), "success message states what is left")
        expect(ResetOutcome.unconfirmed("x").message.contains("cannot spend a second reset"), "unconfirmed message explains retry safety")
    }
}
