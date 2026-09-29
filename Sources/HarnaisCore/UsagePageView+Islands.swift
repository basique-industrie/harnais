import Domain
import SwiftUI

extension UsagePageView {
    var islands: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "Islands feed") {
                SettingsRow(
                    title: feedStatusTitle,
                    description: feedStatusDescription
                ) {
                    HStack(spacing: 6) {
                        if runtime.feedIsStale {
                            HarnaisButton(title: "Refresh now") { runtime.refreshQuotas() }
                        } else {
                            SettingsCheck(title: "Fresh")
                        }
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "Iles",
                    description: ilesDescription
                ) {
                    if runtime.ilesState == .extensionFallback {
                        SettingsCheck(title: "Extension installed")
                    } else {
                        HarnaisButton(title: "Install extension") { runtime.installIlesExtension() }
                    }
                }

            }
            if runtime.accounts.isEmpty {
                Text("Add an account to publish islands.")
                    .font(HarnaisType.status)
                    .foregroundStyle(HarnaisPalette.label)
            } else {
                SettingsSection(
                    title: "Rings",
                    icon: AnyView(LucideIcon(glyph: .lifeBuoy, size: 16, tint: .secondaryLabelColor))
                ) {
                    let items = islandItems
                    if items.isEmpty {
                        SettingsRow(title: "No rings match this filter.") { EmptyView() }
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.key) { index, item in
                            if index > 0 { SettingsDivider() }
                            islandRow(item)
                        }
                    }
                }
                Text("Iles updates every two minutes. Renaming an account keeps its selected rings.")
                    .font(.system(size: 12))
                    .foregroundStyle(HarnaisPalette.label)
            }
        }
    }

    struct IslandItem: Identifiable {
        var key: String
        var title: String
        var provider: ProviderKind
        var remaining: Double
        var hidden: Bool
        var id: String { key }
    }

    var islandItems: [IslandItem] {
        runtime.accounts.flatMap { account -> [IslandItem] in
            runtime.quotas(for: account).map { quota in
                IslandItem(
                    key: quota.type,
                    title: "\(account.provider.displayName) · \(account.displayLabel()) · \(UsageFormat.windowTitle(quota))",
                    provider: account.provider,
                    remaining: quota.percentRemaining,
                    hidden: runtime.isIslandHidden(type: quota.type)
                )
            }
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func islandRow(_ item: IslandItem) -> some View {
        SettingsRow(
            title: item.title,
            description: "\(Int(item.remaining.rounded()))% left"
        ) {
            HStack(spacing: 8) {
                ProviderMark(provider: item.provider, size: 14)
                Toggle("Show in Iles", isOn: Binding(
                    get: { !item.hidden },
                    set: { runtime.setIslandHidden(type: item.key, hidden: !$0) }
                ))
                .toggleStyle(.switch)
                .tint(HarnaisPalette.accent)
                .accessibilityLabel("Show \(item.title) in Iles")
            }
        }
    }

    var feedStatusTitle: String {
        if let captured = runtime.lastQuotaCapturedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Updated \(formatter.localizedString(for: captured, relativeTo: Date()))"
        }
        return "Never published"
    }

    var feedStatusDescription: String? {
        if runtime.feedIsStale {
            return "Refresh usage to update these rings. Changes appear in Iles within two minutes."
        }
        return "Choose which usage limits appear as rings in Iles."
    }

    var ilesDescription: String? {
        switch runtime.ilesState {
        case .extensionFallback:
            return "Extension installed. It refreshes quotas on its own when they go stale."
        case .missing:
            return "Adds Harnais as a source in Iles."
        }
    }
}
