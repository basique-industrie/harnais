import Domain
import Foundation

public struct CursorQuotaProbe: Sendable {
    public var runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func probe(account: Account, environment: [String: String]) throws -> ProbeResult {
        let metadataEmail = AccountMetadata().email(for: account)
        guard let token = try resolveToken(account: account, environment: environment) else {
            if account.importedDefault {
                return ProbeResult(
                    email: metadataEmail,
                    error: "Could not read Cursor CLI credentials. Run agent login, then refresh."
                )
            }
            return ProbeResult(email: metadataEmail, error: "Cursor CLI is not signed in for \(account.label)")
        }
        guard let userId = jwtSubject(token.accessToken) else {
            return ProbeResult(email: metadataEmail ?? token.email, error: "Cursor access token is not a JWT")
        }
        let cookie = "WorkosCursorSessionToken=\(userId)::\(token.accessToken)"
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let body: Data
        let status: Int
        do {
            (body, status) = try HTTPClient.getBlocking(request)
        } catch {
            return ProbeResult(email: metadataEmail ?? token.email, error: error.localizedDescription)
        }
        guard status == 200 else {
            return ProbeResult(email: metadataEmail ?? token.email, error: "Cursor usage API returned \(status)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ProbeResult(email: metadataEmail ?? token.email, error: "Cursor usage API returned invalid JSON")
        }
        let quotas = Self.parseSummary(json)
        if quotas.isEmpty {
            return ProbeResult(
                email: metadataEmail ?? token.email,
                error: "Cursor usage API returned no quota pools"
            )
        }
        return ProbeResult(email: metadataEmail ?? token.email ?? jwtEmail(token.accessToken), quotas: quotas)
    }

    public func usageEvents(
        account: Account,
        environment: [String: String],
        since: Date,
        now: Date = Date()
    ) -> [UsageEvent] {
        guard let token = try? resolveToken(account: account, environment: environment),
              let userId = jwtSubject(token.accessToken)
        else { return [] }
        let cookie = "WorkosCursorSessionToken=\(userId)::\(token.accessToken)"
        var events: [UsageEvent] = []
        var seen = Set<String>()
        for page in 1...8 {
            guard let json = fetchEventPage(
                cookie: cookie,
                since: since,
                now: now,
                page: page
            ) else { break }
            let pageEvents = Self.parseEvents(json, account: account)
            if pageEvents.isEmpty { break }
            for event in pageEvents {
                let key = event.dedupeKey ?? "\(event.sessionID):\(event.date.timeIntervalSince1970):\(event.model)"
                if seen.contains(key) { continue }
                seen.insert(key)
                events.append(event)
            }
            let total = (json["totalUsageEventsCount"] as? Int)
                ?? (json["totalUsageEventsCount"] as? NSNumber)?.intValue
            if let total, events.count >= total { break }
            if pageEvents.count < 250 { break }
        }
        return events
    }

    public static func parseEvents(_ json: [String: Any], account: Account) -> [UsageEvent] {
        let rows = (json["usageEventsDisplay"] as? [[String: Any]])
            ?? (json["usageEvents"] as? [[String: Any]])
            ?? []
        return rows.compactMap { row in
            parseEvent(row, account: account)
        }
    }

    public static func parseEvent(_ row: [String: Any], account: Account) -> UsageEvent? {
        let usage = row["tokenUsage"] as? [String: Any] ?? [:]
        let uncached = QuotaReset.double(usage["inputTokens"]) ?? 0
        let cached = QuotaReset.double(usage["cacheReadTokens"]) ?? 0
        let write = QuotaReset.double(usage["cacheWriteTokens"]) ?? 0
        let output = QuotaReset.double(usage["outputTokens"]) ?? 0
        let cents = QuotaReset.double(row["chargedCents"]) ?? QuotaReset.double(usage["totalCents"])
        let reportedCost = cents.map { $0 / 100 }
        guard uncached + cached + write + output > 0 || (reportedCost ?? 0) > 0 else { return nil }
        guard let date = QuotaReset.date(from: row["timestamp"]) else { return nil }
        let model = (row["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let conversation = (row["conversationId"] as? String)
            ?? (row["conversation_id"] as? String)
        let sessionID = conversation.flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(Int(date.timeIntervalSince1970))-\(model)"
        let dedupe = [
            String(Int(date.timeIntervalSince1970 * 1000)),
            model,
            conversation ?? "",
        ].joined(separator: ":")
        return UsageEvent(
            date: date,
            provider: .cursor,
            accountID: account.id,
            sessionID: sessionID,
            model: model.isEmpty ? "cursor" : model,
            uncachedInput: uncached,
            cachedInput: cached,
            cacheWrite: write,
            output: output,
            dedupeKey: dedupe,
            reportedCost: reportedCost
        )
    }

    private func fetchEventPage(
        cookie: String,
        since: Date,
        now: Date,
        page: Int
    ) -> [String: Any]? {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!)
        request.httpMethod = "POST"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.timeoutInterval = 12
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: [
                "startDate": String(Int(since.timeIntervalSince1970 * 1000)),
                "endDate": String(Int(now.timeIntervalSince1970 * 1000)),
                "page": page,
                "pageSize": 250,
            ]
        )
        guard let (body, status) = try? HTTPClient.sendBlocking(request, timeout: 13),
              status == 200,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return json
    }

    public static func parseSummary(_ json: [String: Any]) -> [ProbeQuota] {
        var quotas: [ProbeQuota] = []
        let resetsAt = (json["billingCycleEnd"] as? String).flatMap(QuotaReset.isoDate)
        let individual = json["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        let autoUsed = percentUsed(
            in: plan,
            key: "autoPercentUsed",
            message: json["autoModelSelectedDisplayMessage"] as? String
        )
        let apiUsed = percentUsed(
            in: plan,
            key: "apiPercentUsed",
            message: json["namedModelSelectedDisplayMessage"] as? String
        )

        if autoUsed != nil || apiUsed != nil {
            if let autoUsed {
                quotas.append(pool(window: "Models", percentUsed: autoUsed, resetsAt: resetsAt))
            }
            if let apiUsed {
                quotas.append(pool(window: "Other", percentUsed: apiUsed, resetsAt: resetsAt))
            }
        } else if let plan, plan["enabled"] as? Bool != false {
            if let remaining = QuotaReset.double(plan["remaining"]),
               let limit = QuotaReset.double(plan["limit"]),
               limit > 0 {
                quotas.append(
                    ProbeQuota(
                        window: "Monthly",
                        percentRemaining: remaining / limit * 100,
                        resetsAt: resetsAt,
                        resetText: QuotaReset.caption(resetsAt: resetsAt)
                    )
                )
            } else if let used = QuotaReset.double(plan["used"]),
                      let limit = QuotaReset.double(plan["limit"]),
                      limit > 0 {
                quotas.append(pool(window: "Monthly", percentUsed: used / limit * 100, resetsAt: resetsAt))
            }
        }

        if let onDemand = individual?["onDemand"] as? [String: Any],
           onDemand["enabled"] as? Bool == true,
           let used = QuotaReset.double(onDemand["used"]),
           let limit = QuotaReset.double(onDemand["limit"]),
           limit > 0 {
            quotas.append(pool(window: "On-demand", percentUsed: used / limit * 100, resetsAt: resetsAt))
        }

        if json["limitType"] as? String == "team",
           let team = json["teamUsage"] as? [String: Any],
           let teamOnDemand = team["onDemand"] as? [String: Any],
           teamOnDemand["enabled"] as? Bool == true,
           let used = QuotaReset.double(teamOnDemand["used"]),
           let limit = QuotaReset.double(teamOnDemand["limit"]),
           limit > 0 {
            quotas.append(pool(window: "Team", percentUsed: used / limit * 100, resetsAt: resetsAt))
        }

        if quotas.isEmpty, json["isUnlimited"] as? Bool == true {
            quotas.append(
                ProbeQuota(window: "Monthly", percentRemaining: 100, resetText: "Unlimited")
            )
        }
        return quotas
    }

    private static func pool(window: String, percentUsed: Double, resetsAt: Date?) -> ProbeQuota {
        ProbeQuota(
            window: window,
            percentRemaining: max(0, 100 - percentUsed),
            resetsAt: resetsAt,
            resetText: QuotaReset.caption(resetsAt: resetsAt)
        )
    }

    static func percentUsed(in plan: [String: Any]?, key: String, message: String?) -> Double? {
        if let plan, let value = QuotaReset.double(plan[key]) {
            return value
        }
        return percentUsed(fromDisplayMessage: message)
    }

    static func percentUsed(fromDisplayMessage message: String?) -> Double? {
        guard let message, let prefix = message.range(of: "You've used ") else { return nil }
        let rest = message[prefix.upperBound...]
        guard let percentSign = rest.firstIndex(of: "%") else { return nil }
        return Double(rest[..<percentSign].trimmingCharacters(in: .whitespaces))
    }

    private struct CursorToken {
        var accessToken: String
        var email: String?
    }

    private func resolveToken(account: Account, environment: [String: String]) throws -> CursorToken? {
        let extraAccount = account.env["CURSOR_CONFIG_DIR"] != nil && !account.importedDefault
        var dirs: [String] = []
        if let config = account.env["CURSOR_CONFIG_DIR"] { dirs.append(config) }
        dirs.append(account.homePath)
        for dir in dirs {
            if let token = token(fromAuthJSON: URL(fileURLWithPath: dir).appendingPathComponent("auth.json")) {
                return token
            }
        }
        if extraAccount { return nil }
        return try tokenFromKeychain(environment: environment)
    }

    private func tokenFromKeychain(environment: [String: String]) throws -> CursorToken? {
        let result = try runner.run(
            executable: "/usr/bin/security",
            arguments: [
                "find-generic-password",
                "-s", "cursor-access-token",
                "-a", "cursor-user",
                "-w",
            ],
            environment: environment,
            timeout: 6
        )
        let token = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !token.isEmpty, token.split(separator: ".").count >= 2 else {
            return nil
        }
        return CursorToken(accessToken: token, email: jwtEmail(token))
    }

    private func token(fromAuthJSON url: URL) -> CursorToken? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let access = (root["accessToken"] as? String)
            ?? (root["access_token"] as? String)
            ?? ((root["tokens"] as? [String: Any])?["access_token"] as? String)
        guard let access, !access.isEmpty else { return nil }
        let email = (root["email"] as? String) ?? jwtEmail(access)
        return CursorToken(accessToken: access, email: email)
    }

    private func jwtSubject(_ token: String) -> String? {
        JWTPayload.string(token, key: "sub")
    }

    private func jwtEmail(_ token: String) -> String? {
        JWTPayload.string(token, key: "email") ?? JWTPayload.string(token, key: "sub")
    }
}
