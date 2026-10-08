import AppKit
import Domain
import Infrastructure
import SwiftUI

public struct HarnaisRootView: View {
    @Bindable var runtime: HarnaisRuntime
    @State private var navigation = HarnaisNavigation()
    private var page: HarnaisPage {
        get { navigation.page }
        nonmutating set { navigation.page = newValue }
    }
    @State private var adding = false
    @State private var addingProvider: ProviderKind = .claude
    @State private var addingLabel = "Personal"
    @State private var loginAccount: Account?
    @State private var exportAccount: Account?
    @State private var deletingAccount: Account?
    @State private var connectingKind: IntegrationKind?
    @State private var reconnectConnection: IntegrationConnection?
    @State private var deletingConnection: IntegrationConnection?
    @State private var titlebarLeading: CGFloat = 84
    @State private var titlebarHeight: CGFloat = 52

    public init(runtime: HarnaisRuntime) {
        self.runtime = runtime
    }

    public var body: some View {
        HStack(spacing: 0) {
            ProviderSidebar(
                runtime: runtime,
                page: $navigation.page,
                onAdd: presentAdd,
                onLogin: { loginAccount = $0 },
                onTerminal: { runtime.openTerminal(for: $0) },
                onExport: { exportAccount = $0 },
                onRemove: { deletingAccount = $0 }
            )
            Group {
                switch page {
                case .overview:
                    AccountsOverviewView(
                        runtime: runtime,
                        onAdd: presentAdd,
                        onLogin: { loginAccount = $0 },
                        onTerminal: { runtime.openTerminal(for: $0) },
                        onOpenAccount: { account in
                            runtime.select(account)
                            page = .account
                        },
                        onOpenUsage: {
                            navigation.showLimits()
                            runtime.refreshQuotas()
                        }
                    )
                case .account:
                    AccountListView(
                        runtime: runtime,
                        onAdd: presentAdd,
                        onLogin: { loginAccount = $0 },
                        onExport: { exportAccount = $0 },
                        onOpenBinaries: { page = .binaries },
                        onOpenUsage: {
                            navigation.showLimits()
                            runtime.refreshQuotas()
                        },
                        onOpenConnections: { navigation.showConnections(for: $0.id) },
                        onOpenSkills: { navigation.showSkills(for: $0.id) },
                        onRemove: { deletingAccount = $0 }
                    )
                case .skills:
                    SkillsPageView(runtime: runtime, navigation: navigation.skills)
                case .connections:
                    ConnectionsPageView(
                        runtime: runtime, navigation: navigation.connections,
                        onConnect: { connectingKind = $0 },
                        onReconnect: { reconnectConnection = $0 },
                        onRemove: { deletingConnection = $0 }
                    )
                case .health:
                    HealthPageView(runtime: runtime, onOpenAccount: { account in
                        runtime.select(account)
                        page = .account
                    })
                case .syncHistory:
                    SyncHistoryPageView(runtime: runtime)
                case .settings:
                    SettingsPageView(runtime: runtime)
                case .about:
                    AboutPageView()
                case .binaries:
                    BinariesPageView(
                        runtime: runtime,
                        onOpenAccount: { account in
                            runtime.select(account)
                            page = .account
                        }
                    )
                case .usage:
                    UsagePageView(runtime: runtime, navigation: navigation.usage, onLogin: { loginAccount = $0 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HarnaisPalette.background)
        }
        .frame(minWidth: 960, minHeight: 720)
        .background(HarnaisPalette.background)
        .ignoresSafeArea(edges: .top)
        .harnaisChrome(
            title: page.windowTitle(account: runtime.selectedAccount),
            kind: .window,
            titlebarLeading: $titlebarLeading,
            titlebarHeight: $titlebarHeight
        )
        .environment(\.titlebarLeading, titlebarLeading)
        .environment(\.titlebarHeight, titlebarHeight)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(item: $runtime.t3Preview) { preview in
            T3SyncPreviewSheet(runtime: runtime, preview: preview)
        }
        .sheet(isPresented: $adding) {
            AddAccountSheet(
                runtime: runtime,
                initialProvider: addingProvider,
                initialLabel: addingLabel
            ) { account in
                loginAccount = account
            }
        }
        .sheet(item: $loginAccount) { account in
            LoginSheet(account: account, runtime: runtime)
        }
        .sheet(item: $exportAccount) { account in
            T3ExportSheet(account: account, snippet: runtime.t3Snippet(for: account))
        }
        .sheet(item: $connectingKind) { kind in
            if kind == .whatsapp { WhatsAppConnectSheet(runtime: runtime) }
            else { IntegrationConnectSheet(kind: kind, runtime: runtime) }
        }
        .sheet(item: $reconnectConnection) { connection in
            if connection.kind == .whatsapp { WhatsAppConnectSheet(runtime: runtime) }
            else { IntegrationReconnectSheet(connection: connection, runtime: runtime) }
        }
        .overlay {
            if let account = deletingAccount {
                HarnaisConfirmDialog(
                    title: "Remove \(account.displayLabel())?",
                    message: Self.deleteMessage(for: account),
                    confirmTitle: "Remove account",
                    onCancel: { deletingAccount = nil },
                    onConfirm: {
                        runtime.remove(account)
                        deletingAccount = nil
                    }
                )
            } else if let connection = deletingConnection {
                HarnaisConfirmDialog(
                    title: "Disconnect \(connection.kind.displayName)?",
                    message: "Removes \(connection.mcpName) from Claude, Codex, Cursor, OpenCode, and T3. Sign in again to restore it.",
                    confirmTitle: "Disconnect",
                    onCancel: { deletingConnection = nil },
                    onConfirm: {
                        runtime.disconnectConnection(connection)
                        deletingConnection = nil
                    }
                )
            } else if let account = runtime.t3SignInPrompt {
                HarnaisConfirmDialog(
                    title: "Sign in to Cursor in T3 Code?",
                    message: "\(account.label) was added to T3 Code. T3 keeps its own Cursor login; choose the account you want this profile to use.",
                    confirmTitle: "Sign in…",
                    cancelTitle: "Later",
                    confirmRole: nil,
                    onCancel: { runtime.dismissT3SignInPrompt(account) },
                    onConfirm: {
                        runtime.dismissT3SignInPrompt(account)
                        runtime.select(account)
                        page = .account
                        runtime.signInToT3(account)
                    }
                )
            }
        }
        .onAppear {
            runtime.reload()
            runtime.checkConnections()
            runtime.refreshOverview()
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                if runtime.settings.autoStartCodexWeeks == true { runtime.refreshQuotas() }
            }
        }
        .onChange(of: runtime.accounts.map(\.id)) { _, ids in
            navigation.reconcileAccounts(Set(ids))
        }
        .focusedSceneValue(\.harnaisAddAccount, presentAdd)
        .focusedSceneValue(\.harnaisNavigate) { destination in
            page = destination
            if destination == .usage { runtime.refreshQuotas() }
            if destination == .overview { runtime.refreshOverview() }
        }
        .focusedSceneValue(\.harnaisAccountActions, selectedAccountActions)
        .onExitCommand {
            if deletingAccount != nil {
                deletingAccount = nil
            } else if deletingConnection != nil {
                deletingConnection = nil
            } else if let account = runtime.t3SignInPrompt {
                runtime.dismissT3SignInPrompt(account)
            } else if page != .overview, !Self.isEditingText {
                page = .overview
            }
        }
    }

    private var selectedAccountActions: HarnaisAccountActionSet? {
        guard let account = runtime.selectedAccount ?? runtime.accounts.first, page == .account else {
            return nil
        }
        let report = runtime.connection(for: account)
        return HarnaisAccountActionSet(
            openTerminal: { runtime.openTerminal(for: account) },
            signIn: { loginAccount = account },
            copyT3: { HarnaisPasteboard.copy(runtime.t3Snippet(for: account)) },
            viewT3: { exportAccount = account },
            delete: { deletingAccount = account },
            canSignIn: report.installed && !report.authenticated,
            canOpenTerminal: report.installed
        )
    }

    private static var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField || responder is NSText
    }

    private func presentAdd(_ provider: ProviderKind?) {
        let kind = provider ?? .claude
        addingProvider = kind
        addingLabel = AccountNaming.suggestedLabel(for: kind, existing: runtime.accounts)
        adding = true
    }

    private static func deleteMessage(for account: Account) -> String {
        if account.importedDefault {
            let folder: String
            switch account.provider {
            case .claude: folder = "~/.claude"
            case .codex: folder = "~/.codex"
            case .cursor: folder = "~/.cursor"
            case .opencode: folder = "~/.local/share/opencode"
            }
            return "Removes the Harnais profile and wrapper. Your \(folder) login is not deleted."
        }
        return "Removes the Harnais profile and wrapper. Files Harnais created for this account are deleted."
    }
}

private struct HarnaisAddAccountKey: FocusedValueKey {
    typealias Value = (ProviderKind?) -> Void
}

private struct HarnaisNavigateKey: FocusedValueKey {
    typealias Value = (HarnaisPage) -> Void
}

private struct HarnaisAccountActionsKey: FocusedValueKey {
    typealias Value = HarnaisAccountActionSet
}

struct HarnaisAccountActionSet {
    var openTerminal: () -> Void
    var signIn: () -> Void
    var copyT3: () -> Void
    var viewT3: () -> Void
    var delete: () -> Void
    var canSignIn: Bool
    var canOpenTerminal: Bool
}

private struct HarnaisFindKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var harnaisFind: (() -> Void)? {
        get { self[HarnaisFindKey.self] }
        set { self[HarnaisFindKey.self] = newValue }
    }

    var harnaisAddAccount: ((ProviderKind?) -> Void)? {
        get { self[HarnaisAddAccountKey.self] }
        set { self[HarnaisAddAccountKey.self] = newValue }
    }

    var harnaisNavigate: ((HarnaisPage) -> Void)? {
        get { self[HarnaisNavigateKey.self] }
        set { self[HarnaisNavigateKey.self] = newValue }
    }

    var harnaisAccountActions: HarnaisAccountActionSet? {
        get { self[HarnaisAccountActionsKey.self] }
        set { self[HarnaisAccountActionsKey.self] = newValue }
    }
}

public struct HarnaisAccountCommands: Commands {
    @FocusedValue(\.harnaisFind) private var find
    @FocusedValue(\.harnaisAddAccount) private var addAccount
    @FocusedValue(\.harnaisNavigate) private var navigate
    @FocusedValue(\.harnaisAccountActions) private var accountActions

    public init() {}

    // Page shortcuts must work without a focused text field, but must not
    // replace the page underneath a sheet that may contain unsaved work.
    private func perform(_ action: () -> Void) {
        guard NSApp.keyWindow?.sheetParent == nil,
              NSApp.keyWindow?.attachedSheet == nil else { return }
        action()
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppIdentity.current.displayName)") { perform { navigate?(.about) } }
                .disabled(navigate == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Account…") { perform { addAccount?(nil) } }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(addAccount == nil)
            Divider()
            Button("Open in Terminal") { perform { accountActions?.openTerminal() } }
                .disabled(accountActions?.canOpenTerminal != true)
            Button("Sign In…") { perform { accountActions?.signIn() } }
                .disabled(accountActions?.canSignIn != true)
            Button("Copy T3 JSON") { perform { accountActions?.copyT3() } }
                .disabled(accountActions == nil)
            Button("View T3 JSON…") { perform { accountActions?.viewT3() } }
                .disabled(accountActions == nil)
            Divider()
            Button("Delete Account…") { perform { accountActions?.delete() } }
                .disabled(accountActions == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find in page") { perform { find?() } }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(find == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { perform { navigate?(.settings) } }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(navigate == nil)
        }
        CommandGroup(before: .sidebar) {
            Button("Overview") { perform { navigate?(.overview) } }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(navigate == nil)
            Button("Usage") { perform { navigate?(.usage) } }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(navigate == nil)
            Button("Connections") { perform { navigate?(.connections) } }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(navigate == nil)
            Button("Skills") { perform { navigate?(.skills) } }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(navigate == nil)
            Divider()
            Button("Binaries") { perform { navigate?(.binaries) } }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(navigate == nil)
        }
    }
}
