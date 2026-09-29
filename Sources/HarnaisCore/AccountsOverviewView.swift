import Domain
import SwiftUI

/// Account status, recent activity and direct actions. Full quota details live in each account.
struct AccountsOverviewView: View {
    @Bindable var runtime: HarnaisRuntime
    var onAdd: (ProviderKind?) -> Void
    var onLogin: (Account) -> Void
    var onTerminal: (Account) -> Void
    var onOpenAccount: (Account) -> Void
    var onOpenUsage: () -> Void

    var body: some View {
        HarnaisCanvas(
            title: "Overview",
            subtitle: subtitle,
            errorMessage: runtime.errorMessage,
            successMessage: runtime.successMessage,
            toolbar: { toolbar },
            content: {
                if runtime.accounts.isEmpty {
                    emptyState
                } else {
                    summary
                    if !attention.isEmpty {
                        attentionBanner
                    }
                    ForEach(runtime.accounts.groupedByProvider()) { group in
                        providerSection(group)
                    }
                }
            }
        )
    }

    // MARK: - Attention

    private struct AttentionItem: Identifiable {
        var account: Account
        var worst: Double
        var id: UUID { account.id }
    }

    private var attention: [AttentionItem] {
        runtime.accounts.compactMap { account in
            let quotas = runtime.quotas(for: account)
            guard !quotas.isEmpty else { return nil }
            let worst = quotas.map(\.percentRemaining).min() ?? 100
            guard QuotaSeverity.of(percentRemaining: worst) == .depleted
                || QuotaSeverity.of(percentRemaining: worst) == .critical
                || QuotaSeverity.of(percentRemaining: worst) == .warning
            else { return nil }
            return AttentionItem(account: account, worst: worst)
        }
        .sorted { $0.worst < $1.worst }
    }

    private var attentionBanner: some View {
        guard let lowest = attention.first else { return AnyView(EmptyView()) }
        return AnyView(HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HarnaisPalette.warning)
            Text(attention.count == 1
                ? "\(lowest.account.displayLabel()) has \(Int(lowest.worst.rounded()))% left."
                : "\(attention.count) accounts low — lowest is \(lowest.account.displayLabel()) at \(Int(lowest.worst.rounded()))% left.")
                .font(.system(size: 13))
                .foregroundStyle(HarnaisPalette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HarnaisButton(title: "View limits", prominence: .ghostMuted, action: onOpenUsage)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HarnaisPalette.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(HarnaisPalette.hairline, lineWidth: 1)
        }
        .accessibilityLabel("\(attention.count) accounts need attention"))
    }

    // MARK: - Providers

    private func providerSection(_ group: AccountProviderGroup) -> some View {
        SettingsSection(
            title: group.provider.displayName,
            icon: AnyView(ProviderMark(provider: group.provider, size: HarnaisIconSize.sectionMark))
        ) {
            ForEach(Array(group.accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { SettingsDivider() }
                compactAccountRow(account)
            }
        }
    }

    private func compactAccountRow(_ account: Account) -> some View {
        OverviewAccountRow(
            account: account,
            report: runtime.connection(for: account),
            quota: runtime.quotas(for: account).min { $0.percentRemaining < $1.percentRemaining },
            onLogin: { onLogin(account) },
            onTerminal: { onTerminal(account) },
            onOpen: { onOpenAccount(account) }
        )
    }

    private var summary: some View {
        let totals = runtime.usage.report(for: .days7).totals
        return HStack(spacing: 12) {
            summaryTile(title: "Accounts", value: "\(runtime.accounts.count)", detail: "Across \(runtime.accounts.groupedByProvider().count) providers")
            summaryTile(title: "Sessions · 7 days", value: "\(totals.sessions)", detail: "From local activity")
            summaryTile(title: "Estimated cost · 7 days", value: UsageFormat.usd(totals.cost), detail: "Usage value, not your bill")
        }
    }

    private func summaryTile(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(HarnaisPalette.label)
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(HarnaisPalette.text)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(detail).font(.system(size: 10)).foregroundStyle(HarnaisPalette.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(HarnaisPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(HarnaisPalette.border, lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Chrome

    private var subtitle: String? {
        runtime.accounts.isEmpty ? nil : "Accounts and usage at a glance."
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if let updated = ConnectionReport.updatedAgoLabel(from: runtime.lastQuotaCapturedAt) {
                Text(updated)
                    .font(.system(size: 12))
                    .foregroundStyle(HarnaisPalette.label)
            }
            HarnaisButton(title: "Add account", size: .sm) { onAdd(nil) }
            HarnaisIconButton(
                systemName: "arrow.clockwise",
                accessibilityLabel: "Refresh overview",
                spinning: runtime.isRefreshingQuotas || runtime.isRefreshingUsage,
                action: { runtime.refreshOverview() }
            )
            .disabled(runtime.isRefreshingQuotas || runtime.isRefreshingUsage)
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private var emptyState: some View {
        AccountsEmptyState(
            onImport: { runtime.importDefaults() },
            onAdd: { onAdd(nil) }
        )
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

/// Shared by Overview and the account detail: import or create the first login.
struct AccountsEmptyState: View {
    var onImport: () -> Void
    var onAdd: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Import the logins already on this Mac, or add a Work / Personal profile.")
                .font(HarnaisType.status)
                .foregroundStyle(HarnaisPalette.label)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.bottom, 8)
            HStack(spacing: 8) {
                HarnaisButton(title: "Import existing logins", action: onImport)
                HarnaisButton(title: "Add account", prominence: .primary, action: onAdd)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}
