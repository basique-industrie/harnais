import Domain
import SwiftUI

struct BinariesPageView: View {
    @Bindable var runtime: HarnaisRuntime
    var onOpenAccount: (Account) -> Void = { _ in }
    @State private var expanded: Set<ProviderKind> = []

    var body: some View {
        HarnaisCanvas(
            title: "Binaries",
            subtitle: "Update your coding tools and keep their command-line versions in sync.",
            errorMessage: runtime.errorMessage,
            successMessage: runtime.successMessage,
            toolbar: {
                HarnaisIconButton(
                    systemName: "arrow.clockwise",
                    accessibilityLabel: "Refresh CLIs",
                    spinning: runtime.isCheckingConnection || !runtime.checkingTerminals.isEmpty,
                    action: { runtime.checkConnections() }
                )
                .keyboardShortcut("r", modifiers: .command)
            },
            content: {
                ForEach(runtime.binaries) { binary in
                    binaryCard(binary)
                }
            }
        )
        .onAppear { runtime.checkConnections(force: false) }
    }

    private func binaryCard(_ binary: ProviderBinary) -> some View {
        SettingsSection(
            title: binary.provider.displayName,
            icon: AnyView(ProviderMark(provider: binary.provider, size: 16)),
            headerAction: AnyView(HStack(spacing: 10) {
                Text(binary.versionLabel ?? (binary.installed ? "Installed" : "Not installed"))
                    .font(HarnaisType.version)
                    .foregroundStyle(HarnaisPalette.tertiary)
                if binary.advisory?.showsUpdateAffordance == true {
                    HarnaisButton(title: runtime.isUpdating(binary.provider) ? "Updating…" : "Update",
                                  prominence: .primary, enabled: !runtime.isUpdating(binary.provider)) {
                        runtime.updateBinary(binary.provider)
                    }
                }
            })
        ) {
            if binary.installed {
                terminalRow(binary)
                let owned = runtime.ownedAccounts(provider: binary.provider)
                if !owned.isEmpty {
                    SettingsDivider()
                    SettingsRow(title: "Accounts") {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { accountButtons(owned) }
                            VStack(alignment: .trailing, spacing: 4) { accountButtons(owned) }
                        }
                    }
                }
            } else {
                SettingsRow(title: "Install CLI") {
                    HarnaisButton(title: "Install instructions") { runtime.openInstallPage(binary.provider) }
                }
            }
            SettingsDivider()
            details(binary)
        }
    }

    private func accountButtons(_ accounts: [Account]) -> some View {
        ForEach(accounts) { account in
            HarnaisButton(title: account.displayLabel(email: runtime.connection(for: account).email), prominence: .ghostMuted) {
                onOpenAccount(account)
            }
        }
    }

    private func terminalRow(_ binary: ProviderBinary) -> some View {
        let status = runtime.terminalStatuses[binary.provider]
        let busy = terminalBusy(binary.provider)
        let command = binary.provider.defaultBinaryName
        let target = binary.versionLabel ?? "Harnais's version"
        let matches = status?.matches == true
        let title: String
        let description: String
        if runtime.terminalRestartRequired.contains(binary.provider) {
            title = "Open a new terminal window"
            description = "Your change will apply the next time you open a terminal."
        } else if matches {
            title = "Ready to run"
            description = "Type `\(command)` in your terminal to use this installation."
        } else if status == nil {
            title = "Checking \(command)…"
            description = "Finding the installation your command opens."
        } else if let version = status?.version {
            title = "Your terminal uses a separate installation"
            description = "Typing `\(command)` runs v\(version). Switch to the installation updated here."
        } else if status?.canManage == true {
            title = "\(command) isn't available in your terminal"
            description = "Make this installation available in new terminal windows."
        } else {
            title = "Couldn't verify \(command)"
            description = "Check Details for the paths and shell settings."
        }
        return SettingsRow(title: title, description: description) {
            if runtime.changingTerminals.contains(binary.provider) || (busy && status == nil) {
                ProgressView().controlSize(.small)
            } else if matches {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(HarnaisPalette.accent)
                    .accessibilityLabel("Same installation in Harnais and your terminal")
            } else if status?.canManage == true && status?.managed != true {
                HarnaisButton(
                    title: status?.version.map { "v" + $0 } == binary.versionLabel
                        ? "Share installation" : "Switch to \(target)",
                    prominence: .primary
                ) {
                    runtime.useCLIInTerminal(binary.provider)
                }
                .help("New terminal windows will use the installation Harnais updates.")
            } else if status != nil {
                HarnaisButton(title: "Review settings", prominence: .ghostMuted) {
                    expanded.insert(binary.provider)
                }
            }
        }
        .disabled(busy)
    }

    private func terminalBusy(_ provider: ProviderKind) -> Bool {
        runtime.checkingTerminals.contains(provider) || runtime.changingTerminals.contains(provider)
    }

    private func terminalPreference(_ binary: ProviderBinary) -> some View {
        let status = runtime.terminalStatuses[binary.provider]
        return SettingsRow(
            title: "Keep command-line updates in sync",
            description: "Always run the installation Harnais updates when you type `\(binary.provider.defaultBinaryName)`. Turn off to let your shell choose again."
        ) {
            Toggle("Keep \(binary.provider.displayName) command-line updates in sync", isOn: Binding(
                get: { status?.managed == true },
                set: { enabled in runtime.useCLIInTerminal(binary.provider, reset: !enabled) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(terminalBusy(binary.provider) || (status?.managed != true && status?.canManage != true))
        }
    }

    private func details(_ binary: ProviderBinary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded.contains(binary.provider) { expanded.remove(binary.provider) }
                else { expanded.insert(binary.provider) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded.contains(binary.provider) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Details").font(HarnaisType.status)
                    Spacer()
                }
                .foregroundStyle(HarnaisPalette.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.contains(binary.provider) {
                if let path = binary.path { pathRow("Updated by Harnais", path: path) }
                if let path = runtime.terminalStatuses[binary.provider]?.path { pathRow("Opened by " + binary.provider.defaultBinaryName, path: path) }
                if let message = runtime.terminalStatuses[binary.provider]?.message {
                    SettingsRow(title: "Command check", description: message) { EmptyView() }
                }
                if let command = binary.advisory?.plan?.command {
                    SettingsRow(title: "Update command", status: "`\(command)`") {
                        HarnaisIconButton(systemName: "square.on.square", accessibilityLabel: "Copy update command") {
                            HarnaisPasteboard.copy(command)
                        }
                    }
                }
                terminalPreference(binary)
            }
        }
    }

    private func pathRow(_ title: String, path: String) -> some View {
        SettingsRow(title: title, status: path) {
            HStack(spacing: 6) {
                HarnaisIconButton(systemName: "square.on.square", accessibilityLabel: "Copy \(title) path") {
                    HarnaisPasteboard.copy(path)
                }
                HarnaisIconButton(systemName: "folder", accessibilityLabel: "Show \(title) in Finder") {
                    runtime.revealBinary(path)
                }
            }
        }
    }
}
