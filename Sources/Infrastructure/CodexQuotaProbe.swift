import Domain
import Foundation

public struct CodexQuotaProbe: Sendable {
    public var runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func probe(account: Account, environment: [String: String]) throws -> ProbeResult {
        let email = AccountMetadata().email(for: account)
        guard let binary = BinaryLocator.resolve(.codex, override: account.binaryPath) else {
            return ProbeResult(email: email, error: HarnaisError.binaryNotFound("codex").localizedDescription)
        }
        do {
            var result = try fetchViaRPC(executable: binary, environment: environment, planType: AccountMetadata().codexPlanType(for: account))
            result.email = email
            if result.quotas.isEmpty {
                result.error = "Codex has not reported rate limits yet"
            }
            return result
        } catch {
            let result = try runner.run(
                executable: binary,
                arguments: ["-s", "read-only", "-a", "never"],
                environment: environment,
                timeout: 20,
                input: "/status\n"
            )
            let quotas = Self.parseTTY(result.output)
            if quotas.isEmpty {
                return ProbeResult(email: email, error: error.localizedDescription)
            }
            return ProbeResult(email: email, quotas: quotas)
        }
    }

    private func fetchViaRPC(executable: String, environment: [String: String], planType: String?) throws -> ProbeResult {
        let session = try runner.openSession(
            executable: executable,
            arguments: ["-s", "read-only", "-a", "never", "app-server"],
            environment: environment
        )
        defer { session.terminate() }
        try session.sendJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "harnais", "version": "0.1.0"], "capabilities": ["experimentalApi": true]],
        ])
        try session.sendJSON(["jsonrpc": "2.0", "method": "initialized"])
        try session.sendJSON(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"])
        let result = try session.waitForResult(id: 2, timeout: 12)
        return Self.parseResponse(result, planType: planType)
    }

    public static func parseResponse(_ response: [String: Any], planType: String? = nil, now: Date = Date()) -> ProbeResult {
        ProbeResult(
            quotas: parseRateLimits(response, planType: planType, now: now),
            resetCredits: ResetCreditsParser.codex(response["rateLimitResetCredits"])
        )
    }

    private static let sessionMins = 5.0 * 60
    private static let weekMins = 7.0 * 24 * 60
    private static let monthMins = 30.0 * 24 * 60

    public static func parseRateLimits(_ rateLimits: [String: Any], planType: String? = nil, now: Date = Date()) -> [ProbeQuota] {
        if let byId = rateLimits["rateLimitsByLimitId"] as? [String: Any]
            ?? rateLimits["rate_limits_by_limit_id"] as? [String: Any],
           let codex = byId["codex"] as? [String: Any] {
            return parseSnapshot(codex, planType: planType, now: now)
        }
        if let nested = rateLimits["rateLimits"] as? [String: Any]
            ?? rateLimits["rate_limits"] as? [String: Any] {
            return parseSnapshot(nested, planType: planType, now: now)
        }
        return parseSnapshot(rateLimits, planType: planType, now: now)
    }

    private static func parseSnapshot(_ snapshot: [String: Any], planType: String?, now: Date) -> [ProbeQuota] {
        if let limitId = snapshot["limitId"] as? String ?? snapshot["limit_id"] as? String,
           limitId != "codex" {
            return []
        }
        let plan = (snapshot["planType"] as? String ?? snapshot["plan_type"] as? String ?? planType)?.lowercased()
        var quotas: [ProbeQuota] = []
        if let primary = window(snapshot["primary"], fallbackMins: primaryFallbackMins(plan), now: now) {
            quotas.append(primary)
        }
        if let secondary = window(snapshot["secondary"], fallbackMins: weekMins, now: now) {
            quotas.append(secondary)
        }
        return quotas
    }

    /// Codex `primary` is a slot, not a duration. Plus keeps a 5h window; Pro's
    /// subscription allowance is weekly; Free/Go are monthly.
    private static func primaryFallbackMins(_ planType: String?) -> Double {
        switch planType {
        case "free", "go": monthMins
        case "pro", "prolite": weekMins
        default: sessionMins
        }
    }

    public static func parseTTY(_ text: String) -> [ProbeQuota] {
        var quotas: [ProbeQuota] = []
        let session = percent(after: ["5h", "session"], in: text)
        let weekly = percent(after: ["7d", "weekly", "week"], in: text)
        if let session {
            quotas.append(ProbeQuota(window: "5h", percentRemaining: session))
        }
        if let weekly {
            quotas.append(ProbeQuota(window: "7d", percentRemaining: weekly))
        }
        return quotas
    }

    private static func window(_ value: Any?, fallbackMins: Double, now: Date) -> ProbeQuota? {
        guard let block = value as? [String: Any] else { return nil }
        let used = QuotaReset.double(block["usedPercent"])
            ?? QuotaReset.double(block["used_percent"])
        guard let used else { return nil }
        let remaining = QuotaReset.remainingPercent(used: used)
        let resetsAt = QuotaReset.date(from: block["resetsAt"] ?? block["resets_at"] ?? block["reset_at"])
            ?? QuotaReset.date(afterSeconds: block["reset_after_seconds"] ?? block["resetAfterSeconds"], now: now)
        let reportedMins = QuotaReset.double(block["windowDurationMins"] ?? block["window_duration_mins"])
        let title = windowTitle(
            reportedMins: reportedMins,
            resetsAt: resetsAt,
            fallbackMins: fallbackMins,
            now: now
        )
        let resetText = (block["resetDescription"] as? String)
            ?? QuotaReset.caption(resetsAt: resetsAt, now: now)
        return ProbeQuota(window: title, percentRemaining: remaining, resetsAt: resetsAt, resetText: resetText)
    }

    /// Prefer Codex's duration; a reset later than a 5h window cannot be a session.
    private static func windowTitle(
        reportedMins: Double?,
        resetsAt: Date?,
        fallbackMins: Double,
        now: Date = Date()
    ) -> String {
        if let reportedMins {
            return title(forMins: reportedMins)
        }
        if let resetsAt {
            let remainingMins = resetsAt.timeIntervalSince(now) / 60
            if remainingMins > sessionMins + 60 {
                return remainingMins >= 20 * 24 * 60 ? "30d" : "7d"
            }
        }
        return title(forMins: fallbackMins)
    }

    private static func title(forMins mins: Double) -> String {
        if mins >= monthMins { return "30d" }
        if mins >= weekMins { return "7d" }
        return "5h"
    }

    private static func percent(after labels: [String], in text: String) -> Double? {
        for label in labels {
            let pattern = "\(NSRegularExpression.escapedPattern(for: label))[^\\d%]{0,40}(\\d{1,3}(?:\\.\\d+)?)\\s*%"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text),
               let value = Double(text[range]) {
                return max(0, 100 - value) < value ? max(0, 100 - value) : value
            }
        }
        return nil
    }
}
