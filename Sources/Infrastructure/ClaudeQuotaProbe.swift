import Domain
import Foundation

public struct ClaudeQuotaProbe: Sendable {
    public var runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func probe(account: Account, environment: [String: String]) throws -> ProbeResult {
        let email = AccountMetadata().email(for: account)
        if let api = try? probeAPI(account: account, environment: environment) {
            return ProbeResult(email: email ?? api.email, quotas: api.quotas, error: api.error, resetCredits: api.resetCredits)
        }
        guard let binary = BinaryLocator.resolve(.claude, override: account.binaryPath) else {
            return ProbeResult(email: email, error: HarnaisError.binaryNotFound("claude").localizedDescription)
        }
        let result = try runner.run(
            executable: binary,
            arguments: ["/usage", "--allowed-tools", ""],
            environment: environment,
            timeout: 25,
            workingDirectory: URL(fileURLWithPath: account.homePath)
        )
        let quotas = Self.parseUsage(result.output)
        if quotas.isEmpty {
            return ProbeResult(email: email, error: "Could not read Claude usage for \(account.label)")
        }
        return ProbeResult(email: email, quotas: quotas)
    }

    private func probeAPI(account: Account, environment: [String: String]) throws -> ProbeResult {
        guard let token = ClaudeCredentials.accessToken(account: account, environment: environment, runner: runner)
        else { throw HarnaisError.notLoggedIn }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        if let binary = BinaryLocator.resolve(.claude, override: account.binaryPath),
           let result = try? runner.run(executable: binary, arguments: ["--version"], environment: environment, timeout: 4),
           let version = ConnectionProbe.parseVersion(result.output) {
            request.setValue("claude-cli/\(version) (external, cli)", forHTTPHeaderField: "User-Agent")
        }
        request.timeoutInterval = 15
        var (body, status) = try HTTPClient.getBlocking(request)
        // An optional credit query must not prevent regular limits from loading.
        if status != 200 {
            request.url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
            (body, status) = try HTTPClient.getBlocking(request)
        }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { throw HarnaisError.processFailed("Claude usage API returned \(status)") }
        return ProbeResult(email: AccountMetadata().email(for: account), quotas: Self.parseAPI(json),
                           resetCredits: ResetCreditsParser.claude(json["cedar_ember"]))
    }

    public static func parseUsage(_ text: String) -> [ProbeQuota] {
        var quotas: [ProbeQuota] = []
        if let session = extractPercent(label: "Current session", text: text) {
            let reset = extractReset(after: "Current session", text: text)
            quotas.append(ProbeQuota(
                window: "5h",
                percentRemaining: remaining(from: session),
                resetsAt: QuotaReset.date(fromEnglishReset: reset),
                resetText: reset
            ))
        }
        if let weekly = extractPercent(label: "Current week (all models)", text: text)
            ?? extractPercent(label: "Current week", text: text) {
            let reset = extractReset(after: "Current week", text: text)
            quotas.append(ProbeQuota(
                window: "7d",
                percentRemaining: remaining(from: weekly),
                resetsAt: QuotaReset.date(fromEnglishReset: reset),
                resetText: reset
            ))
        }
        return quotas
    }

    public static func parseAPI(_ json: [String: Any]) -> [ProbeQuota] {
        var quotas: [ProbeQuota] = []
        func append(_ title: String, from value: Any?) {
            guard quotas.contains(where: { $0.window == title }) == false,
                  let quota = quota(from: value, title: title)
            else { return }
            quotas.append(quota)
        }
        append("5h", from: json["five_hour"])
        append("7d", from: json["seven_day"])
        append("sonnet", from: json["seven_day_sonnet"])
        append("opus", from: json["seven_day_opus"])
        if let rateLimits = json["rate_limits"] as? [String: Any] {
            append("5h", from: rateLimits["five_hour"])
            append("7d", from: rateLimits["seven_day"])
            if let scoped = rateLimits["model_scoped"] as? [[String: Any]] {
                for entry in scoped {
                    let name = (entry["display_name"] as? String)?
                        .split(separator: " ").first.map(String.init)?.lowercased()
                    append(name ?? "model", from: entry)
                }
            }
        }
        if let limits = json["limits"] as? [[String: Any]] {
            for entry in limits {
                guard entry["kind"] as? String == "weekly_scoped" else { continue }
                let scope = entry["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = (model?["display_name"] as? String)?
                    .split(separator: " ").first.map(String.init)?.lowercased()
                append(name ?? "model", from: entry)
            }
        }
        return quotas
    }

    private static func quota(from value: Any?, title: String) -> ProbeQuota? {
        guard let block = value as? [String: Any] else { return nil }
        let remainingPct: Double
        if let remaining = QuotaReset.double(block["remaining"]),
           let limit = QuotaReset.double(block["limit"]),
           limit > 0 {
            remainingPct = remaining / limit * 100
        } else if let percent = QuotaReset.double(block["percent"]) {
            remainingPct = percent <= 1 ? max(0, (1 - percent) * 100) : max(0, 100 - percent)
        } else if let utilization = QuotaReset.double(block["utilization"]) {
            // The OAuth API reports 0–100, including values below 1%.
            remainingPct = min(100, max(0, 100 - utilization))
        } else if let used = QuotaReset.double(block["used"]) {
            remainingPct = used <= 1 ? max(0, (1 - used) * 100) : max(0, 100 - used)
        } else {
            return nil
        }
        let resetsAt = QuotaReset.date(
            from: block["resets_at"] ?? block["resetsAt"] ?? block["reset_at"]
        )
        return ProbeQuota(
            window: title,
            percentRemaining: remainingPct,
            resetsAt: resetsAt,
            resetText: QuotaReset.caption(resetsAt: resetsAt)
        )
    }

    private struct ParsedPercent {
        var value: Double
        var isUsed: Bool
    }

    /// Claude `/usage` prints `42% used` (consumed) or, less often, `58% left`.
    /// Cursor and Codex probes already convert used → remaining; this must too.
    private static func extractPercent(label: String, text: String) -> ParsedPercent? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = "\(escaped)[^\\d%]{0,80}(\\d{1,3}(?:\\.\\d+)?)\\s*%(?:\\s*(used|left))?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let valueRange = Range(match.range(at: 1), in: text),
              let value = Double(text[valueRange])
        else { return nil }
        let unit: String
        if match.numberOfRanges > 2,
           match.range(at: 2).location != NSNotFound,
           let unitRange = Range(match.range(at: 2), in: text) {
            unit = text[unitRange].lowercased()
        } else {
            unit = "used"
        }
        return ParsedPercent(value: value, isUsed: unit != "left")
    }

    private static func extractReset(after label: String, text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        let needle = label.lowercased()
        for (index, line) in lines.enumerated() where line.lowercased().contains(needle) {
            for candidate in lines.dropFirst(index) {
                let lower = candidate.lowercased()
                if lower.contains("current "), !lower.contains(needle) {
                    break
                }
                guard lower.contains("reset") else { continue }
                var trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if let range = trimmed.range(of: "resets", options: .caseInsensitive) {
                    trimmed = String(trimmed[range.lowerBound...])
                }
                trimmed = trimmed.replacingOccurrences(
                    of: #"\s+\d{1,3}%\s*(?:used|left)\s*$"#,
                    with: "",
                    options: .regularExpression
                )
                return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func remaining(from parsed: ParsedPercent) -> Double {
        if parsed.isUsed {
            return max(0, min(100, 100 - parsed.value))
        }
        return max(0, min(100, parsed.value))
    }
}
