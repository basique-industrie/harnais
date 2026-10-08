import Domain
import SwiftUI

extension UsagePageView {
    @ViewBuilder
    var limits: some View {
        if runtime.accounts.isEmpty && runtime.t3ManagedAccounts.isEmpty {
            Text("Add an account to see limits.")
                .font(HarnaisType.status)
                .foregroundStyle(HarnaisPalette.label)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(limitPools, id: \.provider) { pool in
                        providerLimits(pool, now: context.date)
                    }
                }
            }
        }
    }

    func providerLimits(_ pool: ProviderLimitPool, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderMark(provider: pool.provider, size: 16)
                Text(pool.provider.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(HarnaisPalette.text)
                Spacer(minLength: 8)
                if pool.accountCount > 1 {
                    Text("\(pool.accountCount) accounts")
                        .font(.system(size: 12))
                        .foregroundStyle(HarnaisPalette.label)
                }
                if pool.provider == .codex && pool.accountCount > 0 {
                    HarnaisButton(title: "Manage weeks", prominence: .ghostMuted) { managingCodexWeeks = true }
                        .accessibilityLabel("Manage Codex weeks")
                }
            }
            if pool.provider == .cursor {
                Text("Models and Other are Cursor plan buckets, not 5-hour windows.")
                    .font(.system(size: 12))
                    .foregroundStyle(HarnaisPalette.label)
            }
            ForEach(pool.windows) { window in
                LimitPoolCard(
                    provider: pool.provider,
                    title: window.title,
                    members: window.members,
                    now: now
                )
            }
            if !pool.skipped.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(pool.skipped.enumerated()), id: \.element.account.id) { index, item in
                        if index > 0 { SettingsDivider() }
                        emptyAccountLimits(item)
                    }
                }
                .background(HarnaisPalette.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(HarnaisPalette.hairline, lineWidth: 1)
                }
            }
            if pool.provider == .codex && !runtime.t3ManagedAccounts.isEmpty {
                t3ManagedLimits(now: now)
            }
        }
    }

    func emptyAccountLimits(_ item: AccountUsageItem) -> some View {
        SettingsRow(
            title: item.account.displayLabel(email: runtime.connection(for: item.account).email),
            description: emptyCopy(item)
        ) {
            HStack(spacing: 6) {
                if !runtime.connection(for: item.account).authenticated {
                    HarnaisButton(title: "Sign in", prominence: .ghostMuted) { onLogin(item.account) }
                }
                HarnaisButton(title: "Check", prominence: .ghostMuted) {
                    runtime.checkConnection(item.account)
                }
            }
        }
    }

    func emptyCopy(_ item: AccountUsageItem) -> String {
        if let error = item.error { return error }
        if item.quotas.isEmpty { return "No limits reported." }
        switch windowFilter {
        case .weekly: return "No plan window."
        case .session: return "No session window."
        case .all: return "No limits reported."
        }
    }

    var allUsageItems: [AccountUsageItem] {
        runtime.accounts.map { account in
            AccountUsageItem(
                account: account,
                quotas: runtime.quotas(for: account),
                error: runtime.quotaError(for: account)
            )
        }
    }

    var limitPools: [ProviderLimitPool] {
        ProviderKind.allCases.compactMap { provider in
            let items = allUsageItems.filter { $0.account.provider == provider }
            let hasT3Accounts = provider == .codex && !runtime.t3ManagedAccounts.isEmpty
            guard !items.isEmpty || hasT3Accounts else { return nil }
            var buckets: [String: [LimitPoolMember]] = [:]
            var skipped: [AccountUsageItem] = []
            for item in items {
                let matching = item.quotas.filter { windowFilter.includes($0) }
                if matching.isEmpty {
                    skipped.append(item)
                    continue
                }
                for quota in matching {
                    let title = UsageFormat.windowTitle(quota)
                    buckets[title, default: []].append(
                        LimitPoolMember(
                            account: item.account,
                            quota: quota,
                            email: runtime.connection(for: item.account).email ?? item.account.accountEmail,
                            resetCredits: runtime.resetCredits(for: item.account)
                        )
                    )
                }
            }
            let windows = buckets.keys.sorted { lhs, rhs in
                let left = windowSortKey(lhs)
                let right = windowSortKey(rhs)
                if left != right { return left < right }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            .map { title in
                let members = (buckets[title] ?? []).sorted { lhs, rhs in
                    let leftReset = lhs.quota.resetsAt ?? .distantFuture
                    let rightReset = rhs.quota.resetsAt ?? .distantFuture
                    if leftReset != rightReset { return leftReset < rightReset }
                    return lhs.account.label.localizedCaseInsensitiveCompare(rhs.account.label) == .orderedAscending
                }
                return PooledLimitWindow(title: title, members: members)
            }
            return ProviderLimitPool(
                provider: provider,
                windows: windows,
                skipped: skipped,
                accountCount: items.count
            )
        }
    }

    func windowSortKey(_ title: String) -> Int {
        switch title.lowercased() {
        case "session": 0
        case "weekly": 1
        default: 2
        }
    }
}
