import AppKit
import Domain
import Infrastructure
import SwiftUI

struct SkillSelection: Identifiable {
    var shared: SharedSkill? = nil
    var group: SkillGroup? = nil
    var collection: SkillCollection? = nil
    var sharedMembers: [SharedSkill] = []
    var initialSkillID: String? = nil
    var initialTab: String = "Overview"
    var id: String { collection?.id ?? shared?.id.uuidString ?? group?.id ?? "skill" }
}

struct SkillDetailSheet: View {
    let selection: SkillSelection
    @Bindable var runtime: HarnaisRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var selectedGroup = ""
    @State private var memberSearch = ""
    @State private var shared: SharedSkill?
    @State private var importedMembers: [String: SharedSkill] = [:]
    @State private var selectedSource = ""
    @State private var text = ""
    @State private var originalText = ""
    @State private var metadata: SkillMetadata?
    @State private var tab = "Overview"
    @State private var message: String?
    @State private var removing = false
    @State private var removingLocal = false
    @State private var archived: [String: URL] = [:]
    @State private var migrationAccount: Account?
    @State private var busy = false
    @State private var confirmingClose = false
    @State private var confirmingReload = false
    private var hasUnsavedInstructions: Bool { shared != nil && text != originalText }
    private var library: SkillLibrary { SkillLibrary(identity: runtime.identity) }
    private var fileManager: SkillFileManagement { SkillFileManagement(library: library) }
    private var members: [SkillGroup] { selection.collection?.groups ?? selection.group.map { [$0] } ?? [] }
    private var group: SkillGroup? { members.first { $0.id == selectedGroup } ?? members.first }
    private var source: SkillInstallation? {
        guard let selected = group?.installations.first(where: { $0.id == selectedSource }) ?? group?.installations.first else { return nil }
        return runtime.skillInventory.entries.first { $0.id == selected.id } ?? selected
    }
    private var name: String { shared?.name ?? group?.name ?? "Skill" }
    private var title: String { SkillGroup.displayTitle(name) }
    private var file: URL? { shared.map { library.directory($0).appendingPathComponent("SKILL.md") } ?? source.map { URL(fileURLWithPath: $0.path) } }
    private var parent: [ConnectionOccurrence] {
        guard let source, let plugin = source.plugin else { return [] }
        return CatalogConnection.build(accounts: runtime.accounts, inventory: runtime.connectionInventory).flatMap(\.occurrences)
            .filter { $0.account.id == source.account.id && $0.entry.kind == .plugin && $0.entry.name == plugin }
    }
    private var affected: [Account] { source.map { fileManager.affectedAccounts($0, inventory: runtime.skillInventory.entries) } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                SkillMark(icon: selection.collection?.icon ?? group?.iconName ?? "text.book.closed", size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.collection?.title ?? title).font(HarnaisSheetMetrics.titleFont)
                    Text(members.count > 1 ? "\(members.count) skills · select a skill to manage" : "Instructions, configuration and account availability")
                        .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 18) {
                if members.count > 1 { memberList.frame(width: 195); Divider() }
                VStack(alignment: .leading, spacing: 14) {
                    if members.count > 1 { Text(title).font(HarnaisType.rowTitle) }
                    Picker("Skill view", selection: $tab) {
                        Text("Overview").tag("Overview")
                        Text("Instructions").tag("Instructions")
                        Text("Configuration").tag("Configuration")
                        Text("Accounts").tag("Accounts")
                    }.pickerStyle(.segmented).labelsHidden()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            switch tab {
                            case "Instructions": instructions
                            case "Configuration": configuration
                            case "Accounts": accounts
                            default: overview
                            }
                            if let message { Text(message).font(HarnaisType.control).foregroundStyle(HarnaisPalette.label).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                }.frame(maxWidth: .infinity)
            }.frame(height: 470)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                if hasUnsavedInstructions { Text("Unsaved instructions").font(HarnaisType.control).foregroundStyle(HarnaisPalette.warning) }
                Spacer()
                HarnaisButton(title: "Done", enabled: !busy, action: requestClose)
                    .keyboardShortcut(.cancelAction)
                if hasUnsavedInstructions {
                    HarnaisButton(title: "Save instructions", prominence: .primary, enabled: !busy) {
                        saveInstructions()
                    }.keyboardShortcut("s", modifiers: .command)
                }
            }
        }.padding(24).frame(width: members.count > 1 ? 960 : 760).background(HarnaisPalette.background)
            .harnaisChrome(title: selection.collection?.title ?? "Skill", kind: .sheet).toolbar(removing: .title)
            .interactiveDismissDisabled(hasUnsavedInstructions || busy)
            .alert("Save changes to \(title)?", isPresented: $confirmingClose) {
                Button("Save") { if saveInstructions() { dismiss() } }
                Button("Discard", role: .destructive) { text = originalText; dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Your instruction edits have not been saved. Discarding them keeps any account changes you already applied.")
            }
            .onAppear {
                tab = selection.initialTab
                selectedGroup = selection.initialSkillID ?? members.first?.id ?? ""
                shared = selection.shared ?? selection.sharedMembers.first { $0.name == group?.name }
                loadText()
            }
            .alert("Reload saved instructions?", isPresented: $confirmingReload) {
                Button("Reload", role: .destructive) { loadText(); message = nil }
                Button("Keep editing", role: .cancel) {}
            } message: { Text("This replaces your draft with the current file. Copy any edits you want to keep first.") }
            .confirmationDialog("Remove shared skill \(title)?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove managed links and archive skill", role: .destructive) {
                    guard let shared else { return }
                    do { try library.remove(shared); runtime.refreshConnectionInventory(); dismiss() }
                    catch { message = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Removes this skill's Harnais installations and archives its source. Other skills in this collection and independent provider copies are unaffected.") }
            .confirmationDialog("Remove local copy of \(title)?", isPresented: $removingLocal, titleVisibility: .visible) {
                if let source {
                    Button("Archive local copy", role: .destructive) {
                        do { archived[source.path] = try fileManager.archive(source); message = "Local copy archived. Use Restore to undo, or open the archive folder later."; runtime.refreshConnectionInventory() }
                        catch { message = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let source {
                    Text("\(source.path)\nThis source is listed for \(affected.count) account(s): \(affected.map { $0.provider.displayName + " · " + $0.displayLabel() }.joined(separator: ", ")).\nThe folder is archived for recovery. Other copies and plugin packages are preserved.")
                }
            }
            .confirmationDialog("Replace the identical installed copy with a shared link?", isPresented: Binding(get: { migrationAccount != nil }, set: { if !$0 { migrationAccount = nil } }), titleVisibility: .visible) {
                if let account = migrationAccount, let shared {
                    Button("Compare and migrate") {
                        do { try library.setInstalled(true, skill: shared, account: account, migrateMatchingCopy: true); message = "Identical original archived; this account now reads the shared source."; runtime.refreshConnectionInventory() }
                        catch { message = error.localizedDescription }
                        migrationAccount = nil
                    }
                }
                Button("Cancel", role: .cancel) { migrationAccount = nil }
            } message: {
                if let account = migrationAccount, let shared {
                    Text("\(account.provider.displayName) · \(account.displayLabel())\n\(library.destination(shared, account: account).path)\nThe complete folders must match. Harnais archives the original for recovery; different content is left untouched.")
                }
            }
    }
    private var memberList: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Find in collection", text: $memberSearch).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(members.filter { memberSearch.isEmpty || $0.matches(memberSearch) }) { member in
                        Button {
                            guard text == originalText else { message = "Save the current instructions before switching skills."; return }
                            selectedGroup = member.id; selectedSource = ""; message = nil
                            shared = importedMembers[member.name] ?? selection.sharedMembers.first { $0.name == member.name }
                            loadText()
                        } label: {
                            HStack(spacing: 7) {
                                SkillMark(icon: member.iconName, size: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(member.displayTitle).font(HarnaisType.control).multilineTextAlignment(.leading)
                                    Text(member.name.hasPrefix("artifact-template-") ? "Template" : "\(member.accountCount) account\(member.accountCount == 1 ? "" : "s")")
                                        .font(.system(size: 10)).foregroundStyle(HarnaisPalette.label)
                                }
                                Spacer(minLength: 0)
                            }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
                                .background(group?.id == member.id ? HarnaisPalette.muted : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(busy).accessibilityLabel("Select skill \(member.displayTitle)")
                    }
                }
            }
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(metadata?.summary ?? group?.summary ?? "Review SKILL.md to continue.").font(HarnaisType.rowTitle)
            HStack {
                LabeledContent("Origin", value: shared == nil ? source?.origin.rawValue ?? "Added" : "Shared")
                Spacer()
                if let metadata { Text("~\(metadata.estimatedTokens) instruction tokens").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label) }
            }
            if let source, shared == nil {
                LabeledContent("Provided by", value: source.plugin.map { InventoryEntry.displayName($0) } ?? source.account.provider.displayName)
                LabeledContent("Source status", value: archived[source.path] == nil ? source.state : "Archived")
            }
            if let metadata, !metadata.warnings.isEmpty {
                DisclosureGroup("Compatibility · \(metadata.warnings.count) notes") {
                    ForEach(metadata.warnings, id: \.self) { Text($0).font(HarnaisType.control).foregroundStyle(HarnaisPalette.warning).padding(.vertical, 4) }
                }
            }
            if (group?.variants ?? 0) > 1 { Text("\(group!.variants) instruction versions found. Select an installation in Configuration to inspect the right version.").font(HarnaisType.control).foregroundStyle(HarnaisPalette.warning) }
            Divider()
            if shared == nil {
                HarnaisButton(title: "Import as shared", prominence: .primary) { importSelected() }.disabled(metadata == nil || busy || source.map { archived[$0.path] != nil } == true)
                Text("Copies the complete skill folder. Review its dependencies, then choose accounts. Plugin tools and logins remain separate.").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            } else {
                HarnaisButton(title: "Configure accounts", prominence: .primary) { tab = "Accounts" }
                Text("One source for every managed installation. Edit Instructions to update the shared copy.").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            }
            Text("Token size is an estimate for SKILL.md, not measured usage. Providers may load additional resources when invoked.").font(.system(size: 11)).foregroundStyle(HarnaisPalette.label)
        }
    }
    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if shared != nil {
                TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).frame(minHeight: 320)
                    .disabled(busy)
                HarnaisButton(title: "Revert edits") { text = originalText }.disabled(!hasUnsavedInstructions || busy)
                HarnaisButton(title: "Reload saved instructions") {
                    if hasUnsavedInstructions { confirmingReload = true }
                    else { loadText(); message = nil }
                }.disabled(busy)
            } else {
                Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 14) {
            if shared == nil, let group, group.installations.count > 1 {
                Picker("Installation", selection: Binding(get: { source?.id ?? "" }, set: { selectedSource = $0; message = nil; loadText() })) {
                    ForEach(group.installations) { value in
                        Text("\(value.account.provider.displayName) · \(value.account.displayLabel()) · \(value.plugin.map { InventoryEntry.displayName($0) } ?? value.state)").tag(value.id)
                    }
                }
            }
            LabeledContent("Skill identifier", value: name).textSelection(.enabled)
            if let shared {
                LabeledContent("Managed installations", value: "\(runtime.accounts.filter { library.isInstalled(shared, account: $0) }.count) accounts")
                HStack {
                    HarnaisButton(title: "Edit instructions") { tab = "Instructions" }
                    HarnaisButton(title: "Account availability") { tab = "Accounts" }
                }
                Divider()
                Text("Remove this shared skill").font(HarnaisType.rowTitle)
                Text("Archives this source and removes its managed links. Other skills in the collection are kept.").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                HarnaisButton(title: "Remove shared skill…") { removing = true }
            } else if let source {
                if let archive = archived[source.path] {
                    Text("This local copy has been archived.").font(HarnaisType.rowTitle)
                    HStack {
                        HarnaisButton(title: "Restore local copy") {
                            do { try fileManager.restore(archive, entry: source); archived.removeValue(forKey: source.path); message = "Original restored."; runtime.refreshConnectionInventory(); loadText() }
                            catch { message = error.localizedDescription }
                        }
                        HarnaisButton(title: "Reveal archive") { NSWorkspace.shared.activateFileViewerSelecting([archive]) }
                    }
                } else if source.plugin != nil {
                    Text("Plugin configuration").font(HarnaisType.rowTitle)
                    Text("These controls affect the owning plugin, including its other skills, hooks and MCP servers. They do not remove only this skill.")
                        .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                    if !parent.isEmpty { ConnectionInstallationsView(occurrences: parent, runtime: runtime).id(source.id) }
                    else { Text("Refresh the inventory or manage this package in its provider.").font(HarnaisType.control) }
                } else if fileManager.canArchive(source) {
                    LabeledContent("Source", value: "Standalone local skill")
                    Text("This source is listed for \(affected.count) account(s). Editing or removing it affects every account that reads this folder.")
                        .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                    HStack {
                        HarnaisButton(title: "Edit source file") { editSource(source) }
                        HarnaisButton(title: "Remove local copy…") { removingLocal = true }
                    }
                    Text("Removal archives the complete folder for recovery.").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                } else {
                    Text(source.origin == .builtIn ? "Managed by the provider" : "Managed by provider sync").font(HarnaisType.rowTitle)
                    Text("Change availability or remove this skill in the provider's skill settings. Harnais keeps provider-owned files intact. Refresh after making the change.").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                    HarnaisButton(title: "Refresh status") { runtime.refreshConnectionInventory() }
                }
            }
            if let file {
                DisclosureGroup("Source files") {
                    Text(file.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(.vertical, 5)
                    HarnaisButton(title: "Reveal folder") { NSWorkspace.shared.activateFileViewerSelecting([file.deletingLastPathComponent()]) }
                }
            }
        }
    }
    private var accounts: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let shared {
                Text("Manage Harnais's installation for each account. Global or plugin copies can remain available independently.").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                ForEach(runtime.accounts) { account in accountRow(shared, account) }
            } else {
                ForEach(group?.installations ?? []) { value in
                    HStack {
                        ProviderMark(provider: value.account.provider, size: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(value.account.provider.displayName) · \(value.account.displayLabel())").font(HarnaisType.rowTitle)
                            Text("\(value.origin.rawValue) · \(archived[value.path] == nil ? value.state : "Archived")").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                        }
                        Spacer()
                        HarnaisButton(title: "Configure") { selectedSource = value.id; loadText(); tab = "Configuration" }
                    }.padding(.vertical, 7)
                }
                Text("Each installation keeps its own permissions and plugin activation. Import as shared to manage one copy across accounts.").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
            }
        }
    }
    private func editSource(_ source: SkillInstallation) {
        guard fileManager.canArchive(source) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: source.path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: .init()) { _, error in
            if error != nil { Task { @MainActor in message = "Could not open the source file." } }
        }
    }
    private func accountRow(_ skill: SharedSkill, _ account: Account) -> some View {
        let installed = library.isInstalled(skill, account: account)
        let inherited = runtime.skillInventory.entries.filter { $0.account.id == account.id && $0.name == skill.name && $0.path != library.destination(skill, account: account).appendingPathComponent("SKILL.md").path }
        let sameDirectory = runtime.accounts.filter { library.nativeDirectory($0).standardizedFileURL == library.nativeDirectory(account).standardizedFileURL }
        return HStack {
            ProviderMark(provider: account.provider, size: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(account.provider.displayName) · \(account.displayLabel())").font(HarnaisType.rowTitle)
                Text(installed ? "Managed files installed" : "No managed installation").font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                if !inherited.isEmpty { Text("Also found through \(inherited.count) inherited or plugin source(s).").font(.system(size: 11)).foregroundStyle(HarnaisPalette.warning) }
                if sameDirectory.count > 1 { Text("This directory is shared by \(sameDirectory.count) registered accounts.").font(.system(size: 11)).foregroundStyle(HarnaisPalette.warning) }
                if account.provider == .claude && account.importedDefault { Text("Cursor and OpenCode can also discover this global Claude folder.").font(.system(size: 11)).foregroundStyle(HarnaisPalette.label) }
                if account.provider == .codex && account.importedDefault { Text("Cursor can also discover this global Codex folder.").font(.system(size: 11)).foregroundStyle(HarnaisPalette.label) }
            }
            Spacer()
            HarnaisButton(title: installed ? "Disable" : library.hasConflict(skill, account: account) ? "Migrate copy…" : "Enable") {
                if !installed && library.hasConflict(skill, account: account) { migrationAccount = account; return }
                do { try library.setInstalled(!installed, skill: skill, account: account); message = installed ? "Managed link removed. Independent copies may still be available." : "Shared files installed. Reload the provider and verify the skill there."; runtime.refreshConnectionInventory() }
                catch { message = error.localizedDescription }
            }.disabled(busy)
        }.padding(.vertical, 8)
    }
    private func loadText() {
        text = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Could not read SKILL.md."
        originalText = text
        metadata = file.flatMap { try? SkillMetadata.read($0) }
    }
    private func requestClose() {
        guard !busy else { return }
        if hasUnsavedInstructions { confirmingClose = true }
        else { dismiss() }
    }
    @discardableResult
    private func saveInstructions() -> Bool {
        guard let shared, !busy else { return false }
        do {
            try library.save(shared, text: text, expectedText: originalText)
            originalText = text
            metadata = file.flatMap { try? SkillMetadata.read($0) }
            message = "Saved. Installed accounts use the updated source."
            runtime.refreshConnectionInventory()
            return true
        } catch {
            message = error.localizedDescription
            tab = "Instructions"
            return false
        }
    }
    private func importSelected() {
        guard let source else { return }
        busy = true; let library = library; let folder = URL(fileURLWithPath: source.path).deletingLastPathComponent()
        Task {
            do { shared = try await Task.detached { try library.importFolder(folder) }.value; if let shared { importedMembers[source.name] = shared }; loadText(); runtime.refreshConnectionInventory(); message = "Imported. Review the instructions, then enable accounts." }
            catch { message = error.localizedDescription }
            busy = false
        }
    }
}
