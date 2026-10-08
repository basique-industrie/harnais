import AppKit
import Domain
import Infrastructure
import SwiftUI

extension UsagePageView {
    /// ChatGPT accounts T3 signs in to itself. Harnais has no profile for them, so it shows what T3
    /// last reported and links to ChatGPT's usage page.
    func t3ManagedLimits(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Managed by T3 Code")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HarnaisPalette.label)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            ForEach(Array(runtime.t3ManagedAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { SettingsDivider() }
                SettingsRow(
                    title: account.displayName,
                    description: t3ManagedDescription(account, now: now),
                    status: t3ManagedIdentity(account)
                ) {
                    HarnaisButton(title: "ChatGPT usage", prominence: .ghostMuted) {
                        NSWorkspace.shared.open(account.status?.externalUsageURL ?? T3ManagedAccount.usagePage)
                    }
                }
            }
        }
        .background(HarnaisPalette.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(HarnaisPalette.hairline, lineWidth: 1)
        }
    }

    func t3ManagedIdentity(_ account: T3ManagedAccount) -> String? {
        let parts = [account.status?.email, account.status?.planLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func t3ManagedDescription(_ account: T3ManagedAccount, now: Date) -> String {
        if !account.enabled { return "Turned off in T3." }
        guard let status = account.status else { return "T3 hasn't reported this account yet." }
        if status.auth == .unauthenticated { return "Not signed in. Sign in to it in T3 Settings → Providers." }
        guard !status.usageWindows.isEmpty else { return "T3 doesn't report limits for this account." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return status.usageWindows.map { window in
            let used = "\(window.label) \(Int(min(max(window.usedPercent, 0), 100).rounded()))% used"
            guard let resetsAt = window.resetsAt, resetsAt > now else { return used }
            return "\(used), resets \(formatter.localizedString(for: resetsAt, relativeTo: now))"
        }
        .joined(separator: " · ")
    }
}
