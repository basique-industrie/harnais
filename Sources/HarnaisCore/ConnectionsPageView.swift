import Domain
import Infrastructure
import SwiftUI

struct ConnectionsPageView: View {
    @Bindable var runtime: HarnaisRuntime
    @Bindable var navigation: ConnectionsNavigation
    var onConnect: (IntegrationKind) -> Void
    var onReconnect: (IntegrationConnection) -> Void
    var onRemove: (IntegrationConnection) -> Void
    private var search: String { navigation.search }
    private var selectedAccount: UUID? { navigation.accountID }
    private var showBuiltIn: Bool { navigation.showBuiltIn }
    @State private var managedItem: CatalogConnection?
    @State private var registrationKind: IntegrationKind?
    @State private var managedShared: SharedConnectionSelection?
    @Environment(\.scenePhase) private var scenePhase

    private var catalog: [CatalogConnection] {
        CatalogConnection.build(accounts: runtime.accounts, inventory: runtime.connectionInventory).compactMap { item in
            guard !item.occurrences.allSatisfy({ runtime.skillInventory.extensionIDs.contains($0.id) }) else { return nil }
            var filtered = item
            if let selectedAccount { filtered.occurrences.removeAll { $0.account.id != selectedAccount } }
            guard !filtered.occurrences.isEmpty,
                  search.isEmpty || item.displayName.localizedCaseInsensitiveContains(search) || item.name.localizedCaseInsensitiveContains(search) || item.providerLabel.localizedCaseInsensitiveContains(search) || item.purpose.localizedCaseInsensitiveContains(search)
            else { return nil }
            return filtered
        }
    }

    var body: some View {
        HarnaisCanvas(title: "Connections", subtitle: "One shared login for your coding accounts.",
            errorMessage: runtime.errorMessage, successMessage: runtime.successMessage,
            toolbar: {
                HStack(spacing: 8) {
                    HarnaisIconButton(systemName: "arrow.clockwise", accessibilityLabel: "Refresh connections", spinning: runtime.isReadingInventory) { runtime.reload() }
                        .keyboardShortcut("r", modifiers: .command)
                    HarnaisMenu(title: "Add connection", systemImage: "plus", primary: true) {
                        ForEach(IntegrationKind.allCases) { kind in
                            Button(kind.displayName) { onConnect(kind) }
                        }
                        Divider()
                        Menu("Advanced: custom apps") {
                            ForEach(IntegrationKind.allCases.filter { $0.authKind == .oauth && $0 != .custom }) { kind in
                                Button(kind.displayName) { registrationKind = kind }
                            }
                        }
                    }
                }
            }, content: {
                HarnaisLibraryFilters(searchTitle: "Search connections", search: $navigation.search, accounts: runtime.accounts, accountID: $navigation.accountID)
                sharedSection
                catalogSection(.added)
                catalogSection(.builtIn)
                accountWarnings
                Text("Built-in tools come with a coding provider. Added groups installations of the same service across accounts. Shared connections use one Harnais login on this Mac. Provider approval may still be needed.")
                    .font(.system(size: 11)).foregroundStyle(HarnaisPalette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            })
        .task { runtime.refreshConnectionInventory() }
        .onChange(of: runtime.accounts.map(\.id)) { _, ids in
            if let selectedAccount, !ids.contains(selectedAccount) { navigation.accountID = nil }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { runtime.reload() } }
        .sheet(item: $registrationKind) { kind in IntegrationRegistrationSheet(kind: kind, runtime: runtime) }
        .sheet(item: $managedItem) { item in ConnectionManageSheet(item: item, runtime: runtime, onShare: { kind in managedItem = nil; onConnect(kind) }) }
        .sheet(item: $managedShared) { selection in
            SharedConnectionSheet(connection: selection.connection, runtime: runtime,
                onReconnect: { managedShared = nil; onReconnect($0) },
                onRemove: { managedShared = nil; onRemove($0) },
                onAppSetup: { kind in managedShared = nil; registrationKind = kind }, initialTab: selection.initialTab)
        }
    }

    private var sharedSection: some View {
        let connections = runtime.connections.filter {
            (search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.kind.displayName.localizedCaseInsensitiveContains(search))
        }
        return SettingsSection(title: "Shared", icon: AnyView(Image(systemName: "person.2")),
            headerAction: runtime.connections.isEmpty ? nil : AnyView(HarnaisButton(title: "Sync all", prominence: .ghostMuted) { runtime.applyMCP() }
                .help("Sync every shared connection using its saved account selections. The account filter only changes this view."))) {
            if connections.isEmpty {
                if runtime.connections.isEmpty && search.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connect once. Use it in Claude, Codex, Cursor, and OpenCode.")
                            .font(HarnaisType.rowTitle).foregroundStyle(HarnaisPalette.text)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)], alignment: .leading, spacing: 12) {
                            ForEach(IntegrationKind.allCases.filter { $0 != .custom }) { kind in
                                Button { onConnect(kind) } label: {
                                    HStack(spacing: 6) { IntegrationMark(kind: kind, size: 17); Text(kind.displayName) }
                                }.buttonStyle(.plain).font(HarnaisType.control).foregroundStyle(HarnaisPalette.accent)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                } else {
                    SettingsRow(title: "No shared connections match this search") { EmptyView() }
                }
            } else {
                ForEach(connections) { connection in
                    if connection.id != connections.first?.id { SettingsDivider() }
                    HStack(spacing: 12) {
                        ConnectionMark(name: connection.kind.rawValue, size: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.kind == .custom ? connection.label : "\(connection.kind.displayName) · \(connection.label)")
                                .font(HarnaisType.rowTitle).foregroundStyle(HarnaisPalette.text)
                            Text(sharedSubtitle(connection))
                                .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                        }
                        Spacer(minLength: 8)
                        if connection.excludedFromApply {
                            Text("Paused").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                        } else if let selectedAccount, !connection.isEnabled(for: selectedAccount) {
                            Text("Not enabled for this account").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                        } else if !connection.isSignedIn {
                            Text("Sign in needed").font(HarnaisType.control).foregroundStyle(HarnaisPalette.warning)
                        } else if runtime.connectionInventory.flatMap(\.entries).contains(where: { $0.origin == .shared && $0.name == connection.mcpName && !$0.actionableWarnings.isEmpty }) {
                            Label("Needs attention", systemImage: "exclamationmark.triangle")
                                .font(HarnaisType.control).foregroundStyle(HarnaisPalette.warning)
                        }
                        HarnaisButton(title: selectedAccount == nil ? "Manage" : "Manage access", prominence: .ghostMuted) {
                            managedShared = SharedConnectionSelection(connection: connection,
                                initialTab: selectedAccount == nil ? "Overview" : "Accounts")
                        }
                            .accessibilityLabel("Manage shared \(connection.kind.displayName) \(connection.label)")
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
        }
    }

    private func sharedSubtitle(_ connection: IntegrationConnection) -> String {
        if connection.excludedFromApply { return "Sharing paused for all accounts" }
        if let selectedAccount {
            return connection.isEnabled(for: selectedAccount)
                ? "Sharing enabled for this account"
                : "Use the existing shared login by enabling account access"
        }
        return "\(connection.kind == .excalidraw ? "Shared server" : "One login") · \(sharedCount(connection)) of \(runtime.accounts.count) accounts configured"
    }

    private func sharedCount(_ connection: IntegrationConnection) -> Int {
        runtime.connectionInventory.filter { inventory in
            inventory.entries.contains { $0.name == connection.mcpName && $0.state == "Shared by Harnais" }
        }.count
    }

    @ViewBuilder
    private func catalogSection(_ origin: ConnectionOrigin) -> some View {
        let items = catalog.filter { $0.origin == origin && $0.sharedConnection(in: runtime.connections) == nil }
        SettingsSection(title: "\(origin.rawValue) · \(items.count)",
            icon: AnyView(Image(systemName: origin == .builtIn ? "shippingbox" : "puzzlepiece.extension")),
            collapsible: origin == .builtIn && search.isEmpty,
            isExpanded: origin == .builtIn ? $navigation.showBuiltIn : .constant(true)) {
            if items.isEmpty {
                SettingsRow(title: runtime.isReadingInventory ? "Reading connections…" : "No \(origin.rawValue.lowercased()) connections found") { EmptyView() }
            } else {
                ForEach(Array(Set(items.map(\.categoryLabel))).sorted(), id: \.self) { category in
                    Text(category).font(.system(size: 11, weight: .semibold)).foregroundStyle(HarnaisPalette.label)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 12)
                    ForEach(items.filter { $0.categoryLabel == category }) { item in
                        ConnectionCatalogRow(item: item) { managedItem = item }
                        if item.id != items.last?.id { SettingsDivider() }
                    }
                }
            }
        }
    }

    private var accountWarnings: some View {
        let warnings = runtime.connectionInventory.filter { !$0.warnings.isEmpty && (selectedAccount == nil || selectedAccount == $0.accountID) }
        return Group {
            if !warnings.isEmpty {
                DisclosureGroup("Account notices · \(warnings.count)") {
                    ForEach(warnings) { inventory in
                        if let account = runtime.accounts.first(where: { $0.id == inventory.accountID }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(account.provider.displayName) · \(account.displayLabel())").font(HarnaisType.rowTitle)
                                ForEach(inventory.warnings, id: \.self) { Text($0).font(HarnaisType.control).foregroundStyle(HarnaisPalette.warning) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }
                    }
                }.font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            }
        }
    }
}

private struct SharedConnectionSelection: Identifiable {
    let connection: IntegrationConnection
    let initialTab: String
    var id: UUID { connection.id }
}
