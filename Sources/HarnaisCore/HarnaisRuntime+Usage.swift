import AppKit
import Domain
import Foundation
import Infrastructure

extension HarnaisRuntime {
    public func refreshQuotas() {
        guard !isRefreshingQuotas, startingCodexWeeks.isEmpty else { return }
        isRefreshingQuotas = true
        errorMessage = nil
        let accounts = self.accounts
        let automatic = settings.autoStartCodexWeeks == true
        Task {
            let feed = await Task.detached {
                QuotaAggregator().refresh(accounts: accounts, startUnusedCodexWeeks: automatic)
            }.value
            self.isRefreshingQuotas = false
            guard self.accounts == accounts else {
                refreshQuotas()
                return
            }
            self.feed = feed
            self.codexWeekStates = CodexWeekStarter().states()
        }
    }

    public func setAutoStartCodexWeeks(_ enabled: Bool) {
        var updated = settings
        updated.autoStartCodexWeeks = enabled
        do {
            try settingsStore.save(updated)
            settings = updated
            if enabled { refreshQuotas() }
        } catch { errorMessage = error.localizedDescription }
    }

    public func codexWeekMessage(for account: Account) -> String? {
        codexWeekStates[CodexWeekStarter.key(for: account)]?.message
    }

    public func startCodexWeek(_ account: Account) {
        guard account.provider == .codex, startingCodexWeeks.isEmpty, !isRefreshingQuotas else { return }
        startingCodexWeeks.insert(account.id)
        errorMessage = nil
        Task {
            do {
                let sent = try await Task.detached {
                    let starter = CodexWeekStarter()
                    let probe = try CodexQuotaProbe().probe(account: account, environment: IsolationEngine().spawnEnvironment(for: account))
                    _ = try starter.observe(account: account, result: probe)
                    guard probe.error == nil else { throw HarnaisError.processFailed(probe.error!) }
                    return try starter.start(account: account, manual: true)
                }.value
                if sent { presentSuccess("Request sent. Refreshing the weekly window.") }
                else { presentSuccess("No request sent. The week is active or was just checked; refresh limits before retrying.") }
            } catch { errorMessage = error.localizedDescription }
            startingCodexWeeks.remove(account.id)
            let message = errorMessage
            refreshQuotas()
            if let message { errorMessage = message }
        }
    }

    /// Overview needs both live quotas and the local spend scan.
    public func refreshOverview() {
        refreshQuotas()
        refreshUsage()
    }

    public func refreshUsage() {
        guard !isRefreshingUsage else { return }
        isRefreshingUsage = true
        let accounts = self.accounts
        let cacheURL = identity.usageCacheFileURL
        let needsCached = usage.capturedAt == nil
        Task {
            if needsCached {
                let cached = await Task.detached(priority: .userInitiated) {
                    autoreleasepool {
                        SessionUsageScanner().load(cacheURL: cacheURL).map { UsagePresentation(summary: $0) }
                    }
                }.value
                if let cached, self.accounts == accounts { usage = cached }
            }
            let presentation = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    let summary = SessionUsageScanner().scan(accounts: accounts, cacheURL: cacheURL)
                    return UsagePresentation(summary: summary)
                }
            }.value
            isRefreshingUsage = false
            guard self.accounts == accounts else {
                refreshUsage()
                return
            }
            usage = presentation
        }
    }
}
