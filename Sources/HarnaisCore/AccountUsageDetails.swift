import Domain
import SwiftUI

/// Account detail meters keep the value, reset time and banked resets distinct.
struct AccountUsageDetails: View {
    let provider: ProviderKind
    let quotas: [FeedQuota]
    var resetCredits: ResetCredits?
    var onUseReset: (() -> Void)?
    var isUsingReset = false
    /// Set while the weekly quota is not empty: the reset is shown but cannot be used.
    var resetBlocker: String?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(quotas.enumerated()), id: \.offset) { _, quota in
                quotaRow(quota)
            }
            if let resetCredits {
                SettingsDivider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        bankLabel(resetCredits)
                        Spacer(minLength: 8)
                        bankExpiry(resetCredits)
                        useButton(resetCredits)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        bankLabel(resetCredits)
                        bankExpiry(resetCredits)
                        useButton(resetCredits)
                    }
                }
                if let resetBlocker, onUseReset != nil {
                    Text(resetBlocker)
                        .font(.system(size: 11))
                        .foregroundStyle(HarnaisPalette.label)
                }
            }
        }
        .padding(16)
    }

    private func quotaRow(_ quota: FeedQuota) -> some View {
        let remaining = min(max(quota.percentRemaining, 0), 100)
        let title = UsageFormat.windowTitle(quota)
        let reset = UsageFormat.compactReset(quota, now: now)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(HarnaisType.rowTitle)
                    .foregroundStyle(HarnaisPalette.text)
                Spacer(minLength: 8)
                Text("\(Int(remaining.rounded()))% left")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(remaining <= 10 ? HarnaisPalette.warning : HarnaisPalette.text)
            }
            GeometryReader { geometry in
                Capsule().fill(HarnaisPalette.track)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(HarnaisPalette.quotaFill(for: provider, remaining: remaining))
                            .frame(width: geometry.size.width * remaining / 100)
                    }
            }
            .frame(height: 6)
            HStack(spacing: 12) {
                Text("\(Int(quota.usedPercent.rounded()))% used")
                Spacer(minLength: 8)
                if let reset {
                    Text(reset == "Not started" ? "Starts on first use" : reset == "now" ? "Resets now" : "Resets in \(reset)")
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(HarnaisPalette.label)
        }
        .accessibilityElement(children: .combine)
    }

    private func bankLabel(_ credits: ResetCredits) -> some View {
        Text(credits.caption)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(HarnaisPalette.text)
            .help("Banked resets are spent only when you confirm, and are separate from scheduled usage resets.")
    }

    @ViewBuilder
    private func useButton(_ credits: ResetCredits) -> some View {
        if credits.availableCount > 0, let onUseReset {
            HarnaisButton(title: isUsingReset ? "Checking…" : "Use reset…", prominence: .primary, enabled: !isUsingReset && resetBlocker == nil, action: onUseReset)
                .help(resetBlocker ?? "Checks live limits first. Nothing is spent until you confirm.")
        }
    }

    @ViewBuilder
    private func bankExpiry(_ credits: ResetCredits) -> some View {
        if let expiry = credits.expiryCaption(now: now) {
            Text(expiry)
                .font(.system(size: 11))
                .foregroundStyle(HarnaisPalette.label)
        }
    }
}
