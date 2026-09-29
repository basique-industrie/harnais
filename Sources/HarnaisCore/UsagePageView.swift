import Domain
import SwiftUI

struct UsagePageView: View {
    @Bindable var runtime: HarnaisRuntime
    @Bindable var navigation: UsageNavigation
    var onLogin: (Account) -> Void = { _ in }
    var tab: UsageTab { navigation.tab }
    var metric: UsageMetric { navigation.metric }
    var range: UsageRange { navigation.range }
    var breakdown: BreakdownMode { navigation.breakdown }
    @State var managingCodexWeeks = false
    var windowFilter: LimitWindowFilter { navigation.windowFilter }

    var body: some View {
        HarnaisCanvas(
            title: "Usage",
            errorMessage: runtime.errorMessage,
            toolbar: { toolbar },
            content: {
                navigationControls
                switch tab {
                case .limits:
                    limits
                case .spend:
                    if runtime.usage.capturedAt == nil && runtime.isRefreshingUsage {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading usage…").foregroundStyle(HarnaisPalette.label)
                        }
                        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
                    } else {
                        spend
                    }
                case .islands:
                    islands
                }
            }
        )
        .sheet(isPresented: $managingCodexWeeks) {
            CodexWeeksSheet(runtime: runtime)
        }
        .onAppear {
            if runtime.usage.capturedAt == nil {
                runtime.refreshUsage()
            }
        }
    }

    var navigationControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                tabs.fixedSize()
                Spacer(minLength: 12)
                filters.fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                tabs
                filters
            }
        }
    }

    var tabs: some View {
        HarnaisSegmentedControl(
            items: Array(UsageTab.allCases), selection: $navigation.tab,
            title: { $0.title }, accessibilityTitle: "Usage section"
        )
    }

    @ViewBuilder
    var filters: some View {
        if tab == .limits {
            HarnaisSegmentedControl(
                items: Array(LimitWindowFilter.allCases), selection: $navigation.windowFilter,
                title: { $0.title }, accessibilityTitle: "Limit window", quiet: true
            )
        } else if tab == .spend {
            HStack(spacing: 8) {
                HarnaisSegmentedControl(
                    items: [UsageMetric.cost, .tokens], selection: $navigation.metric,
                    title: { $0.title }, accessibilityTitle: "Spend metric"
                )
                HarnaisSegmentedControl(
                    items: Array(UsageRange.allCases), selection: $navigation.range,
                    title: { $0.shortTitle }, accessibilityTitle: "Time range"
                )
            }
        }
    }

    var toolbar: some View {
        HStack(spacing: 8) {
            if let updated = updatedCaption {
                Text(updated)
                    .font(.system(size: 12))
                    .foregroundStyle(HarnaisPalette.label)
            }
            HarnaisIconButton(
                systemName: "arrow.clockwise",
                accessibilityLabel: refreshLabel,
                spinning: isRefreshing,
                action: refresh
            )
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    func refresh() {
        switch tab {
        case .limits, .islands: runtime.refreshQuotas()
        case .spend: runtime.refreshUsage()
        }
    }

    var refreshLabel: String {
        switch tab {
        case .limits: "Refresh limits"
        case .spend: "Refresh usage"
        case .islands: "Refresh islands feed"
        }
    }

    var updatedCaption: String? {
        switch tab {
        case .limits, .islands:
            return ConnectionReport.updatedAgoLabel(from: runtime.lastQuotaCapturedAt)
        case .spend:
            guard runtime.usage.capturedAt != nil else { return nil }
            return runtime.isRefreshingUsage ? "Updating…" : nil
        }
    }

    var isRefreshing: Bool {
        switch tab {
        case .limits, .islands: runtime.isRefreshingQuotas
        case .spend: runtime.isRefreshingUsage
        }
    }


}

enum UsageTab: Hashable, CaseIterable {
    case limits
    case spend
    case islands

    var title: String {
        switch self {
        case .limits: "Limits"
        case .spend: "Spend"
        case .islands: "Islands"
        }
    }
}

enum BreakdownMode: Hashable {
    case model
    case account
    case day

    var title: String {
        switch self {
        case .model: "Model"
        case .account: "Account"
        case .day: "Day"
        }
    }
}

struct ProviderLimitPool {
    var provider: ProviderKind
    var windows: [PooledLimitWindow]
    var skipped: [AccountUsageItem]
    var accountCount: Int
}

struct PooledLimitWindow: Identifiable {
    var title: String
    var members: [LimitPoolMember]
    var id: String { title }
}

struct AccountUsageItem {
    var account: Account
    var quotas: [FeedQuota]
    var error: String?
}

extension UsageMetric {
    var title: String {
        switch self {
        case .limits: "Limits"
        case .cost: "Cost"
        case .tokens: "Tokens"
        }
    }
}
