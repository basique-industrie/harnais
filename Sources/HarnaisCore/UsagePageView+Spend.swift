import Domain
import SwiftUI

extension UsagePageView {
    var spend: some View {
        let totals = runtime.usage.report(for: range).totals
        let points = runtime.usage.report(for: range).points
        return VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metric == .cost ? UsageFormat.usd(totals.cost) : UsageFormat.tokens(totals.processed))
                            .font(.system(size: 34, weight: .semibold).monospacedDigit())
                            .foregroundStyle(HarnaisPalette.text)
                        Text(rangeCaption)
                            .font(.system(size: 12))
                            .foregroundStyle(HarnaisPalette.label)
                        Text(heroCaption(totals: totals))
                            .font(.system(size: 12))
                            .foregroundStyle(HarnaisPalette.label)
                    }
                    ForEach(legendSlices) { slice in
                        providerLegend(slice, totals: totals)
                    }
                }
                .frame(width: 288, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    Text(metric == .cost ? "Daily cost" : "Daily processed tokens")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(HarnaisPalette.text)
                    if points.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No sessions in this window.")
                                .font(HarnaisType.status)
                                .foregroundStyle(HarnaisPalette.label)
                            if range != .days90 {
                                HarnaisButton(title: "Show 90 days") { navigation.range = .days90 }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
                    } else {
                        UsageTrendChart(points: points, metric: metric)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            breakdownTable(totals: totals)
        }
    }

    func providerLegend(_ slice: UsageSlice, totals: UsageTotals) -> some View {
        let share = metric == .cost
            ? (totals.cost == 0 ? 0 : slice.cost / totals.cost)
            : (totals.processed == 0 ? 0 : slice.tokens / totals.processed)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(HarnaisPalette.chartStroke(for: slice.provider))
                    .frame(width: 8, height: 8)
                ProviderMark(provider: slice.provider, size: 14)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(slice.provider.displayName)
                        .font(.system(size: 13))
                        .foregroundStyle(HarnaisPalette.text)
                        .lineLimit(1)
                    Text("\(slice.sessions) \(slice.sessions == 1 ? "session" : "sessions")")
                        .font(.system(size: 11))
                        .foregroundStyle(HarnaisPalette.label)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 8)
                Text(metric == .cost ? UsageFormat.usd(slice.cost) : UsageFormat.tokens(slice.tokens))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(HarnaisPalette.text)
                    .fixedSize()
            }
            Text(
                metric == .cost
                    ? "\(percent(share)) of cost · \(UsageFormat.tokens(slice.tokens)) tokens"
                    : "\(percent(share)) of tokens · \(UsageFormat.usd(slice.cost))"
            )
            .font(.system(size: 12))
            .foregroundStyle(HarnaisPalette.label)
        }
    }

    func breakdownTable(totals: UsageTotals) -> some View {
        let rows = breakdownRows
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Breakdown")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(HarnaisPalette.text)
                Spacer(minLength: 8)
                HarnaisSegmentedControl(
                    items: [BreakdownMode.model, .account, .day],
                    selection: $navigation.breakdown,
                    title: { $0.title }
                )
            }
            if rows.isEmpty {
                Text("No usage in this window.")
                    .font(HarnaisType.status)
                    .foregroundStyle(HarnaisPalette.label)
            } else {
                HStack {
                    Text(breakdownColumnTitle)
                    Spacer()
                    Text("Cost").frame(width: 88, alignment: .trailing)
                    Text("Share").frame(width: 64, alignment: .trailing)
                    Text("Tokens").frame(width: 72, alignment: .trailing)
                }
                .font(.system(size: 12))
                .foregroundStyle(HarnaisPalette.label)
                ForEach(rows) { row in
                    Rectangle()
                        .fill(HarnaisPalette.hairline)
                        .frame(height: 1)
                    HStack(spacing: 8) {
                        if let provider = row.provider {
                            ProviderMark(provider: provider, size: 14)
                        }
                        Text(row.title)
                            .font(.system(size: 13))
                            .foregroundStyle(HarnaisPalette.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(UsageFormat.usd(row.cost))
                            .frame(width: 88, alignment: .trailing)
                        Text(sharePercent(row, totals: totals))
                            .frame(width: 64, alignment: .trailing)
                        Text(UsageFormat.tokens(row.tokens))
                            .frame(width: 72, alignment: .trailing)
                    }
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(HarnaisPalette.text)
                }
            }
        }
    }

    var breakdownRows: [UsageBreakdownRow] {
        switch breakdown {
        case .model:
            return sortedByMetric(runtime.usage.report(for: range).models)
        case .day:
            return runtime.usage.report(for: range).days
        case .account:
            return sortedByMetric(accountBreakdown())
        }
    }

    var breakdownColumnTitle: String {
        switch breakdown {
        case .model: "Model"
        case .day: "Day"
        case .account: "Account"
        }
    }

    /// Per-account spend: which subscription drove cost. Groups scanned events
    /// by account and joins display names from the registry.
    func accountBreakdown() -> [UsageBreakdownRow] {
        runtime.usage.report(for: range).accounts.compactMap { row in
            guard let account = runtime.accounts.first(where: { $0.id.uuidString == row.id }) else { return nil }
            return UsageBreakdownRow(id: row.id,
                title: "\(account.provider.displayName) · \(account.displayLabel())",
                provider: account.provider, cost: row.cost, tokens: row.tokens)
        }
    }

    func sortedByMetric(_ rows: [UsageBreakdownRow]) -> [UsageBreakdownRow] {
        rows.sorted { lhs, rhs in
            let left = metric == .tokens ? lhs.tokens : lhs.cost
            let right = metric == .tokens ? rhs.tokens : rhs.cost
            return left == right ? lhs.id < rhs.id : left > right
        }
    }

    // MARK: - Islands (Iles rings)

    func heroCaption(totals: UsageTotals) -> String {
        if totals.sessions == 0 {
            return runtime.isRefreshingUsage ? "Scanning sessions…" : "No sessions in this window."
        }
        var parts = ["\(totals.sessions) sessions"]
        if totals.cacheSavings > 0 {
            parts.append("\(UsageFormat.usd(totals.cacheSavings)) cache savings")
        }
        parts.append("estimate as of \(ModelRates.pricedAsOf)")
        return parts.joined(separator: " · ")
    }

    func sharePercent(_ row: UsageBreakdownRow, totals: UsageTotals) -> String {
        if metric == .tokens {
            return percent(totals.processed == 0 ? 0 : row.tokens / totals.processed)
        }
        return percent(totals.cost == 0 ? 0 : row.cost / totals.cost)
    }

    var rangeCaption: String {
        let now = runtime.usage.capturedAt ?? Date()
        let start = now.addingTimeInterval(-range.interval)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: start)) to \(formatter.string(from: now))"
    }

    var legendSlices: [UsageSlice] {
        runtime.usage.report(for: range).slices.sorted { lhs, rhs in
            if metric == .cost { return lhs.cost > rhs.cost }
            return lhs.tokens > rhs.tokens
        }
    }

    func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
