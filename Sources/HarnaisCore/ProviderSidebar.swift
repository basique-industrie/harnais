import Domain
import SwiftUI

struct ProviderSidebar: View {
    @Bindable var runtime: HarnaisRuntime
    @Binding var page: HarnaisPage
    var onAdd: (ProviderKind?) -> Void
    var onLogin: (Account) -> Void
    var onTerminal: (Account) -> Void
    var onExport: (Account) -> Void
    var onRemove: (Account) -> Void
    @Environment(\.titlebarLeading) private var titlebarLeading
    @Environment(\.titlebarHeight) private var titlebarHeight

    var body: some View {
        VStack(spacing: 0) {
            header
            primaryNavigation
            accountsHeader
            BoundedScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(runtime.accounts.groupedByProvider().enumerated()), id: \.element.id) { index, group in
                        providerGroup(group)
                            .padding(.top, index == 0 ? 0 : 8)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 2)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: .infinity)
            sidebarFooter
        }
        .frame(width: 260)
        .background(HarnaisPalette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(HarnaisPalette.sidebarBorder)
                .frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VectorTemplateMark(
                resource: ("HarnaisIcon", "svg"),
                tint: .labelColor,
                isTemplate: true
            )
            .frame(width: HarnaisIconSize.appMark, height: HarnaisIconSize.appMark)
            .allowsHitTesting(false)
            Text("Harnais")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HarnaisPalette.text)
                .lineLimit(1)
                .allowsHitTesting(false)
            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
        .padding(.leading, titlebarLeading)
        .frame(height: titlebarHeight)
    }

    private func providerGroup(_ group: AccountProviderGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ProviderMark(provider: group.provider, size: HarnaisIconSize.sidebarMark)
                Text(group.provider.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HarnaisPalette.label)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
            ForEach(group.accounts) { account in
                ProviderInstanceRow(
                    account: account,
                    report: runtime.connection(for: account),
                    selected: page == .account && runtime.selectedAccountID == account.id,
                    onSelect: {
                        runtime.select(account)
                        page = .account
                    },
                    onLogin: { onLogin(account) },
                    onTerminal: { onTerminal(account) },
                    onExport: { onExport(account) },
                    onRemove: { onRemove(account) }
                )
                .padding(.leading, 12)
            }
        }
    }

    private var primaryNavigation: some View {
        VStack(spacing: 1) {
            SidebarNavRow(
                glyph: .layoutDashboard,
                title: "Overview",
                selected: page == .overview,
                shortcutHint: "⌘0",
                action: {
                    page = .overview
                    runtime.refreshOverview()
                }
            )
            SidebarNavRow(
                glyph: .chartNoAxesColumn,
                title: "Usage",
                selected: page == .usage,
                shortcutHint: "⌘1",
                action: {
                    page = .usage
                    runtime.refreshQuotas()
                }
            )
            SidebarNavRow(
                glyph: .unplug,
                title: "Connections",
                selected: page == .connections,
                shortcutHint: "⌘3",
                action: { page = .connections }
            )
            SidebarNavRow(
                glyph: .bookOpen,
                title: "Skills",
                selected: page == .skills,
                shortcutHint: "⌘4",
                action: { page = .skills }
            )
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 10)
    }

    private var accountsHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Rectangle()
                .fill(HarnaisPalette.sidebarBorder)
                .frame(height: 1)
                .padding(.bottom, 10)
            Text("Accounts")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HarnaisPalette.label)
                .padding(.horizontal, 8)
                .accessibilityAddTraits(.isHeader)
            SidebarAddAccountRow(onAdd: onAdd)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 1) {
            Rectangle()
                .fill(HarnaisPalette.sidebarBorder)
                .frame(height: 1)
            SidebarNavRow(
                glyph: .package,
                title: "Binaries",
                selected: page == .binaries,
                badge: runtime.hasBinaryUpdates ? "Update" : nil,
                shortcutHint: "⌘2",
                action: { page = .binaries }
            )
            SidebarNavRow(
                glyph: .settings,
                title: "Settings",
                selected: page == .settings,
                shortcutHint: "⌘,",
                action: { page = .settings }
            )
            SidebarNavRow(
                glyph: .info,
                title: "About",
                selected: page == .about,
                action: { page = .about }
            )
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .padding(.top, 2)
    }
}

private struct ProviderInstanceRow: View {
    let account: Account
    let report: ConnectionReport
    let selected: Bool
    let onSelect: () -> Void
    var onLogin: () -> Void = {}
    var onTerminal: () -> Void = {}
    var onExport: () -> Void = {}
    var onRemove: () -> Void = {}
    @State private var isHovering = false

    private static let planColumnWidth: CGFloat = 56

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if report.showsStatusDot {
                            Circle()
                                .fill(HarnaisPalette.statusDot(report.kind))
                                .frame(width: 8, height: 8)
                        }
                        Text(visibleName)
                            .font(.system(size: 13, weight: selected ? .semibold : .medium))
                            .tracking(-0.07)
                            .foregroundStyle(HarnaisPalette.text)
                            .lineLimit(1)
                    }
                    if let detailLine {
                        Text(detailLine)
                            .font(.system(size: 11))
                            .foregroundStyle(HarnaisPalette.label)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(planLabel ?? "")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(HarnaisPalette.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Self.planColumnWidth, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(rowHelp)
        .contextMenu {
            Button("Open in Terminal", action: onTerminal)
                .disabled(!report.installed)
            if report.installed, !report.authenticated, report.kind != .checking {
                Button("Sign in", action: onLogin)
            }
            Button("T3 configuration…", action: onExport)
            Divider()
            Button("Remove account…", role: .destructive, action: onRemove)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(accessibilityLabel)
    }

    private var visibleName: String {
        account.displayLabel(email: email)
    }

    private var email: String? {
        report.email ?? (account.provider == .opencode ? nil : JWTPayload.mailbox(account.accountEmail))
    }

    private var planLabel: String? {
        guard report.authenticated, let authLabel = report.authLabel, !authLabel.isEmpty else {
            return nil
        }
        return SubscriptionLabel.sidebarPlan(authLabel)
    }

    private var detailLine: String? {
        if AccountNaming.shouldShowMailbox(visibleName: visibleName, email: email) {
            return email
        }
        if !report.authenticated { return report.headline }
        if !report.connectedAccounts.isEmpty {
            return report.connectedAccounts.map(\.providerName).joined(separator: ", ")
        }
        return nil
    }

    private var rowHelp: String {
        [account.label, planLabel, email, report.connectedAccounts.map(\.providerName).joined(separator: ", "), report.authenticated ? nil : report.headline]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        [account.provider.displayName, account.label, planLabel, email, report.connectedAccounts.map(\.providerName).joined(separator: ", "), report.authenticated ? nil : report.headline]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var rowBackground: Color {
        if selected { return HarnaisPalette.rowSelected }
        if isHovering { return HarnaisPalette.rowHover }
        return .clear
    }
}

struct SidebarNavRow: View {
    let glyph: LucideGlyph
    let title: String
    let selected: Bool
    var badge: String? = nil
    var shortcutHint: String? = nil
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                LucideIcon(glyph: glyph, size: 15, tint: iconTint)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(HarnaisPalette.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    HarnaisCapsuleBadge(text: badge)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(shortcutHint.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fill: Color {
        if selected { return HarnaisPalette.rowSelected }
        if isHovering { return HarnaisPalette.rowHover }
        return .clear
    }

    private var iconTint: NSColor {
        selected || isHovering ? .labelColor : .secondaryLabelColor
    }
}

private struct SidebarAddAccountRow: View {
    var onAdd: (ProviderKind?) -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            onAdd(nil)
        } label: {
            HStack(spacing: 8) {
                LucideIcon(glyph: .plus, size: 15, tint: iconTint)
                Text("Add account")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHovering ? HarnaisPalette.text : HarnaisPalette.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                isHovering ? HarnaisPalette.rowHover : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .keyboardShortcut("n", modifiers: .command)
        .help("Add account (⌘N)")
        .accessibilityLabel("Add account")
    }

    private var iconTint: NSColor {
        isHovering ? .labelColor : .secondaryLabelColor
    }
}
