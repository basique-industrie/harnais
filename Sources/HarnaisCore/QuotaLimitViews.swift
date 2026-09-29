import Domain
import SwiftUI

/// Remaining-fill meter shared by Home Limits and Usage → Limits.
/// Fill is quota left. Title, remaining, and refill sit inside a compact bar.
struct QuotaRemainingMeter: View {
    static let height: CGFloat = 34
    private static let cornerRadius: CGFloat = 10

    let provider: ProviderKind
    let remaining: Double
    let title: String
    var resetCaption: String? = nil
    var resetCredits: ResetCredits? = nil
    var now: Date = Date()
    var help: String = ""

    var body: some View {
        let clamped = min(max(remaining, 0), 100)
        let depleted = QuotaSeverity.of(percentRemaining: clamped) == .critical
            || QuotaSeverity.of(percentRemaining: clamped) == .depleted
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                shape.fill(HarnaisPalette.track)
                if clamped > 0 {
                    Rectangle()
                        .fill(HarnaisPalette.quotaFill(for: provider, remaining: clamped))
                        .frame(width: geo.size.width * clamped / 100, height: geo.size.height)
                }
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HarnaisPalette.text)
                        .lineLimit(1)
                    Text(Self.remainingCaption(clamped))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(depleted ? HarnaisPalette.warning : HarnaisPalette.text)
                        .fixedSize()
                    Spacer(minLength: 4)
                    if resetCaption != nil || (resetCredits?.availableCount ?? 0) > 0 {
                        HStack(spacing: 4) {
                            if let resetCaption {
                                Image(systemName: resetCaption == "Not started" ? "clock" : "arrow.clockwise")
                                Text(resetCaption)
                            }
                            if let resetCredits, resetCredits.availableCount > 0 {
                                if resetCaption != nil { Text("·").foregroundStyle(HarnaisPalette.tertiary) }
                                HStack(spacing: 3) {
                                    LucideIcon(glyph: .ticket, size: 12, tint: .labelColor)
                                    Text("\(resetCredits.availableCount)")
                                }
                                    .fontWeight(.semibold)
                                    .help([resetCredits.caption, resetCredits.expiryCaption(now: now)]
                                        .compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(HarnaisPalette.text)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(HarnaisPalette.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                        .fixedSize()
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(shape)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .help([help, resetCredits?.caption, resetCredits?.expiryCaption(now: now),
               resetCredits == nil ? nil : "Banked resets are redeemed manually before expiry. They are separate from scheduled or provider-wide usage resets."]
            .compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["\(title), \(Self.remainingCaption(clamped)) left", resetCaption,
                             resetCredits?.caption, resetCredits?.expiryCaption(now: now)]
            .compactMap { $0 }.joined(separator: ", "))
    }

    static func remainingCaption(_ remaining: Double) -> String {
        remaining <= 0 ? "Empty" : "\(Int(remaining.rounded()))%"
    }
}

struct LimitPoolMember: Identifiable {
    var account: Account
    var quota: FeedQuota
    var email: String?
    var resetCredits: ResetCredits? = nil
    var id: UUID { account.id }
}

/// Per-account Limits on Home. Same meter as Usage → Limits.
struct AccountQuotaStrip: View {
    let provider: ProviderKind
    let quotas: [FeedQuota]
    var resetCredits: ResetCredits? = nil
    var now: Date = Date()
    var onDepleted: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(quotas, id: \.stripID) { quota in
                let remaining = quota.percentRemaining
                let depleted = QuotaSeverity.of(percentRemaining: remaining) == .depleted
                    || QuotaSeverity.of(percentRemaining: remaining) == .critical
                QuotaRemainingMeter(
                    provider: provider,
                    remaining: remaining,
                    title: UsageFormat.windowTitle(quota),
                    resetCaption: UsageFormat.compactReset(quota, now: now),
                    resetCredits: provider == .claude && quota.windowKind != .weekly ? nil : resetCredits,
                    now: now,
                    help: depleted
                        ? "Open Usage"
                        : "\(Int(quota.usedPercent.rounded()))% used. Bar is quota left."
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if depleted { onDepleted?() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// T3-style pooled limits, with an inline reset badge for each account.
struct LimitPoolCard: View {
    let provider: ProviderKind
    let title: String
    let members: [LimitPoolMember]
    var now: Date = Date()

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                summary
                HStack(spacing: 4) {
                    ForEach(members) { member in
                        accountSegment(member).frame(minWidth: 218)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                summary
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 4)], spacing: 4) {
                    ForEach(members) { member in accountSegment(member) }
                }
            }
        }
        .padding(16)
        .background(HarnaisPalette.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(HarnaisPalette.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(HarnaisType.rowTitle)
                .foregroundStyle(HarnaisPalette.text)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(remainingPercent)%")
                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                    .foregroundStyle(HarnaisPalette.text)
                Text("left")
                    .font(.system(size: 12))
                    .foregroundStyle(HarnaisPalette.label)
            }
            if let refill = nextRefill {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                    Text("+\(refill.percent)% in \(refill.caption)")
                }
                .font(.system(size: 11))
                .foregroundStyle(HarnaisPalette.tertiary)
                .help("The next scheduled reset restores this share of the combined allowance.")
            }
        }
        .frame(minWidth: 148, alignment: .leading)
    }

    private func accountSegment(_ member: LimitPoolMember) -> some View {
        let remaining = min(max(member.quota.percentRemaining, 0), 100)
        let chipLabel = member.account.displayLabel(email: member.email)
        return QuotaRemainingMeter(
            provider: provider,
            remaining: remaining,
            title: chipLabel,
            resetCaption: UsageFormat.compactReset(member.quota, now: now),
            resetCredits: provider == .claude && member.quota.windowKind != .weekly ? nil : member.resetCredits,
            now: now,
            help: "\(chipLabel): \(Int(remaining.rounded()))% left, \(Int(member.quota.usedPercent.rounded()))% used. Bar is quota left."
        )
    }

    private var remainingPercent: Int {
        QuotaWindowMath.pooledRemainingPercent(members.map(\.quota.percentRemaining))
    }

    private var nextRefill: (percent: Int, caption: String)? {
        let restoring = members.enumerated().filter { $0.element.quota.usedPercent > 0 }
        guard let next = restoring.min(by: { lhs, rhs in
            (lhs.element.quota.resetsAt ?? .distantFuture) < (rhs.element.quota.resetsAt ?? .distantFuture)
        }) else { return nil }
        guard let caption = UsageFormat.compactReset(next.element.quota, now: now) else { return nil }
        let restores = QuotaWindowMath.refillDelta(currentRemaining: members.map(\.quota.percentRemaining),
                                                   resettingIndex: next.offset)
        guard restores > 0 else { return nil }
        return (restores, caption)
    }

}

private extension FeedQuota {
    var stripID: String {
        "\(type)|\(compactTitle ?? "")"
    }
}
