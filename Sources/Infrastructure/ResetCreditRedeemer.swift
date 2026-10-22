import Domain
import Foundation

/// Redeems a banked reset the way each provider's own client does.
///
/// - Codex: app-server `account/rateLimitResetCredit/consume`
///   (`idempotencyKey`, optional `creditId`).
/// - Claude: `POST /api/organizations/{org}/reset_rate_limits` with the `cedar_ember`
///   program, a `grant_id` and a `request_id`. Claude only redeems its designated next grant.
///
/// Two steps, never one: `plan` reads recent provider state for the confirmation
/// dialog; `redeem` is the only call that can spend a credit. Every transport is injected so
/// tests never reach a provider.
public struct ResetCreditRedeemer: Sendable {
    public typealias HTTP = @Sendable (URLRequest) throws -> (Data, Int)
    public typealias CodexCall = @Sendable (Account, [String: String], String, [String: Any]?) throws -> [String: Any]
    public typealias ClaudeRequest = @Sendable (Account, [String: String], URL, String) throws -> URLRequest

    static let claudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!
    static let claudeProgram = "cedar_ember"
    static let codexConsume = "account/rateLimitResetCredit/consume"

    public var attempts: ResetAttemptStore
    var http: HTTP
    var codexCall: CodexCall
    var claudeRequest: ClaudeRequest
    var organizationID: @Sendable (Account) -> String?

    public init(
        attempts: ResetAttemptStore = ResetAttemptStore(),
        http: @escaping HTTP = ResetCreditRedeemer.liveHTTP,
        codexCall: @escaping CodexCall = ResetCreditRedeemer.liveCodexCall,
        claudeRequest: @escaping ClaudeRequest = ResetCreditRedeemer.liveClaudeRequest,
        organizationID: @escaping @Sendable (Account) -> String? = { AccountMetadata().claudeOrganizationID(for: $0) }
    ) {
        self.attempts = attempts
        self.http = http
        self.codexCall = codexCall
        self.claudeRequest = claudeRequest
        self.organizationID = organizationID
    }

    // MARK: Plan (read-only)

    public func plan(for account: Account, environment: [String: String], now: Date = Date()) throws -> ResetPlan {
        switch account.provider {
        case .codex: try codexPlan(account, environment, now)
        case .claude: try claudePlan(account, environment, now)
        case .cursor, .opencode:
            throw HarnaisError.processFailed("\(account.provider.displayName) has no banked resets.")
        }
    }

    private func codexPlan(_ account: Account, _ environment: [String: String], _ now: Date) throws -> ResetPlan {
        let response = try codexCall(account, environment, "account/rateLimits/read", nil)
        guard let summary = ResetCreditsParser.codex(response["rateLimitResetCredits"]) else {
            throw HarnaisError.processFailed("This Codex version does not report banked resets. Update Codex, then refresh limits.")
        }
        let quotas = CodexQuotaProbe.parseResponse(response, planType: AccountMetadata().codexPlanType(for: account), now: now).quotas
        let next = ResetCreditsParser.codexCredits(response["rateLimitResetCredits"]).first
        return ResetPlan(
            provider: .codex, creditID: next?.id, title: next?.title ?? "Banked reset",
            availableCount: summary.availableCount, expiresAt: next?.expiresAt ?? summary.nextExpiresAt,
            windows: quotas.map { .init(name: $0.window, percentRemaining: $0.percentRemaining) }
        )
    }

    private func claudePlan(_ account: Account, _ environment: [String: String], _ now: Date) throws -> ResetPlan {
        let request = try claudeRequest(account, environment, Self.claudeUsageURL, "GET")
        let (body, status) = try http(request)
        if status == 429 { throw HarnaisError.processFailed(ClaudeUsageClient.rateLimitMessage + " No reset was sent.") }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw HarnaisError.processFailed("Claude usage returned \(status). Sign in again if this persists.")
        }
        let block = json["cedar_ember"]
        let credits = ResetCreditsParser.claude(block, now: now)
        guard let offer = ResetCreditsParser.claudeOffer(block) else {
            throw HarnaisError.processFailed("Claude did not report banked resets for this account.")
        }
        let quotas = ClaudeQuotaProbe.parseAPI(json)
        return ResetPlan(
            provider: .claude, creditID: offer.grantID, title: offer.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Banked reset",
            availableCount: credits?.availableCount ?? 0, expiresAt: offer.expiresAt == .distantPast ? nil : offer.expiresAt,
            clears: offer.clears.compactMap { ResetCreditsParser.claudeLimitNames[$0] }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
            windows: quotas.map { .init(name: $0.window, percentRemaining: $0.percentRemaining) },
            blocker: Self.claudeBlocker(offer, now: now)
        )
    }

    static func claudeBlocker(_ offer: ResetCreditsParser.ClaudeOffer, now: Date) -> String? {
        if !offer.eligible { return "Claude does not offer banked resets to this account right now." }
        guard offer.grantID != nil, offer.resetsLeft > 0 else { return "No banked reset is available." }
        if offer.paused { return "This banked reset is paused by Claude." }
        if let expiresAt = offer.expiresAt, expiresAt <= now { return "This banked reset has expired. Refresh limits." }
        if !offer.usableNow { return "This banked reset cannot be used yet." }
        if let until = offer.cooldownUntil, until > now { return "A reset was used recently. Try again later." }
        if offer.requiresLimit, !offer.atLimit { return "Claude only allows this reset once you have reached a limit." }
        return nil
    }

    // MARK: Redeem (spends a credit)

    /// Never throws. The only call that can spend a credit, and it only runs after a confirmed plan.
    public func redeem(_ plan: ResetPlan, account: Account, environment: [String: String]) -> ResetOutcome {
        guard plan.blocker == nil, plan.provider == account.provider else {
            return .notSent(plan.blocker ?? "This reset does not belong to this account.")
        }
        let scope = ResetAttemptStore.scope(provider: account.provider, accountID: account.id, creditID: plan.creditID)
        let key: String
        do { key = try attempts.key(for: scope) } catch {
            return .notSent("Could not record the request, so nothing was sent.")
        }
        let outcome: ResetOutcome
        switch account.provider {
        case .codex: outcome = redeemCodex(plan, account, environment, key: key)
        case .claude: outcome = redeemClaude(plan, account, environment, key: key)
        case .cursor, .opencode: outcome = .notSent("\(account.provider.displayName) has no banked resets.")
        }
        if outcome.retiresKey { attempts.finish(scope) }
        return outcome
    }

    private func redeemCodex(_ plan: ResetPlan, _ account: Account, _ environment: [String: String], key: String) -> ResetOutcome {
        var params: [String: Any] = ["idempotencyKey": key]
        if let id = plan.creditID { params["creditId"] = id }
        let result: [String: Any]
        do { result = try codexCall(account, environment, Self.codexConsume, params) } catch HarnaisError.binaryNotFound(_) {
            return .notSent(HarnaisError.binaryNotFound("codex").localizedDescription)
        } catch {
            return .unconfirmed("Codex did not confirm the reset.")
        }
        switch result["outcome"] as? String {
        case "reset": return .reset(remaining: plan.availableCount > 0 ? plan.availableCount - 1 : nil)
        case "alreadyRedeemed": return .alreadyRedeemed
        case "nothingToReset": return .nothingToReset
        case "noCredit": return .noCredit
        default: return .unconfirmed("Codex answered with an unexpected result.")
        }
    }

    private func redeemClaude(_ plan: ResetPlan, _ account: Account, _ environment: [String: String], key: String) -> ResetOutcome {
        guard let grantID = plan.creditID else { return .notSent("Claude did not name a banked reset to use.") }
        guard let organization = organizationID(account) else {
            return .notSent("Could not find this account's Claude organization. Sign in again, then retry.")
        }
        guard let url = URL(string: "https://api.anthropic.com/api/organizations/\(organization)/reset_rate_limits"),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "program": Self.claudeProgram, "grant_id": grantID, "request_id": key,
              ])
        else { return .notSent("Could not build the reset request.") }
        var request: URLRequest
        do { request = try claudeRequest(account, environment, url, "POST") } catch {
            return .notSent(error.localizedDescription)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 25
        let data: Data, status: Int
        do { (data, status) = try http(request) } catch {
            return .unconfirmed("Claude did not confirm the reset.")
        }
        switch status {
        case 200: break
        case 401, 403: return .notSent("Claude rejected this account's sign-in. Sign in again, then retry.")
        case 429: return .unconfirmed("Claude is rate limiting requests.")
        default: return .unconfirmed("Claude answered \(status).")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unconfirmed("Claude answered with an unreadable result.")
        }
        switch json["result"] as? String {
        case "reset": return .reset(remaining: (json["resets_left"] as? Int).map { max(0, $0) })
        case "already_used": return .alreadyRedeemed
        case "not_limited": return .nothingToReset
        case "cooldown": return .cooldown
        case "ineligible": return .ineligible
        default: return .unavailable
        }
    }

    // MARK: Live transports

    public static let liveHTTP: HTTP = { request in
        if request.httpMethod == "GET" {
            return try ClaudeUsageClient.shared.send(request, maximumAge: ClaudeUsageClient.resetMaxAge)
        }
        return try ClaudeUsageClient.shared.withInvalidatedUsage(request) {
            try HTTPClient.sendBlocking(request, timeout: 25)
        }
    }

    public static let liveClaudeRequest: ClaudeRequest = { account, environment, url, method in
        try ClaudeQuotaProbe().authorizedRequest(url: url, method: method, account: account, environment: environment)
    }

    /// One short-lived `codex app-server` session per call. Plan uses it read-only.
    public static let liveCodexCall: CodexCall = { account, environment, method, params in
        guard let binary = BinaryLocator.resolve(.codex, override: account.binaryPath) else {
            throw HarnaisError.binaryNotFound("codex")
        }
        let session = try ProcessRunner().openSession(
            executable: binary, arguments: ["-s", "read-only", "-a", "never", "app-server"], environment: environment
        )
        defer { session.terminate() }
        try session.sendJSON([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "harnais", "version": "0.1.0"], "capabilities": ["experimentalApi": true]],
        ])
        try session.sendJSON(["jsonrpc": "2.0", "method": "initialized"])
        var request: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": method]
        if let params { request["params"] = params }
        try session.sendJSON(request)
        return try session.waitForResult(
            id: 2, timeout: 20,
            failureMessage: "Codex could not complete the request.",
            earlyExitMessage: "Codex stopped before answering."
        )
    }
}
