import AppKit
import Domain
import Infrastructure
import SwiftUI

struct SkillsPageView: View {
    @Bindable var runtime: HarnaisRuntime
    @Bindable var navigation: SkillsNavigation
    private var search: String { navigation.search }
    private var accountID: UUID? { navigation.accountID }
    private var section: String { navigation.section }
    @State private var selection: SkillSelection?
    @State private var package: CatalogConnection?
    @State private var creating = false
    @State private var createdSkill: SharedSkill?
    @State private var message: String?
    @State private var importing = false
    private var library: SkillLibrary { SkillLibrary(identity: runtime.identity) }
    private var groups: [SkillGroup] {
        SkillGroup.build(runtime.skillInventory.entries.filter { entry in
            (accountID == nil || entry.account.id == accountID) && entry.sharedID == nil
        })
    }
    private var packages: [CatalogConnection] {
        CatalogConnection.build(accounts: runtime.accounts, inventory: runtime.connectionInventory).compactMap { item in
            var scoped = item
            if let accountID { scoped.occurrences.removeAll { $0.account.id != accountID } }
            guard !scoped.occurrences.isEmpty,
                  scoped.occurrences.contains(where: { !(Set(runtime.skillInventory.packageComponents[$0.id] ?? []).intersection(["Skills", "Commands", "Agents", "Hooks", "Language servers"])).isEmpty }),
                  search.isEmpty || item.displayName.localizedCaseInsensitiveContains(search)
            else { return nil }
            return scoped
        }
    }
    var body: some View {
        HarnaisCanvas(title: "Skills", subtitle: "Reusable instructions, shared across your coding accounts.",
            errorMessage: message, successMessage: nil, toolbar: {
                HStack(spacing: 8) {
                    HarnaisIconButton(systemName: "arrow.clockwise", accessibilityLabel: "Refresh skills", spinning: importing || runtime.isReadingInventory) { runtime.refreshConnectionInventory() }
                        .keyboardShortcut("r", modifiers: .command)
                    HarnaisMenu(title: "Add skill", systemImage: "plus", primary: true) {
                        Button("New skill", systemImage: "square.and.pencil") { creating = true }
                        Button("Import folder…", systemImage: "folder") { chooseFolder() }
                    }.disabled(importing)
                }
            }, content: {
                HarnaisLibraryFilters(searchTitle: "Search skills", search: $navigation.search, accounts: runtime.accounts, accountID: $navigation.accountID)
                HarnaisSegmentedControl(items: ["Skills", "Extensions"], selection: $navigation.section,
                    title: { $0 == "Extensions" ? "Provider extensions" : "Skills" }, accessibilityTitle: "Library")
                if section == "Skills" {
                    // Keep uninstalled shared skills discoverable when choosing an account.
                    let shared = runtime.sharedSkills
                    let sharedGroups = shared.map { skill in
                        SkillGroup(name: skill.name, installations: runtime.skillInventory.entries.filter { $0.sharedID == skill.id })
                    }
                    let sharedCollections = SkillCollection.build(sharedGroups).filter { $0.matches(search) }
                    SettingsSection(title: "Shared", icon: AnyView(Image(systemName: "square.stack.3d.up"))) {
                        if sharedCollections.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(search.isEmpty ? "One source, selected accounts" : "No matching shared skills").font(HarnaisType.rowTitle)
                                if search.isEmpty { Text("Import a skill or choose one below to share across accounts.").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }
                        ForEach(sharedCollections) { collection in
                            collectionRow(collection, origin: .shared) {
                                selection = SkillSelection(collection: collection, sharedMembers: shared.filter { skill in collection.groups.contains { $0.name == skill.name } }, initialTab: accountID == nil ? "Overview" : "Accounts")
                            }
                        }
                    }
                    ForEach([ConnectionOrigin.added, .builtIn], id: \.self) { origin in
                        let collections = SkillCollection.build(groups).filter { $0.origin == origin && $0.matches(search) }
                        SettingsSection(title: "\(origin.rawValue) · \(collections.count) collections", icon: AnyView(Image(systemName: origin == .builtIn ? "shippingbox" : "text.book.closed"))) {
                            if collections.isEmpty { Text("No matching skills").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label).padding(16) }
                            ForEach(collections) { collection in
                                collectionRow(collection, origin: origin) { selection = SkillSelection(collection: collection, initialSkillID: collection.groups.first { $0.matches(search) }?.id) }
                            }
                        }
                    }
                    Text("Local account, inherited global and installed-plugin files are listed. Project-only and cloud-synced availability must be checked in the provider. Installed files do not prove a skill has run successfully.")
                        .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                } else {
                    Text("Plugins are packages. These extensions contain skills, commands, agents, hooks or language servers. Packages with service connections also remain in Connections.")
                        .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                    SettingsSection(title: "Provider extensions", icon: AnyView(Image(systemName: "puzzlepiece.extension"))) {
                        ForEach(packages) { item in
                            HStack {
                                ConnectionMark(name: item.name, size: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName).font(HarnaisType.rowTitle)
                                    Text(Array(Set(item.occurrences.flatMap { runtime.skillInventory.packageComponents[$0.id] ?? [] })).sorted().joined(separator: " · "))
                                        .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                                    Text(item.providerLabel + " · " + item.activationSummary).font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                                }
                                Spacer()
                                HarnaisButton(title: "Manage") { package = item }.accessibilityLabel("Manage extension \(item.displayName)")
                            }.padding(16)
                        }
                        if packages.isEmpty { Text("No matching extensions").padding(16) }
                    }
                }
                ForEach(runtime.skillInventory.warnings, id: \.self) { Text($0).foregroundStyle(HarnaisPalette.warning) }
            })
            .task { runtime.refreshConnectionInventory() }
            .sheet(item: $selection) { SkillDetailSheet(selection: $0, runtime: runtime) }
            .sheet(item: $package) { ConnectionManageSheet(item: $0, runtime: runtime) }
            .sheet(isPresented: $creating, onDismiss: {
                if let createdSkill {
                    selection = SkillSelection(shared: createdSkill, group: nil)
                    self.createdSkill = nil
                }
            }) { NewSkillSheet(runtime: runtime, onCreate: { createdSkill = $0 }) }
    }
    private func collectionRow(_ collection: SkillCollection, origin: ConnectionOrigin, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            SkillMark(icon: collection.icon)
            VStack(alignment: .leading, spacing: 5) {
                Text(collection.title).font(HarnaisType.rowTitle)
                Text(collection.summary.isEmpty ? "Shared instructions. Choose which accounts use them." : collection.summary).font(HarnaisType.control).foregroundStyle(HarnaisPalette.label).lineLimit(2)
                HStack(spacing: 6) {
                    ForEach(collection.providers) { ProviderMark(provider: $0, size: 12) }
                    Text((origin == .shared ? "Shared" : collection.originLabels) + " · " + "\(collection.groups.count) skill\(collection.groups.count == 1 ? "" : "s") · \(collection.accountCount) account\(collection.accountCount == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(HarnaisPalette.label)
                }
                if origin == .shared, let account = runtime.accounts.first(where: { $0.id == accountID }) {
                    let installed = collection.groups.filter { group in
                        group.installations.contains { $0.account.id == account.id }
                    }.count
                    Text("\(installed) of \(collection.groups.count) skills available to \(account.provider.displayName) · \(account.displayLabel())")
                        .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                }
            }
            Spacer()
            HarnaisButton(title: origin == .shared && accountID != nil ? "Manage accounts" : "Manage", action: action)
                .accessibilityLabel("Manage skill collection \(collection.title)")
        }.padding(16)
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose a folder containing SKILL.md and its supporting files."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        importing = true
        let library = library
        Task {
            do {
                let skill = try await Task.detached { try library.importFolder(folder) }.value
                runtime.refreshConnectionInventory(); selection = SkillSelection(shared: skill, group: nil); message = nil
            } catch { message = error.localizedDescription }
            importing = false
        }
    }
}
