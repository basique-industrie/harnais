import Domain
import Foundation
import Infrastructure

enum CodexCreditsTests {
    static func run(expect: (Bool, String) -> Void) throws {
        let credits: [String: Any] = ["hasCredits": true, "unlimited": false, "balance": "1234.50"]
        let snapshot: [String: Any] = [
            "limitId": "codex", "credits": credits,
            "primary": ["usedPercent": 20, "windowDurationMins": 10080],
        ]
        let expected = CodexCredits(hasCredits: true, unlimited: false, balance: "1234.50")
        for payload in [snapshot, ["rateLimits": snapshot], ["rateLimitsByLimitId": ["codex": snapshot]]] {
            let result = CodexQuotaProbe.parseResponse(payload)
            expect(result.codexCredits == expected, "Codex credits decode across supported snapshot envelopes")
            expect(result.quotas.count == 1, "credit parsing preserves subscription limits")
        }
        let response = CodexQuotaProbe.parseResponse([
            "rateLimits": ["credits": ["hasCredits": false, "unlimited": false]],
            "rateLimitsByLimitId": ["codex": snapshot, "other": ["credits": credits]],
            "rateLimitResetCredits": ["availableCount": 3],
        ])
        expect(response.codexCredits == expected, "Codex map entry is authoritative over legacy snapshot")
        expect(response.resetCredits?.availableCount == 3, "extra credits remain independent of banked resets")
        expect(CodexQuotaProbe.parseResponse(["rate_limits": ["credits": ["has_credits": true, "unlimited": false, "balance": "12.5"]]]).codexCredits?.balance == "12.5", "snake-case snapshots and flags decode")
        expect(CodexQuotaProbe.parseResponse(["rateLimits": ["limitId": "other", "credits": credits]]).codexCredits == nil, "unrelated limits cannot supply Codex credits")
        expect(CodexQuotaProbe.parseResponse(["rateLimitsByLimitId": ["other": snapshot]]).codexCredits == nil, "unrelated map entries are ignored")
        expect(CodexQuotaProbe.parseResponse(["rateLimits": ["credits": credits]]).codexCredits == expected, "credits can load without quota windows")
        for bad: Any in [NSNull(), [:], ["hasCredits": 1, "unlimited": false], ["hasCredits": true, "unlimited": "false"],
                         ["hasCredits": true, "unlimited": false, "balance": 42],
                         ["hasCredits": true, "unlimited": false, "balance": "NaN"],
                         ["hasCredits": true, "unlimited": false, "balance": "-10"],
                         ["hasCredits": true, "unlimited": false, "balance": ""]] {
            var invalid = snapshot
            invalid["credits"] = bad
            let result = CodexQuotaProbe.parseResponse(["rateLimits": invalid])
            expect(result.codexCredits == nil && result.quotas.count == 1, "malformed credits stay unknown without discarding usage")
        }
        expect(CodexQuotaProbe.parseResponse([:]).codexCredits == nil, "missing credit data stays unknown")
        let zero = CodexQuotaProbe.parseResponse(["credits": ["hasCredits": false, "unlimited": false, "balance": NSNull()]])
        expect(zero.codexCredits?.balanceLabel == "0", "explicit lack of credits displays zero")
        expect(CodexCredits(hasCredits: true, unlimited: true, balance: "0").balanceLabel == "Unlimited", "unlimited takes precedence over balance")
        expect(CodexCredits(hasCredits: true, unlimited: false).balanceLabel == "Available", "availability without a balance does not invent an amount")
        let english = Locale(identifier: "en_US")
        let french = Locale(identifier: "fr_FR")
        func formatted(_ balance: String, locale: Locale = Locale(identifier: "en_US")) -> String {
            CodexCredits(hasCredits: true, unlimited: false, balance: balance).formattedBalance(locale: locale)
        }
        expect(expected.formattedBalance(locale: english) == "1,234.5", "credits group thousands and omit unnecessary trailing zeros")
        expect(formatted("59705.1154555000") == "59,705.12", "long provider balance rounds to two decimals")
        expect(formatted("59705.1154555000", locale: french) == "59\u{202F}705,12", "credits use local grouping and decimal separators")
        expect(formatted("1000.000000") == "1,000", "whole balances omit the decimal portion")
        expect(formatted("999.999") == "1,000", "rounding carries into the integer portion")
        expect(formatted("0.0001") == "< 0.01", "small available balances do not appear depleted")
        expect(formatted("0.0001", locale: french) == "< 0,01", "small balance threshold is localized")
        expect(formatted("0.01000") == "0.01" && formatted("0.0000") == "0", "threshold and zero remain exact")
        expect(expected.balance == "1234.50", "display formatting preserves the cached provider precision")

        let decoder = JSONDecoder()
        let legacy = try decoder.decode(AccountQuotaSnapshot.self, from: Data(#"{"id":"old","provider":"codex","label":"Old","quotas":[]}"#.utf8))
        expect(legacy.codexCredits == nil, "existing cached feeds decode without Codex credits")
        let account = AccountQuotaSnapshot(id: "new", provider: "codex", label: "New", codexCredits: expected)
        expect(try decoder.decode(AccountQuotaSnapshot.self, from: JSONEncoder().encode(account)) == account, "Codex credits survive feed caching")
    }
}
