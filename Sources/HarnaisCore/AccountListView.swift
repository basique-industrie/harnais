import Domain
import SwiftUI

struct AccountListView: View {
    @Bindable var runtime: HarnaisRuntime
    var onAdd: (ProviderKind?) -> Void
    var onLogin: (Account) -> Void
    var onExport: (Account) -> Void
    var onOpenBinaries: () -> Void
    var onOpenUsage: () -> Void
    var onOpenConnections: (Account) -> Void
    var onOpenSkills: (Account) -> Void
    var onRemove: (Account) -> Void

    var body: some View {
        if runtime.accounts.isEmpty {
            HarnaisCanvas(
                title: "Accounts",
                errorMessage: runtime.errorMessage,
                successMessage: runtime.successMessage
            ) {
                emptyState
            }
        } else if let account = runtime.selectedAccount ?? runtime.accounts.first {
            ProviderEditorView(
                account: account,
                report: runtime.connection(for: account),
                quotas: runtime.quotas(for: account),
                wrapperPath: runtime.wrapperPath(for: account),
                t3Placement: runtime.t3Placement(for: account),
                onRename: { runtime.rename(account, label: $0) },
                onLogin: { onLogin(account) },
                onTerminal: { runtime.openTerminal(for: account) },
                onCheck: { runtime.checkConnection(account) },
                onRefreshLimits: { runtime.refreshQuotas() },
                onApplyT3: { runtime.applyT3() },
                onCopyT3: { HarnaisPasteboard.copy(runtime.t3Snippet(for: account)) },
                onViewT3: { onExport(account) },
                onOpenBinaries: onOpenBinaries,
                onOpenUsage: onOpenUsage,
                onOpenConnections: { onOpenConnections(account) },
                onOpenSkills: { onOpenSkills(account) },
                onRemove: { onRemove(account) },
                resetCredits: runtime.resetCredits(for: account),
                onStartWeek: { runtime.startCodexWeek(account) },
                isStartingWeek: runtime.startingCodexWeeks.contains(account.id),
                weekStartMessage: runtime.codexWeekMessage(for: account),
                isChecking: runtime.isCheckingConnection || runtime.checkingAccounts.contains(account.id),
                isRefreshingLimits: runtime.isRefreshingQuotas,
                t3Success: runtime.didUpdateT3,
                errorMessage: runtime.errorMessage,
                successMessage: runtime.didUpdateT3 ? nil : runtime.successMessage
            )
            .id(account.id)
        }
    }

    private var emptyState: some View {
        AccountsEmptyState(
            onImport: { runtime.importDefaults() },
            onAdd: { onAdd(nil) }
        )
    }
}
