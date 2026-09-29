import Domain
import Foundation

public struct QuotaAggregator: Sendable {
    public var identity: AppIdentity
    public var isolation: IsolationEngine

    public init(identity: AppIdentity = .current, isolation: IsolationEngine = IsolationEngine()) {
        self.identity = identity
        self.isolation = isolation
    }

    public func refresh(accounts: [Account], startUnusedCodexWeeks: Bool = false) -> QuotaFeed {
        var snapshots: [AccountQuotaSnapshot] = []
        let starter = CodexWeekStarter(identity: identity)
        let previous = load()
        let states = starter.states()
        for account in accounts {
            let env = isolation.spawnEnvironment(for: account)
            var result: ProbeResult
            do {
                switch account.provider {
                case .claude:
                    result = try ClaudeQuotaProbe().probe(account: account, environment: env)
                case .codex:
                    result = try CodexQuotaProbe().probe(account: account, environment: env)
                case .opencode:
                    result = ProbeResult(error: "OpenCode limits are not available in Harnais.")
                case .cursor:
                    result = try CursorQuotaProbe().probe(account: account, environment: env)
                }
            } catch {
                result = ProbeResult(error: error.localizedDescription)
            }
            var pending = false
            if account.provider == .codex {
                if states[CodexWeekStarter.key(for: account)]?.observedAt == nil,
                   let prior = previous.accounts.first(where: { $0.id == account.id.uuidString }), prior.error == nil {
                    _ = try? starter.observe(account: account, result: ProbeResult(quotas: prior.quotas.map {
                        ProbeQuota(window: $0.compactTitle ?? "", percentRemaining: $0.percentRemaining, resetsAt: $0.resetsAt)
                    }), now: previous.capturedAt)
                }
                pending = (try? starter.observe(account: account, result: result))?.awaitingFirstUse == true
                if startUnusedCodexWeeks, pending,
                   (try? SettingsStore(identity: identity).load().autoStartCodexWeeks) == true,
                   (try? starter.start(account: account)) == true {
                    if let refreshed = try? CodexQuotaProbe().probe(account: account, environment: env) {
                        result = refreshed
                        pending = (try? starter.observe(account: account, result: result))?.awaitingFirstUse == true
                    }
                }
            }
            let group = Self.quotaGroupTitle(
                provider: account.provider,
                visibleName: account.displayLabel(email: result.email)
            )
            let quotas = result.quotas.map { quota in
                FeedQuota(
                    type: Self.quotaTypeKey(
                        provider: account.provider,
                        slug: account.slug,
                        window: quota.window
                    ),
                    percentRemaining: quota.percentRemaining,
                    resetsAt: quota.resetsAt,
                    resetText: quota.resetText ?? QuotaReset.caption(resetsAt: quota.resetsAt),
                    group: group,
                    compactTitle: quota.window,
                    menuBarTitle: "\(account.provider.displayName) \(quota.window)",
                    awaitingFirstUse: pending && quota.window == "7d" ? true : nil
                )
            }
            snapshots.append(
                AccountQuotaSnapshot(
                    id: account.id.uuidString,
                    provider: account.provider.rawValue,
                    label: account.label,
                    email: result.email ?? JWTPayload.mailbox(account.accountEmail),
                    quotas: quotas,
                    error: result.error,
                    resetCredits: result.resetCredits
                )
            )
        }
        let feed = QuotaFeed(capturedAt: Date(), accounts: snapshots)
        try? AtomicJSONFile(fileURL: identity.quotasFileURL).write(feed)
        return feed
    }

    /// Stable Iles metric key. Uses `slug` so renaming an account does not
    /// orphan island rings that already bind this window.
    public static func quotaTypeKey(provider: ProviderKind, slug: String, window: String) -> String {
        "time:\(provider.displayName) · \(slug) \(window)"
    }

    public static func quotaGroupTitle(provider: ProviderKind, visibleName: String) -> String {
        "\(provider.displayName) · \(visibleName)"
    }

    public func load() -> QuotaFeed {
        guard FileManager.default.fileExists(atPath: identity.quotasFileURL.path),
              let feed = try? AtomicJSONFile(fileURL: identity.quotasFileURL).read(QuotaFeed.self)
        else {
            return QuotaFeed()
        }
        return feed
    }
}
