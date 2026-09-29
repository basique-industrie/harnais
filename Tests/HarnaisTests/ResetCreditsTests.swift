import AppKit
import Domain
import Foundation
import Infrastructure

enum ResetCreditsTests {
    static func run(expect: (Bool, String) -> Void) throws {
        expect(ClaudeCredentials.keychainService(environment: [:]) == "Claude Code-credentials", "default Claude login uses the standard Keychain service")
        expect(ClaudeCredentials.keychainService(environment: ["CLAUDE_CONFIG_DIR": "/profiles/work"]) == "Claude Code-credentials-2ea9e238", "Claude profile Keychain service uses the first eight SHA256 digits")
        expect(ClaudeCredentials.keychainService(environment: ["CLAUDE_CONFIG_DIR": "/profiles/work", "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""]) == "Claude Code-credentials", "explicit empty secure storage override selects default Keychain service")
        expect(ClaudeCredentials.keychainService(environment: ["CLAUDE_CONFIG_DIR": "/other", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/profiles/work"]) == ClaudeCredentials.keychainService(environment: ["CLAUDE_CONFIG_DIR": "/profiles/work"]), "secure storage override takes precedence over profile directory")
        let lowUsage = ClaudeQuotaProbe.parseAPI(["five_hour": ["utilization": 1], "seven_day": ["utilization": 0.5]])
        expect(lowUsage.map(\.percentRemaining) == [99, 99.5], "Claude API utilization is percent even below one percent")
        let now = QuotaReset.isoDate("2026-09-28T08:00:00Z")!
        let expiry = QuotaReset.isoDate("2026-10-01T00:00:00Z")!
        let codex = ResetCreditsParser.codex([
            "availableCount": 3,
            "credits": [
                ["status": "available", "expiresAt": expiry.timeIntervalSince1970],
                ["status": "redeemed", "expiresAt": now.timeIntervalSince1970],
                ["status": "available", "expiresAt": expiry.addingTimeInterval(3600).timeIntervalSince1970],
            ],
        ])
        expect(codex == ResetCredits(availableCount: 3, nextExpiresAt: expiry), "Codex uses authoritative count even when detail list is capped; expiry ignores redeemed credits")
        expect(ResetCreditsParser.codex(["availableCount": 0]) == ResetCredits(availableCount: 0), "zero reset credits are known, not unavailable")
        expect(ResetCreditsParser.codex(["availableCount": 2, "credits": NSNull()])?.availableCount == 2, "Codex count works without credit details")
        expect(ResetCreditsParser.codex(nil) == nil && ResetCreditsParser.codex(NSNull()) == nil, "older Codex missing credits remains unknown")
        expect(ResetCreditsParser.codex(["availableCount": -2])?.availableCount == 0, "negative Codex counts clamp to zero")
        for bad: Any in [true, "2", 1.5] {
            expect(ResetCreditsParser.codex(["availableCount": bad]) == nil, "malformed Codex count is not shown as real credits")
        }

        func grant(_ id: String, count: Int = 1, extras: [String: Any] = [:]) -> [String: Any] {
            ["id": id, "resets_left": count, "usable_now": true].merging(extras) { _, new in new }
        }
        func claude(_ grants: [Any], next: String = "next") -> ResetCredits? {
            ResetCreditsParser.claude(["eligible": true, "next_grant_id": next, "grants": grants], now: now)
        }
        let next = grant("next", count: 2, extras: ["ends_at": "2026-10-01T00:00:00Z"])
        let parsed = claude([
            next, grant("other", count: 1), grant("paused", extras: ["paused": true]),
            grant("expired", extras: ["ends_at": "2026-09-01T00:00:00Z"]),
            grant("future", extras: ["usable_now": false]), grant("invalid id"),
            grant("fraction", extras: ["resets_left": 1.5]),
            grant("bad_bool", extras: ["usable_now": 1]),
            grant("bad_pause", extras: ["paused": "false"]),
            grant("date_only", extras: ["ends_at": "2026-10-01"]),
            grant("impossible", extras: ["ends_at": "2027-02-30T00:00:00Z"]),
            grant("garbled", extras: ["ends_at": "tomorrow"]),
        ])
        expect(parsed == ResetCredits(availableCount: 3, nextExpiresAt: expiry), "Claude counts only usable valid unexpired grants and uses the designated grant expiry")
        expect(claude([next], next: "missing")?.availableCount == 0, "Claude needs a usable designated next grant")
        expect(claude([grant("next", extras: ["usable_now": false])])?.availableCount == 0, "unusable Claude next grant reports zero")
        expect(ResetCreditsParser.claude(["eligible": false, "grants": [next]]) == nil, "ineligible Claude accounts do not invent a count")
        expect(ResetCreditsParser.claude(nil) == nil, "missing Claude credits stay unknown")
        expect(claude([grant("next", extras: ["ends_at": NSNull()])])?.availableCount == 1, "Claude grants may have no expiry")

        let rpc: [String: Any] = [
            "rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 300]],
            "rateLimitResetCredits": ["availableCount": 2],
        ]
        let response = CodexQuotaProbe.parseResponse(rpc, now: now)
        expect(response.quotas.count == 1 && response.resetCredits?.availableCount == 2, "Codex probe preserves both windows and account-level credits")
        var malformed = rpc
        malformed["rateLimitResetCredits"] = ["availableCount": "bad"]
        expect(CodexQuotaProbe.parseResponse(malformed).quotas.count == 1, "malformed credits do not discard valid Codex usage")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(AccountQuotaSnapshot.self, from: Data(#"{"id":"old","provider":"codex","label":"Old","quotas":[]}"#.utf8))
        expect(legacy.resetCredits == nil, "old saved quota feeds still decode without credits")
        let account = AccountQuotaSnapshot(id: "new", provider: "codex", label: "New", resetCredits: codex)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        expect(try decoder.decode(AccountQuotaSnapshot.self, from: encoder.encode(account)) == account, "reset count and expiry survive feed caching")
        expect(ResetCredits(availableCount: 1).caption == "1 banked reset available", "single banked reset has singular label")
        expect(ResetCredits(availableCount: 0).caption == "0 banked resets available", "zero banked resets remains explicit")
        expect(codex?.expiryCaption(now: now) == "Next expires in 2d 16h", "expiry is distinct from window reset countdown")
        expect(codex?.expiryCaption(now: expiry) == "Expiry reached · refresh limits", "expired cache prompts refresh rather than claiming the credit is usable")
    }
}
