import Domain
import SwiftUI

struct CodexWeeksSheet: View {
    @Bindable var runtime: HarnaisRuntime
    @Environment(\.dismiss) private var dismiss

    private var accounts: [Account] { runtime.ownedAccounts(provider: .codex) }

    var body: some View {
        VStack(alignment: .leading, spacing: HarnaisSheetMetrics.spacing) {
            HStack(spacing: 8) {
                ProviderMark(provider: .codex, size: 20)
                Text("Codex weeks")
                    .font(HarnaisSheetMetrics.titleFont)
                    .foregroundStyle(HarnaisPalette.text)
                Spacer()
                HarnaisIconButton(systemName: "arrow.clockwise", accessibilityLabel: "Refresh Codex weeks",
                                  spinning: runtime.isRefreshingQuotas, action: { runtime.refreshQuotas() })
                    .disabled(!runtime.startingCodexWeeks.isEmpty)
            }
            Text("Start an unused week with one small request. It uses a little allowance and keeps your banked resets.")
                .font(HarnaisSheetMetrics.subtitleFont)
                .foregroundStyle(HarnaisPalette.label)
                .fixedSize(horizontal: false, vertical: true)

            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                            if index > 0 { SettingsDivider() }
                            accountRow(account, now: context.date)
                        }
                    }
                }
                .frame(height: min(CGFloat(accounts.count) * 78, 312))
                .background(HarnaisPalette.cardFill, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(HarnaisPalette.hairline, lineWidth: 1) }
            }

            VStack(alignment: .leading, spacing: 5) {
                Toggle("Start new weeks automatically", isOn: Binding(
                    get: { runtime.settings.autoStartCodexWeeks == true },
                    set: { runtime.setAutoStartCodexWeeks($0) }
                ))
                .toggleStyle(.switch)
                .tint(HarnaisPalette.accent)
                .foregroundStyle(HarnaisPalette.text)
                Text("Checks once a minute while Harnais is open. Sends one request when a new unused week is confirmed.")
                    .font(HarnaisSheetMetrics.subtitleFont)
                    .foregroundStyle(HarnaisPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = runtime.errorMessage {
                Text(error)
                    .font(HarnaisSheetMetrics.subtitleFont)
                    .foregroundStyle(HarnaisPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                HarnaisButton(title: "Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(HarnaisSheetMetrics.padding)
        .frame(width: 540)
        .background(HarnaisPalette.background)
        .harnaisChrome(title: "Codex weeks", kind: .sheet)
        .toolbar(removing: .title)
        .onExitCommand { dismiss() }
    }

    private func accountRow(_ account: Account, now: Date) -> some View {
        let weekly = runtime.quotas(for: account).first { $0.windowKind == .weekly }
        let starting = runtime.startingCodexWeeks.contains(account.id)
        let pending = weekly?.awaitingFirstUse == true
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayLabel())
                    .font(HarnaisType.rowTitle)
                    .foregroundStyle(HarnaisPalette.text)
                    .lineLimit(1)
                if let email = runtime.connection(for: account).email ?? account.accountEmail {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundStyle(HarnaisPalette.tertiary)
                        .lineLimit(1)
                }
                Text(starting ? "Starting…" : status(for: weekly, account: account, now: now))
                    .font(HarnaisSheetMetrics.subtitleFont)
                    .foregroundStyle(HarnaisPalette.label)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if pending || starting {
                HarnaisButton(title: starting ? "Starting…" : "Start week") { runtime.startCodexWeek(account) }
                    .disabled(runtime.isRefreshingQuotas || !runtime.startingCodexWeeks.isEmpty)
                    .accessibilityLabel("Start week for \(account.displayLabel())")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 77)
    }

    private func status(for quota: FeedQuota?, account: Account, now: Date) -> String {
        guard let quota else { return "Limits unavailable · refresh to check" }
        if quota.awaitingFirstUse == true {
            if let message = runtime.codexWeekMessage(for: account), message.hasPrefix("Could not") {
                return "Not started · last attempt failed"
            }
            return "Not started"
        }
        if let reset = quota.resetCaption(now: now) { return reset.prefix(1).uppercased() + reset.dropFirst() }
        return "Reset time unavailable"
    }
}
