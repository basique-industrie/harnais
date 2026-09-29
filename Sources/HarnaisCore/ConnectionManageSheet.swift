import AppKit
import Domain
import Infrastructure
import SwiftUI

struct ConnectionManageSheet: View {
    let item: CatalogConnection
    @Bindable var runtime: HarnaisRuntime
    var onShare: ((IntegrationKind) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "Overview"

    private var liveItem: CatalogConnection {
        var empty = item; empty.occurrences = []
        var current = CatalogConnection.build(accounts: runtime.accounts, inventory: runtime.connectionInventory).first { $0.id == item.id } ?? empty
        let accounts = Set(item.occurrences.map { $0.account.id })
        current.occurrences.removeAll { !accounts.contains($0.account.id) }
        return current
    }
    private var shareableKind: IntegrationKind? {
        guard item.origin != .builtIn else { return nil }
        return IntegrationKind.allCases.first { $0 != .custom && $0.rawValue == item.name }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ConnectionMark(name: item.name, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayName).font(HarnaisSheetMetrics.titleFont)
                    Text("\(item.origin.rawValue) · \(item.categoryLabel)").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                }
                Spacer()
            }
            Picker("View", selection: $tab) {
                Text("Overview").tag("Overview")
                Text("Installations · \(liveItem.accountCount) account\(liveItem.accountCount == 1 ? "" : "s")").tag("Installations")
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if tab == "Overview" {
                        Text(item.purpose).font(HarnaisType.rowTitle)
                        Text(item.compatibilityNote).font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                        LabeledContent("Installed for", value: item.providerLabel)
                        LabeledContent("Status", value: liveItem.occurrences.isEmpty ? "Removed" : liveItem.activationSummary)
                        if let url = item.documentationURL { Link("Provider documentation ↗", destination: url) }
                        if let kind = shareableKind, let onShare {
                            Divider()
                            Text("Use one service login in every coding account").font(HarnaisType.rowTitle)
                            Text("Connect through Harnais, test the replacement, then retire the separate login. Keep any provider commands and skills you still use.").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                            HarnaisButton(title: "Add shared connection", prominence: .primary) { onShare(kind) }
                        }
                    } else {
                        ConnectionInstallationsView(occurrences: liveItem.occurrences, runtime: runtime)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.frame(height: 350)
            HStack { Spacer(); HarnaisButton(title: "Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 680).background(HarnaisPalette.background)
        .harnaisChrome(title: item.displayName, kind: .sheet).toolbar(removing: .title)
    }
}

/// Account selection and detail stay on one page, including provider sign-in.
struct ConnectionInstallationsView: View {
    let occurrences: [ConnectionOccurrence]
    @Bindable var runtime: HarnaisRuntime
    @State private var selectedID = ""
    @State private var command: LoginCommand?
    @State private var message: String?
    @State private var pendingAction: ConnectionAction?
    @State private var actionTarget: ConnectionOccurrence?
    @State private var providerInstructions: String?
    @State private var providerURL: URL?
    @State private var commandPurpose = "Sign-in"
    private var occurrence: ConnectionOccurrence? { occurrences.first { $0.id == selectedID } ?? occurrences.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let command {
                HarnaisButton(title: "Back to installations", prominence: .ghostMuted) { self.command = nil }
                LoginTerminalView(command: command) { code in
                    message = code == 0 ? "\(commandPurpose) completed. Inventory refreshed; existing provider sessions may need a reload." : "\(commandPurpose) did not complete. Review the terminal output."
                    runtime.refreshConnectionInventory()
                }.frame(height: 250)
            } else {
                ForEach(occurrences) { value in
                    Button { selectedID = value.id; message = nil; providerInstructions = nil; providerURL = nil } label: {
                        HStack(spacing: 8) {
                            ProviderMark(provider: value.account.provider, size: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(value.account.provider.displayName) · \(value.account.displayLabel())").font(HarnaisType.rowTitle)
                                Text(value.entry.origin.rawValue + " · " + (value.entry.parentPlugin.map { "Plugin MCP · " + $0 } ?? "\(value.entry.kind.rawValue) · \(value.entry.name)")).font(.system(size: 11)).lineLimit(2)
                            }
                            Spacer()
                            Text(value.entry.presentationState).font(HarnaisType.control)
                            Image(systemName: occurrence?.id == value.id ? "checkmark.circle.fill" : "circle").foregroundStyle(HarnaisPalette.accent)
                        }.padding(10).contentShape(Rectangle())
                            .background(occurrence?.id == value.id ? HarnaisPalette.muted : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                if let occurrence {
                    Divider()
                    Text("Configuration").font(HarnaisType.rowTitle)
                    if let provenance = occurrence.entry.providerRuntime { Text(provenance).font(HarnaisType.control).foregroundStyle(HarnaisPalette.label) }
                    if let detail = occurrence.entry.activationDetail { Text(detail).font(HarnaisType.control).foregroundStyle(HarnaisPalette.label) }
                    Text(occurrence.entry.scope).font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                    Text(occurrence.entry.source).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        HarnaisButton(title: occurrence.entry.kind == .plugin || occurrence.entry.parentPlugin != nil ? "Reveal source" : "Open settings file") { openSettings(occurrence) }
                        if occurrence.entry.supportsLogin && (occurrence.entry.parentPlugin == nil || occurrence.account.provider == .claude) {
                            HarnaisButton(title: "Sign in for this account") {
                                do { commandPurpose = "Sign-in"; command = try ConnectionManagement.loginCommand(account: occurrence.account, entry: occurrence.entry) }
                                catch { message = error.localizedDescription }
                            }
                        }
                    }
                    if occurrence.entry.origin == .added {
                        HStack {
                            HarnaisButton(title: occurrence.entry.isInactive ? "Enable…" : "Disable…") {
                                prepare(occurrence.entry.isInactive ? .enable : .disable, occurrence)
                            }
                            HarnaisButton(title: "Remove…") { prepare(.remove, occurrence) }
                        }
                        Text("Actions apply to the selected installation and scope. Removing a plugin also removes its skills and hooks. Service login revocation is separate.")
                            .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                    }
                    Text(occurrence.entry.kind == .plugin || occurrence.entry.parentPlugin != nil
                         ? "Installed files alone do not confirm that a plugin is enabled. Actions use the provider’s supported controls; some open instructions for completing the change there."
                         : "These settings belong to this account. Signing in here does not change the shared Harnais login.")
                        .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                    ForEach(occurrence.entry.warnings, id: \.self) { warning in
                        let actionable = occurrence.entry.actionableWarnings.contains(warning)
                        Label(warning, systemImage: actionable ? "exclamationmark.triangle" : "info.circle")
                            .font(HarnaisType.control).foregroundStyle(actionable ? HarnaisPalette.warning : HarnaisPalette.label)
                    }
                }
            }
            if occurrences.isEmpty { Text("This installation is no longer listed.").font(HarnaisType.control) }
            if let providerInstructions {
                Divider()
                Text(providerInstructions).font(HarnaisType.control).textSelection(.enabled)
                HStack {
                    if let providerURL { Link("Provider instructions ↗", destination: providerURL) }
                    HarnaisButton(title: "Refresh status") { runtime.refreshConnectionInventory() }
                }
            }
            if let message { Text(message).font(HarnaisType.control).foregroundStyle(HarnaisPalette.label) }
        }
        .confirmationDialog(actionTitle, isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            if let action = pendingAction, let target = actionTarget {
                Button(action.rawValue, role: action == .remove ? .destructive : nil) { perform(action, target) }
                Button("Cancel", role: .cancel) { pendingAction = nil }
            }
        } message: {
            if let target = actionTarget {
                Text("\(target.account.provider.displayName) · \(target.account.displayLabel()) · \(target.entry.scope)\n\(target.entry.name)\n\(target.entry.source)\nThis affects this installation. Plugin actions include its skills, hooks and servers. Existing provider sessions may need a reload.")
            }
        }
    }
    private var actionTitle: String {
        "\(pendingAction?.rawValue ?? "Manage") \(actionTarget?.entry.displayName ?? "connection")?"
    }
    private func prepare(_ action: ConnectionAction, _ target: ConnectionOccurrence) {
        message = nil; providerInstructions = nil; providerURL = nil
        do {
            if case let .provider(instructions, url) = try ConnectionManagement.actionRoute(action, occurrence: target) {
                providerInstructions = instructions; providerURL = url
            } else { actionTarget = target; pendingAction = action }
        } catch { message = error.localizedDescription }
    }
    private func perform(_ action: ConnectionAction, _ target: ConnectionOccurrence) {
        pendingAction = nil
        do {
            switch try ConnectionManagement.actionRoute(action, occurrence: target) {
            case .configuration:
                let backup = try ConnectionManagement.applyConfigurationAction(action, occurrence: target)
                message = "\(action.rawValue) saved. Reload the provider to apply it. Settings backup: \(backup.path)"
                runtime.refreshConnectionInventory()
            case .command(let next): commandPurpose = action.rawValue; command = next
            case let .provider(instructions, url): providerInstructions = instructions; providerURL = url
            }
        } catch { message = error.localizedDescription }
    }
    private func openSettings(_ occurrence: ConnectionOccurrence) {
        if occurrence.entry.kind == .plugin || occurrence.entry.parentPlugin != nil {
            let url = URL(fileURLWithPath: occurrence.entry.source)
            guard FileManager.default.fileExists(atPath: url.path) else { message = "These plugin files are no longer present. Refresh the inventory."; return }
            NSWorkspace.shared.activateFileViewerSelecting([url]); return
        }
        let url = ConnectionManagement.settingsURL(account: occurrence.account, entry: occurrence.entry)
        guard FileManager.default.fileExists(atPath: url.path) else { message = "Open the coding provider to create this account's settings."; return }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: .init()) { _, error in
            if error != nil { Task { @MainActor in message = "Could not open the settings file." } }
        }
    }
}
