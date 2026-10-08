import Domain
import Infrastructure
import SwiftUI

struct HealthPageView: View {
    @Bindable var runtime: HarnaisRuntime
    var onOpenAccount: (Account) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        HarnaisCanvas(title: "Account health", errorMessage: runtime.errorMessage, successMessage: runtime.successMessage) {
            SettingsSection(title: "Diagnosis") {
                SettingsRow(title: "Account checks", description: "Review sign-in, command routing, T3 and usage together. Checks older than 15 minutes are marked unverified.") {
                    HStack {
                        HarnaisButton(title: "Copy report", prominence: .ghostMuted) { runtime.copyHealthReport() }
                        HarnaisButton(title: "Check accounts") { runtime.refreshHealth() }
                            .disabled(runtime.isCheckingConnection || runtime.isRefreshingQuotas)
                    }
                }
            }
            ForEach(runtime.accounts) { account in
                let health = runtime.health(for: account, now: now)
                SettingsSection(title: "\(account.provider.displayName) · \(account.displayLabel())") {
                    SettingsRow(title: health.state.title, description: "Open the account for sign-in and provider settings.") {
                        HarnaisButton(title: "Open account") { onOpenAccount(account) }
                    }
                    ForEach(health.checks) { check in
                        SettingsDivider()
                        SettingsRow(title: check.title,
                                    description: [check.detail, check.nextStep].compactMap { $0 }.joined(separator: " "),
                                    status: check.checkedAt.map { ConnectionReport.lastCheckedLabel(from: $0) }) {
                            HStack(spacing: 8) {
                                HealthStateLabel(state: check.state)
                                if check.id == "command" && check.state == .attention {
                                    HarnaisButton(title: "Repair command", prominence: .ghostMuted) { runtime.repairAccountCommand(account) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct HealthStateLabel: View {
    let state: HealthState
    var body: some View {
        Label(state.title, systemImage: state == .ready ? "checkmark.circle" : state == .attention ? "exclamationmark.triangle" : "questionmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(state == .attention ? HarnaisPalette.warning : state == .ready ? HarnaisPalette.accent : HarnaisPalette.label)
    }
}
