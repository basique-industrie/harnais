import Domain
import SwiftUI

struct OverviewAccountRow: View {
    let account: Account
    let report: ConnectionReport
    let quota: FeedQuota?
    let onLogin: () -> Void
    let onTerminal: () -> Void
    let onOpen: () -> Void

    private var name: String { account.displayLabel(email: report.email) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                identity
                availability.frame(width: 164)
                actions
            }
            VStack(alignment: .leading, spacing: 12) {
                identity
                HStack(spacing: 20) {
                    availability
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    AccountColorMark(account: account)
                    Text(name)
                        .font(HarnaisType.rowTitle)
                        .foregroundStyle(HarnaisPalette.text)
                }
                if AccountNaming.shouldShowMailbox(visibleName: name, email: report.email), let email = report.email {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundStyle(HarnaisPalette.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let plan = report.authLabel {
                    Text(SubscriptionLabel.sidebarPlan(plan))
                        .font(.system(size: 11))
                        .foregroundStyle(HarnaisPalette.label)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(account.provider.displayName) \(name) details")
    }

    @ViewBuilder
    private var availability: some View {
        if !report.authenticated {
            Text(report.headline)
                .font(.system(size: 12))
                .foregroundStyle(HarnaisPalette.label)
        } else if let quota {
            let remaining = min(max(quota.percentRemaining, 0), 100)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(UsageFormat.windowTitle(quota))
                        .foregroundStyle(HarnaisPalette.label)
                    Spacer(minLength: 0)
                    Text("\(Int(remaining.rounded()))% left")
                        .fontWeight(.semibold)
                        .foregroundStyle(remaining <= 10 ? HarnaisPalette.warning : HarnaisPalette.text)
                }
                .font(.system(size: 11).monospacedDigit())
                GeometryReader { geometry in
                    Capsule().fill(HarnaisPalette.track)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(HarnaisPalette.quotaFill(for: account.provider, remaining: remaining))
                                .frame(width: geometry.size.width * remaining / 100)
                        }
                }
                .frame(height: 5)
            }
            .help("Lowest remaining allowance for this account. Open details to see every usage window.")
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("Signed in").foregroundStyle(HarnaisPalette.text)
                Text("Usage unavailable").foregroundStyle(HarnaisPalette.label)
            }
            .font(.system(size: 11))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if report.installed {
                if report.authenticated {
                    HarnaisButton(title: "Terminal", prominence: .ghostMuted, size: .xs, action: onTerminal)
                        .accessibilityLabel("Open \(account.provider.displayName) \(name) in Terminal")
                } else {
                    HarnaisButton(title: "Sign in", prominence: .primary, size: .sm, action: onLogin)
                        .disabled(report.kind == .checking)
                }
            }
            HarnaisIconButton(
                systemName: "chevron.right",
                accessibilityLabel: "View details for \(account.provider.displayName) \(name)",
                action: onOpen
            )
            .help("Account details")
        }
        .fixedSize()
    }
}
