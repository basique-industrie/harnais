import Domain
import Infrastructure
import SwiftUI

struct SharedConnectionSheet: View {
    let connection: IntegrationConnection
    @Bindable var runtime: HarnaisRuntime
    var onReconnect: (IntegrationConnection) -> Void
    var onRemove: (IntegrationConnection) -> Void
    var onAppSetup: (IntegrationKind) -> Void
    var initialTab: String = "Overview"
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "Overview"
    @State private var label = ""
    @State private var serverName = ""
    @State private var endpoint = ""
    @State private var token = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var shared = true
    @State private var excludedAccountIDs: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var showInactiveProviderEntries = false
    @State private var savedDraft: Draft?
    @State private var pendingAction: LeavingAction?
    @State private var showUnsavedChanges = false

    private struct Draft: Equatable {
        var label: String
        var serverName: String
        var endpoint: String
        var token: String
        var clientID: String
        var clientSecret: String
        var shared: Bool
        var excludedAccountIDs: Set<UUID>
    }

    private enum LeavingAction {
        case dismiss
        case reconnect
        case appSetup
        case remove
    }

    private var draft: Draft {
        Draft(label: label, serverName: serverName, endpoint: endpoint, token: token,
              clientID: clientID, clientSecret: clientSecret, shared: shared,
              excludedAccountIDs: excludedAccountIDs)
    }
    private var isDirty: Bool { savedDraft.map { $0 != draft } ?? false }
    private var reconnectTitle: String {
        isDirty ? "Save and reconnect" : current.isSignedIn ? "Reconnect" : "Sign in"
    }
    private var current: IntegrationConnection { runtime.connections.first { $0.id == connection.id } ?? connection }
    private var validation: ConnectionValidationStore.Report? { ConnectionValidationStore().report(for: current) }
    private var related: [ConnectionOccurrence] {
        CatalogConnection.build(accounts: runtime.accounts, inventory: runtime.connectionInventory)
            .filter { $0.origin == .added && $0.name == current.kind.rawValue }.flatMap(\.occurrences)
    }
    private var providerInventory: SharedProviderInventory { SharedProviderInventory(occurrences: related) }
    private var warnings: [String] {
        Array(Set(runtime.connectionInventory.flatMap(\.entries).filter { $0.origin == .shared && $0.name == current.mcpName }.flatMap(\.actionableWarnings))).sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ConnectionMark(name: connection.kind.rawValue, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.kind == .custom ? current.label : connection.kind.displayName).font(HarnaisSheetMetrics.titleFont)
                    Text("Shared · \(current.label)").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                }
                Spacer()
                if connection.kind.authKind == .oauth || connection.kind == .aikido || connection.kind == .whatsapp {
                    HarnaisButton(title: reconnectTitle, prominence: current.isSignedIn ? .outline : .primary, enabled: !saving) {
                        if isDirty { save(after: .reconnect) }
                        else { onReconnect(current) }
                    }
                }
            }
            Picker("View", selection: $tab) {
                ForEach(["Overview", "Accounts", "Provider tools", "Settings"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case "Accounts": accounts
                    case "Provider tools": providerTools
                    case "Settings": settings
                    default: overview
                    }
                    if let errorMessage { Text(errorMessage).font(HarnaisType.control).foregroundStyle(HarnaisPalette.warning) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.frame(height: 380)
            HStack {
                HarnaisButton(title: "Disconnect…", role: .destructive, prominence: .ghostMuted) { requestLeaving(.remove) }
                Spacer()
                HarnaisButton(title: "Done") { requestLeaving(.dismiss) }.keyboardShortcut(.cancelAction)
                HarnaisButton(title: saving ? "Saving…" : "Save and sync", prominence: .primary, enabled: !saving) { save() }
            }
        }.padding(24).frame(width: 680).background(HarnaisPalette.background)
        .disabled(saving)
        .harnaisChrome(title: "Manage shared connection", kind: .sheet).toolbar(removing: .title)
        .interactiveDismissDisabled(isDirty || saving)
        .alert("Save changes before leaving?", isPresented: $showUnsavedChanges) {
            Button("Save and sync") {
                let action = pendingAction ?? .dismiss
                pendingAction = nil
                save(after: action)
            }
            Button("Discard changes", role: .destructive) {
                let action = pendingAction ?? .dismiss
                pendingAction = nil
                perform(action, connection: current)
            }
            Button("Keep editing", role: .cancel) { pendingAction = nil }
        } message: {
            Text("Your changes to this shared connection have not been saved.")
        }
        .onAppear {
            guard savedDraft == nil else { return }
            tab = ["Overview", "Accounts", "Provider tools", "Settings"].contains(initialTab) ? initialTab : "Overview"
            label = current.label; serverName = current.mcpName
            endpoint = current.kind == .grafana ? current.grafanaURL ?? "" : current.mcpURL.absoluteString
            shared = !current.excludedFromApply
            excludedAccountIDs = Set(current.excludedAccountIDs ?? [])
            if let tokens = try? runtime.integrations.credentials.load(for: current).oauth { clientID = tokens.clientId ?? "" }
            if clientID.isEmpty, current.kind != .custom { clientID = (try? runtime.integrations.clients.record(for: current.kind))?.clientId ?? "" }
            savedDraft = draft
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let identity = current.accountLabel { LabeledContent("Signed in as", value: identity) }
            LabeledContent("Connection", value: current.excludedFromApply ? "Sharing paused" : current.isSignedIn ? "Connected" : "Sign-in required")
            LabeledContent("Name") { TextField("Display name", text: $label).textFieldStyle(.roundedBorder).frame(maxWidth: 320) }
            Toggle("Enable sharing", isOn: $shared).toggleStyle(.switch)
            Text("Choose which accounts can use this connection in Accounts. Pausing sharing keeps those choices.")
                .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            Text("Sign in once in Harnais. Your coding accounts use a local adapter; credentials stay on this Mac. Save and sync to apply changes.")
                .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            if current.kind == .googleDrive {
                Divider()
                Text("Drive, Sheets, Docs and Slides").font(HarnaisType.rowTitle)
                Text("Read Google and Office documents, OpenDocument files, PDFs and image text. Sheets reads include all worksheets, cell addresses, values and formulas. Images and scanned PDF pages use local OCR; charts and visual layout remain in the original download.")
                    .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                Text("Edit Google Sheets cells, formulas, worksheets and formatting; update Google Docs and Slides content. Uploaded Excel, Word and PowerPoint files can be replaced after local editing while keeping their ID and link. Google limits edits to files created or explicitly authorized for Harnais; reading a file does not grant edit permission.")
                    .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                if !providerInventory.configuredConnections.isEmpty {
                    Text("A separate provider connection is still configured. Review or remove it in Provider tools after checking the shared connection.")
                        .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                    HarnaisButton(title: "View retained provider tools", prominence: .ghostMuted) { tab = "Provider tools" }
                }
            }
            if current.kind == .aikido || current.kind == .excalidraw {
                Text(current.kind == .aikido ? "Uses Aikido's macOS Keychain login." : current.localCanvas == true ? "Local canvas · mcp-excalidraw-server 2.0.0" : "Official remote server · No login required")
                    .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            }
            if current.kind == .whatsapp {
                Divider()
                Text("WhatsApp linked device").font(HarnaisType.rowTitle)
                Text("Search chats, read synced messages and exchange documents or text when you explicitly ask. Agents must resolve the recipient and follow your request. Your provider's tool permissions control sending; Harnais cannot infer your intent from a tool call.")
                    .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                Text("This unofficial client uses one local session. History can be incomplete. Documents and media can be downloaded up to 50 MB; view-once and disappearing message content is excluded. Disconnect unlinks Harnais and clears its local message cache.")
                    .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            }
            if let validation {
                let passed = validation.results.filter { $0.status == "passed" && $0.readCall == "passed" }.count
                Divider()
                Text("Last live check · \(passed) of \(validation.results.count) accounts read successfully").font(HarnaisType.rowTitle)
                Text(validation.checkedAt.formatted(date: .abbreviated, time: .shortened)).font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                HarnaisButton(title: "View account results", prominence: .ghostMuted) { tab = "Accounts" }
            }
            ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(HarnaisType.control).foregroundStyle(HarnaisPalette.warning) }
        }
    }
    private var accounts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Account availability").font(HarnaisType.rowTitle)
            Text("Choose where this connection is available, then Save and sync. Switching off removes the Harnais adapter from that account and keeps your shared login. Reload existing provider sessions to apply the change.")
                .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            if !shared { Text("Sharing is paused. Enable sharing in Overview to activate the selected accounts.").font(HarnaisType.control).foregroundStyle(HarnaisPalette.warning) }
            ForEach(runtime.accounts) { account in
                let configured = runtime.connectionInventory.first { $0.accountID == account.id }?.entries.contains { $0.name == current.mcpName && $0.state == "Shared by Harnais" } == true
                let enabled = shared && !excludedAccountIDs.contains(account.id)
                let changed = enabled != current.isEnabled(for: account.id)
                let peers = runtime.integrations.exporter.accountsSharingConfiguration(with: account.id, accounts: runtime.accounts)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        ProviderMark(provider: account.provider, size: 18)
                        Text("\(account.provider.displayName) · \(account.displayLabel())").font(HarnaisType.rowTitle)
                        Spacer()
                        Text(changed ? "Pending sync" : !enabled ? (configured ? "Sync needed" : "Off") : configured ? "Configured" : "Sync needed")
                            .font(HarnaisType.control).foregroundStyle(changed ? HarnaisPalette.warning : HarnaisPalette.label)
                        Toggle("Enable for \(account.provider.displayName) · \(account.displayLabel())", isOn: Binding(
                            get: { shared && !excludedAccountIDs.contains(account.id) },
                            set: { value in
                                if value { excludedAccountIDs.subtract(peers) }
                                else { excludedAccountIDs.formUnion(peers) }
                            }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden().disabled(!shared || saving)
                    }
                    if peers.count > 1 { Text("Shares a settings file with another registered account. These switches change together.").font(.system(size: 11)).foregroundStyle(HarnaisPalette.label) }
                    if current.readOnlyAccountIDs?.contains(account.id) == true { Text("Read-only tools").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label) }
                    if let validation, let check = validation.results.first(where: { $0.accountID == account.id }) {
                        Text("\(check.status == "passed" && check.readCall == "passed" ? "Read succeeded" : check.status == "passed" ? "Tools loaded" : "Check failed") · \(validation.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(check.status == "passed" ? HarnaisPalette.label : HarnaisPalette.warning)
                        if let query = check.queryLabel {
                            Text(query + (check.queryDurationMS.map { " · \($0) ms" } ?? "")).font(.system(size: 11)).foregroundStyle(HarnaisPalette.label)
                        }
                    } else { Text("No recorded live check").font(.system(size: 11)).foregroundStyle(HarnaisPalette.label) }
                }.padding(12).background(HarnaisPalette.muted, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private var providerTools: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Separate provider connections").font(HarnaisType.rowTitle)
            if providerInventory.configuredConnections.isEmpty {
                Label("No separate connection configured in the scanned account settings", systemImage: "checkmark.circle")
                    .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            } else {
                Text(current.kind == .googleDrive
                    ? "This separate Drive connection uses its own login. Harnais reads supported files through the shared adapter. You can remove a verified duplicate using the controls below."
                     : "These provider configurations are separate from the shared Harnais adapter. Review their identity and capabilities before retiring them.")
                    .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                ConnectionInstallationsView(occurrences: providerInventory.configuredConnections, runtime: runtime)
            }
            if !providerInventory.extensions.isEmpty {
                Divider()
                Text("Retained provider extensions").font(HarnaisType.rowTitle)
                Text("Plugins can add skills and commands without an active service connection. Their MCP settings are checked separately.")
                    .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                ConnectionInstallationsView(occurrences: providerInventory.extensions, runtime: runtime)
            }
            if !providerInventory.inactive.isEmpty {
                Divider()
                Text("Cached and disabled entries · \(providerInventory.inactive.count)").font(HarnaisType.rowTitle)
                Text("Plugin caches and disabled configurations are kept for inspection. Cached files alone do not show whether a plugin is active.")
                    .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                Toggle("Show cached and disabled entries", isOn: $showInactiveProviderEntries).toggleStyle(.switch)
                if showInactiveProviderEntries {
                    ConnectionInstallationsView(occurrences: providerInventory.inactive, runtime: runtime)
                }
            }
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adapter settings").font(HarnaisType.rowTitle)
            LabeledContent("Server name") { TextField("harnais-service", text: $serverName).textFieldStyle(.roundedBorder) }
            Text("Keep a unique server name while testing a replacement. Existing provider settings are listed in Provider tools.").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            if current.kind == .grafana || current.kind == .custom {
                LabeledContent(current.kind == .grafana ? "Grafana URL" : "MCP URL") { TextField("https://", text: $endpoint).textFieldStyle(.roundedBorder) }
            }
            if current.kind == .grafana { SecureField("New token, leave blank to keep current", text: $token).textFieldStyle(.roundedBorder) }
            else if current.kind.authKind == .oauth {
                Divider()
                Text("OAuth application").font(HarnaisType.rowTitle)
                Text("Harnais supplies its registered app when available. Change these fields only to use a different app; a change requires signing in again.")
                    .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder)
                SecureField("New client secret, leave blank to keep current", text: $clientSecret).textFieldStyle(.roundedBorder)
                LabeledContent("Callback") { Text(IntegrationOAuth.redirectURI).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                HarnaisButton(title: "App registration guide", prominence: .ghostMuted) { requestLeaving(.appSetup) }
            }
        }
    }

    private func requestLeaving(_ action: LeavingAction) {
        guard !saving else { return }
        if isDirty {
            pendingAction = action
            showUnsavedChanges = true
        } else {
            perform(action, connection: current)
        }
    }

    private func perform(_ action: LeavingAction, connection: IntegrationConnection) {
        switch action {
        case .dismiss: dismiss()
        case .reconnect: onReconnect(connection)
        case .appSetup: onAppSetup(connection.kind)
        case .remove: onRemove(connection)
        }
    }

    private func save(after action: LeavingAction = .dismiss) {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        errorMessage = nil
        do {
            let updated = try runtime.integrations.updateSettings(current, label: label, mcpName: serverName,
                endpoint: endpoint, token: token, clientID: clientID, clientSecret: clientSecret, shared: shared,
                excludedAccountIDs: Array(excludedAccountIDs).sorted { $0.uuidString < $1.uuidString })
            savedDraft = draft
            runtime.reload()
            runtime.applyMCP()
            if let message = runtime.errorMessage { errorMessage = "Settings saved. Sync needs attention: \(message)" }
            else { perform(action, connection: updated) }
        } catch { errorMessage = error.localizedDescription }
    }
}
