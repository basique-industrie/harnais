import Domain
import Infrastructure
import SwiftUI

struct SyncHistoryPageView: View {
    @Bindable var runtime: HarnaisRuntime
    var body: some View {
        HarnaisCanvas(title: "Sync history", errorMessage: runtime.errorMessage ?? runtime.syncHistoryError,
                      successMessage: runtime.successMessage) {
            SettingsSection(title: "T3 configuration") {
                SettingsRow(title: "Preview before syncing", description: "Review the profiles and fields that will change. Automatic updates are also recorded here. Undo restores only managed settings; it does not change Harnais accounts or sign-in.") {
                    HarnaisButton(title: "Preview sync") { runtime.applyT3() }.disabled(runtime.isSyncingT3)
                }
            }
            if runtime.syncHistory.isEmpty {
                SettingsSection(title: "No sync activity yet") {
                    SettingsRow(title: "Changes appear after the next sync", description: "The latest 100 entries are kept locally. Syncs from older Harnais versions are not included.") { EmptyView() }
                }
            }
            ForEach(runtime.syncHistory) { record in
                SettingsSection(title: record.createdAt.formatted(date: .abbreviated, time: .standard)) {
                    SettingsRow(title: record.undoOf == nil ? "T3 sync · \(status(record))" : "Undo · \(status(record))",
                                description: detail(record), status: record.settingsPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        if record.canUndo {
                            HarnaisButton(title: "Preview undo", prominence: .ghostMuted) { runtime.previewUndo(record) }
                                .disabled(runtime.isSyncingT3)
                        }
                    }
                    ForEach(record.instanceIDs, id: \.self) { id in
                        SettingsDivider()
                        SettingsRow(title: name(id), description: record.fields.filter { $0.instanceID == id }.map(\.title).joined(separator: ", ")) {
                            Text(record.createdInstances.contains(id) ? "Added" : "Updated").font(.system(size: 11)).foregroundStyle(HarnaisPalette.label)
                        }
                    }
                }
            }
        }
        .onAppear { runtime.refreshSyncHistory() }
    }
    private func name(_ id: String) -> String {
        runtime.accounts.first { $0.t3InstanceID == id }.map { "\($0.provider.displayName) \($0.displayLabel())" } ?? id
    }
    private func status(_ record: T3SyncRecord) -> String {
        switch record.status {
        case .planned: "Interrupted or pending"
        case .applied: "Applied"
        case .failed: "Failed"
        case .undone: "Undone"
        }
    }
    private func detail(_ record: T3SyncRecord) -> String {
        if record.status == .failed || record.status == .planned { return "The operation may have stopped partway through. Check T3 before syncing again. Automatic undo is unavailable." }
        if record.hasUnrecordedChanges { return "Some changes could not be safely retained for undo. Credentials and custom environment values are excluded from this history." }
        return record.route == "server" ? "Saved through the running T3 server." : "Saved to T3 settings with a backup."
    }
}

struct T3SyncPreviewSheet: View {
    @Bindable var runtime: HarnaisRuntime
    let preview: T3SyncPreview
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(preview.isUndo ? "Preview undo" : "Preview T3 sync").font(.title2.bold())
            Text(preview.isUndo ? "Undo changes only the fields shown below. Newly added profiles are disabled so conversations keep their IDs. Later conflicting edits cancel undo."
                 : "Review the managed fields before saving. Credentials and custom environment values are not displayed.")
                .font(.callout).foregroundStyle(HarnaisPalette.label)
            if let error = runtime.errorMessage { Text(error).foregroundStyle(HarnaisPalette.warning) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview.records) { record in
                        Text(record.settingsPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(HarnaisPalette.label)
                        ForEach(record.instanceIDs, id: \.self) { id in
                            Text(runtime.accounts.first { $0.t3InstanceID == id }?.displayLabel() ?? id).font(.headline)
                            ForEach(record.fields.filter { $0.instanceID == id }) { field in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(field.title).font(.caption.bold())
                                    Text("\(field.before ?? "Not set") → \(field.after ?? "Not set")")
                                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }
                        if record.hasUnrecordedChanges {
                            Text("Some changes cannot be retained in history. Undo will not be available for this sync.")
                                .font(.caption).foregroundStyle(HarnaisPalette.warning)
                        }
                    }
                    if !preview.hasChanges { Text("Everything is already in sync.").foregroundStyle(HarnaisPalette.label) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(runtime.isSyncingT3)
                Button(preview.isUndo ? "Undo changes" : "Apply sync") { runtime.applyT3Preview(preview) }
                    .keyboardShortcut(.defaultAction).disabled(!preview.hasChanges || runtime.isSyncingT3)
            }
        }
        .padding(24).frame(width: 640, height: 540)
    }
}
