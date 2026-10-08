import Domain
import Foundation
import Infrastructure
import SwiftUI

struct ProviderEditorView: View {
    let account: Account
    let report: ConnectionReport
    let quotas: [FeedQuota]
    let wrapperPath: String
    let t3Placement: T3AccountPlacement
    let t3SignsInSeparately: Bool
    let onRename: (String) -> Void
    let onLogin: () -> Void
    let onTerminal: () -> Void
    let onCheck: () -> Void
    let onRefreshLimits: () -> Void
    let onApplyT3: () -> Void
    let onCopyT3: () -> Void
    let onViewT3: () -> Void
    let onOpenBinaries: () -> Void
    let onOpenUsage: () -> Void
    let onOpenConnections: () -> Void
    let onOpenSkills: () -> Void
    let onRemove: () -> Void
    var resetCredits: ResetCredits?
    var onStartWeek: (() -> Void)?
    var isStartingWeek = false
    var weekStartMessage: String?
    var isChecking = false
    var isRefreshingLimits = false
    var t3Success = false
    var t3Status: T3ProviderStatus?
    var t3SignIn: T3AuthState?
    var isSyncingT3 = false
    var onSignInT3: (() -> Void)?
    var onCancelT3SignIn: (() -> Void)?
    var errorMessage: String?
    var successMessage: String?
    var onColorChange: (AccountColor?, Bool) -> Void = { _, _ in }

    @State private var draftName = ""
    @State private var isEditingName = false
    @State private var selectedTab = AccountDetailTab.overview
    @State private var copiedT3 = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HarnaisCanvas(
            title: isEditingName ? nil : visibleName,
            subtitle: nil,
            titleOverride: isEditingName ? AnyView(titleEditor) : AnyView(accountHeading),
            titleAccessory: nil,
            errorMessage: errorMessage,
            successMessage: successMessage,
            toolbar: { toolbar },
            content: {
                HarnaisSegmentedControl(
                    items: AccountDetailTab.allCases,
                    selection: $selectedTab,
                    title: { $0.rawValue },
                    accessibilityTitle: "Account sections"
                )
                switch selectedTab {
                case .overview:
                    if showsSignIn || !report.installed { identity }
                    limits
                    connectionsAndSkills
                    if account.provider == .opencode { connectedAccounts }
                case .settings:
                    AccountColorSection(account: account, isNativeT3Account: t3Placement == .nativeDefault,
                                        onChange: onColorChange)
                    files
                    t3Section
                    removeSection
                }
            }
        )
        .onAppear {
            draftName = account.label
            isEditingName = false
            nameFocused = false
            selectedTab = .overview
            copiedT3 = false
        }
        .onChange(of: account.id) { _, _ in
            draftName = account.label
            isEditingName = false
            nameFocused = false
            selectedTab = .overview
            copiedT3 = false
        }
        .onChange(of: account.label) { _, newValue in
            if !isEditingName, draftName != newValue { draftName = newValue }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if isEditingName {
                HarnaisButton(title: "Save", prominence: .primary) {
                    commitName()
                    isEditingName = false
                    nameFocused = false
                }
                .disabled(!AccountNaming.isReadable(draftName))
                HarnaisButton(title: "Cancel", prominence: .ghostMuted) {
                    draftName = account.label
                    isEditingName = false
                    nameFocused = false
                }
            } else if let primary = primaryAction {
                HarnaisButton(title: primary.title, prominence: .primary, action: primary.action)
            }
            if !isEditingName { accountMenu }
        }
    }

    private var titleEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(account.provider.displayName, text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(HarnaisPalette.text)
                .focused($nameFocused)
                .onSubmit {
                    guard AccountNaming.isReadable(draftName) else { return }
                    commitName()
                    isEditingName = false
                    nameFocused = false
                }
                .frame(maxWidth: 360)
            if !AccountNaming.isReadable(draftName) {
                Text("Use a name like Work or Personal.")
                    .font(HarnaisType.status)
                    .foregroundStyle(HarnaisPalette.warning)
            }
        }
    }

    private var accountHeading: some View {
        HStack(alignment: .top, spacing: 12) {
            AccountColorMark(account: account).padding(.top, 10)
            ProviderMark(provider: account.provider, size: 32)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(visibleName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(HarnaisPalette.text)
                Text("\(account.provider.displayName) · \(statusLine)")
                    .font(HarnaisType.status)
                    .foregroundStyle(HarnaisPalette.label)
                if showsMailbox, let email = report.email {
                    Text(email)
                        .font(.system(size: 12))
                        .foregroundStyle(HarnaisPalette.label)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var accountMenu: some View {
        Menu {
            Button("Rename account…", action: beginRename)
            Button(isChecking ? "Checking connection…" : "Check connection", action: onCheck)
                .disabled(isChecking || report.kind == .checking)
                .keyboardShortcut("r", modifiers: .command)
            if report.installed {
                Button(report.authenticated ? "Sign in again…" : "Sign in…", action: onLogin)
            }
            Divider()
            Menu("T3 Code") {
                Button("View configuration…", action: onViewT3)
                Button("Copy JSON", action: copyT3)
            }
            Button("Account settings") { selectedTab = .settings }
            Divider()
            Button("Remove account…", role: .destructive, action: onRemove)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HarnaisPalette.label)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Account actions")
        .help("Account actions")
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsSignIn {
                Text("Opens the official \(account.provider.displayName) login with this profile already selected.")
                    .font(HarnaisType.status)
                    .foregroundStyle(HarnaisPalette.label)
            }
            if !report.installed {
                Text("Install the \(account.provider.displayName) CLI to use this account.")
                    .font(HarnaisType.status)
                    .foregroundStyle(HarnaisPalette.label)
            }
        }
    }

    private var connectedAccounts: some View {
        SettingsSection(title: "Connected accounts") {
            if report.connectedAccounts.isEmpty {
                SettingsRow(title: isChecking ? "Checking accounts…" : "No saved logins", description: "Connect a provider to use OpenCode with this profile.") {
                    HarnaisButton(title: "Connect provider", action: onLogin)
                }
            } else {
                ForEach(Array(report.connectedAccounts.enumerated()), id: \.element.id) { index, login in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: login.providerName, status: login.loginMethod) {
                        if let url = login.accountURL {
                            HarnaisButton(title: "Open account") { NSWorkspace.shared.open(url) }
                        }
                    }
                    if let email = login.email {
                        editorCopyRow(title: "Email", value: email)
                    }
                    if let plan = login.plan {
                        SettingsRow(title: "Plan", status: plan) { EmptyView() }
                    }
                    if login.email == nil || login.plan == nil {
                        SettingsRow(
                            title: "Account details",
                            description: missingDetailsMessage(login)
                        ) { EmptyView() }
                    }
                }
            }

        }
    }

    private func missingDetailsMessage(_ login: ConnectedAccount) -> String {
        let missing = login.email == nil && login.plan == nil ? "Email and plan details are"
            : login.email == nil ? "The email address is" : "Plan details are"
        let location = login.accountURL != nil ? " Open your account to view them." : " Check your provider's account page."
        return "\(missing) not included in this saved login.\(location)"
    }

    private var t3Section: some View {
        SettingsSection(title: "T3 Code") {
            SettingsRow(
                title: "Use in T3 Code",
                description: t3RowDescription
            ) {
                t3Control
            }
            if t3Placement != .notMerged {
                SettingsDivider()
                SettingsRow(title: "T3 sign-in", description: t3SignInDescription, status: t3CheckedLabel) {
                    t3SignInControl
                }
            }
            SettingsDivider()
            editorCopyRow(title: "Instance ID", value: account.t3InstanceID)
            SettingsDivider()
            SettingsRow(
                title: "Manual configuration",
                description: t3JSONDescription
            ) {
                HStack(spacing: 6) {
                    if copiedT3 {
                        SettingsCheck(title: "Copied")
                    }
                    HarnaisButton(title: "View JSON…", action: onViewT3)
                    HarnaisButton(title: "Copy JSON", action: copyT3)
                }
            }
        }
    }

    @ViewBuilder
    private var t3Control: some View {
        if isSyncingT3 {
            ProgressView().controlSize(.small)
        } else if t3Success {
            SettingsCheck(title: HarnaisRuntime.t3UpdatedMessage)
        } else {
            switch t3Placement {
            case .nativeDefault:
                if !t3SignsInSeparately {
                    SettingsCheck(title: "T3 already uses this login")
                }
            case .merged:
                HarnaisButton(title: "Update in T3 Code", action: onApplyT3)
            case .notMerged:
                HarnaisButton(title: "Add to T3 Code", action: onApplyT3)
            }
        }
    }

    private var limits: some View {
        SettingsSection(
            title: "Usage limits",
            headerAction: AnyView(
                HStack(spacing: 8) {
                    HarnaisButton(title: "All usage", size: .sm, action: onOpenUsage)
                    HarnaisIconButton(
                        systemName: "arrow.clockwise",
                        accessibilityLabel: "Refresh limits",
                        spinning: isRefreshingLimits,
                        action: onRefreshLimits
                    )
                    .disabled(isRefreshingLimits)
                }
            )
        ) {
            if quotas.isEmpty {
                SettingsRow(
                    title: account.provider == .opencode ? "OpenCode limits are not available yet." : (showsSignIn ? "Sign in to see limits." : "No limits reported.")
                ) {
                    EmptyView()
                }
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    AccountUsageDetails(
                        provider: account.provider,
                        quotas: quotas,
                        resetCredits: resetCredits,
                        now: context.date
                    )
                }
            }
            if account.provider == .codex, quotas.contains(where: { $0.awaitingFirstUse == true }) {
                SettingsDivider()
                SettingsRow(title: "Weekly window not started",
                            description: weekStartMessage ?? "Start it with one small request. Uses a little allowance; keeps your banked resets.") {
                    HarnaisButton(title: isStartingWeek ? "Starting…" : "Start week") { onStartWeek?() }
                        .disabled(isStartingWeek || isRefreshingLimits)
                }
            }
        }
    }

    private var connectionsAndSkills: some View {
        SettingsSection(title: "Tools for this account") {
            SettingsRow(title: "Connections", description: "Choose the services this account can access.") {
                HarnaisButton(title: "Manage", action: onOpenConnections)
                    .accessibilityLabel("Manage connections for \(visibleName)")
            }
            SettingsDivider()
            SettingsRow(title: "Skills", description: "Choose the instructions and workflows available to this account.") {
                HarnaisButton(title: "Manage", action: onOpenSkills)
                    .accessibilityLabel("Manage skills for \(visibleName)")
            }
        }
    }

    private var files: some View {
        SettingsSection(title: "Local configuration") {
            editorCopyRow(title: "Terminal command", value: wrapperPath)
            SettingsDivider()
            editorCopyRow(title: "Account folder", value: account.homePath)
            if let shadow = account.shadowHomePath {
                SettingsDivider()
                editorCopyRow(title: "Shadow home", value: shadow)
            }
            if account.importedDefault {
                SettingsDivider()
                SettingsRow(title: "Source", description: "Imported from the default home on this Mac.") {
                    EmptyView()
                }
            }
            if account.codexMode == .t3Shadow {
                SettingsDivider()
                SettingsRow(
                    title: "Codex history",
                    description: "Shares ~/.codex with T3. Auth stays in the shadow home."
                ) {
                    EmptyView()
                }
            }
            ForEach(extraEnvKeys, id: \.self) { key in
                SettingsDivider()
                editorCopyRow(title: key, value: account.env[key] ?? "")
            }
        }
    }

    private var removeSection: some View {
        SettingsSection(title: "Remove account") {
            SettingsRow(
                title: visibleName,
                description: deleteMessage
            ) {
                HarnaisButton(title: "Remove account…", role: .destructive) {
                    onRemove()
                }
            }
        }
    }

    private var extraEnvKeys: [String] {
        account.env.keys.sorted().filter { key in
            let value = ((account.env[key] ?? "") as NSString).expandingTildeInPath
            let home = (account.homePath as NSString).expandingTildeInPath
            let shadow = account.shadowHomePath.map { ($0 as NSString).expandingTildeInPath }
            if value == home || value == shadow { return false }
            return true
        }
    }

    private var showsMailbox: Bool {
        AccountNaming.shouldShowMailbox(visibleName: visibleName, email: report.email)
    }

    private var showsSignIn: Bool {
        report.kind != .checking && !report.authenticated && report.installed
    }

    private var primaryAction: (title: String, action: () -> Void)? {
        if !report.installed {
            return ("Binaries", onOpenBinaries)
        }
        if showsSignIn {
            return ("Sign in", onLogin)
        }
        return ("Open in Terminal", onTerminal)
    }

    private var visibleName: String {
        AccountNaming.isReadable(account.label) ? account.label : account.displayLabel(email: report.email)
    }

    private var statusLine: String {
        if report.authenticated, let plan = report.authLabel, !plan.isEmpty {
            return SubscriptionLabel.sidebarPlan(plan)
        }
        if report.authenticated {
            return "Signed in"
        }
        return report.headline
    }

    private var t3RowDescription: String {
        if t3SignsInSeparately {
            switch t3Placement {
            case .nativeDefault:
                return "T3 signs in to \(account.provider.displayName) itself. Sign in to its \(account.provider.displayName) provider with this account."
            case .merged:
                return "Listed in T3 as an extra profile. Sign in to it in T3 Settings → Providers."
            case .notMerged:
                return "Add this extra profile, then sign in to it in T3 Settings → Providers."
            }
        }
        switch t3Placement {
        case .nativeDefault:
            return "T3 already uses this as the default \(account.provider.displayName) login."
        case .merged:
            return "Listed in T3 as an extra profile."
        case .notMerged:
            return "Add this extra profile. The default login stays as it is."
        }
    }

    @ViewBuilder
    private var t3SignInControl: some View {
        if t3SignIn != nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if let onCancelT3SignIn {
                    HarnaisButton(title: "Cancel", action: onCancelT3SignIn)
                }
            }
        } else if t3SignsInSeparately, let onSignInT3 {
            HarnaisButton(
                title: t3Status?.auth == .authenticated ? "Sign in again…" : "Sign in…",
                prominence: t3Status?.auth == .authenticated && !t3EmailMismatch ? .outline : .primary,
                action: onSignInT3
            )
        } else if t3Status?.auth == .authenticated && !t3EmailMismatch {
            SettingsCheck(title: "Signed in")
        }
    }

    private var t3SignInDescription: String {
        if let t3SignIn {
            if let message = t3SignIn.message, !message.isEmpty { return message }
            switch t3SignIn.phase {
            case .waiting: return "Finish signing in in your browser."
            case .verifying: return "Checking the sign-in…"
            default: return "Starting sign-in in T3 Code…"
            }
        }
        guard let t3Status else {
            return t3SignsInSeparately
                ? "T3 hasn't reported this provider yet. Sign in to use it in T3."
                : "T3 hasn't reported this provider yet."
        }
        switch t3Status.auth {
        case .authenticated:
            guard let email = t3Status.email else { return "Signed in." }
            if t3EmailMismatch, let expected = harnaisEmail {
                return "T3 is signed in as \(email), not \(expected). Sign in again with this account."
            }
            return "Signed in as \(email)" + (t3Status.planLabel.map { " · \($0)" } ?? "") + "."
        case .unauthenticated:
            return t3SignsInSeparately ? "Not signed in. T3 keeps its own login for this provider." : "Not signed in."
        case .unknown:
            return "T3 couldn't tell whether this provider is signed in."
        }
    }

    private var t3CheckedLabel: String? {
        guard t3SignIn == nil, let checkedAt = t3Status?.checkedAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Checked \(formatter.localizedString(for: checkedAt, relativeTo: Date()))"
    }

    private var harnaisEmail: String? {
        report.email ?? account.accountEmail
    }

    /// T3 signed in to a different account than this Harnais profile, e.g. the default Cursor login.
    private var t3EmailMismatch: Bool {
        guard t3Status?.auth == .authenticated,
              let email = t3Status?.email?.trimmingCharacters(in: .whitespaces).lowercased(),
              let expected = harnaisEmail?.trimmingCharacters(in: .whitespaces).lowercased(),
              email.contains("@"), expected.contains("@")
        else { return false }
        return email != expected
    }

    private var t3JSONDescription: String {
        switch t3Placement {
        case .nativeDefault, .merged:
            return "Paste into T3 by hand."
        case .notMerged:
            return "Prefer Add to T3 Code above."
        }
    }

    private var deleteMessage: String {
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

    private func beginRename() {
        draftName = account.label
        isEditingName = true
        nameFocused = true
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AccountNaming.isReadable(trimmed), trimmed != account.label else { return }
        onRename(trimmed)
    }

    private func copyT3() {
        onCopyT3()
        copiedT3 = true
    }

    private func editorCopyRow(title: String, value: String) -> some View {
        SettingsRow(title: title, status: value) {
            HarnaisIconButton(systemName: "square.on.square", accessibilityLabel: "Copy \(title)") {
                HarnaisPasteboard.copy(value)
            }
        }
    }
}

private enum AccountDetailTab: String, CaseIterable {
    case overview = "Overview"
    case settings = "Settings"
}
