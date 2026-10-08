import Domain
import Foundation
import Infrastructure
import os

/// Exercise real file writes, persistence, conflicts and recovery on throwaway
/// settings. No local account registry or live T3 instance is involved.
enum T3RecoveryTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let directory = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = directory.appendingPathComponent("settings.json")
        let journal = T3SyncJournal(fileURL: directory.appendingPathComponent("history.json"))
        var exporter = T3Exporter(settingsURL: settings, homeDirectory: root)
        exporter.journal = journal
        let account = Account(provider: .codex, label: "Work", slug: "recovery", homePath: "/new-home")
        let id = account.t3InstanceID
        let original: [String: Any] = ["theme": "dark", "providerInstances": [id: [
            "driver": "codex", "displayName": "Previous", "enabled": true,
            "config": ["homePath": "/old-home", "apiKey": "NEVER-RECORD-THIS", "model": "keep"],
            "environment": [["name": "API_TOKEN", "value": "NEVER-RECORD-ENV", "sensitive": true]]
        ], "custom": ["driver": "cursor", "displayName": "Unrelated"]]]
        let data = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        try data.write(to: settings)
        let preview = try exporter.preview(accounts: [account])
        expect(try Data(contentsOf: settings) == data, "preview makes no settings change")
        expect(try journal.records().isEmpty, "preview does not create an activity entry")
        expect(preview.hasChanges, "preview identifies profile changes")
        let safe = String(decoding: try JSONEncoder().encode(preview.records), as: UTF8.self)
        expect(!safe.contains("NEVER-RECORD"), "preview and history exclude credentials")
        try run { [exporter] in _ = try await exporter.apply(preview) }
        let record = try journal.records()[0]
        expect(record.status == .applied && record.canUndo, "successful sync is persisted and undoable")
        let saved = String(decoding: try Data(contentsOf: journal.file.fileURL), as: UTF8.self)
        expect(!saved.contains("NEVER-RECORD"), "persisted journal excludes secret values")
        let permissions = try FileManager.default.attributesOfItem(atPath: journal.file.fileURL.path)[.posixPermissions] as? Int
        expect(permissions == 0o600, "journal is owner-only")
        let undo = try exporter.previewUndo(record.id)
        var after = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        after["theme"] = "light"
        try JSONSerialization.data(withJSONObject: after).write(to: settings)
        do { try run { [exporter] in _ = try await exporter.apply(undo) }; expect(false, "stale preview should fail") }
        catch { expect(true, "stale preview refuses later T3 edits") }
        let freshUndo = try exporter.previewUndo(record.id)
        try run { [exporter] in _ = try await exporter.apply(freshUndo) }
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        let restoredProfiles = restored["providerInstances"] as! [String: Any]
        let restoredProfile = restoredProfiles[id] as! [String: Any]
        expect(restored["theme"] as? String == "light", "undo preserves unrelated settings edited later")
        expect((restoredProfile["config"] as? [String: Any])?["homePath"] as? String == "/old-home", "undo restores prior home routing")
        expect((restoredProfile["config"] as? [String: Any])?["apiKey"] as? String == "NEVER-RECORD-THIS", "undo preserves T3 credentials")
        expect(try journal.records().first(where: { $0.id == record.id })?.status == .undone, "undo cannot be repeated")
        expect(try journal.records().contains(where: { $0.undoOf == record.id && $0.status == .applied }), "undo has its own activity entry")
        do { _ = try exporter.previewUndo(record.id); expect(false, "repeated undo should fail") }
        catch { expect(true, "repeated undo is rejected") }

        try exporter.apply(accounts: [account])
        let nextRecord = try journal.records().first { $0.canUndo }!
        var conflict = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        var map = conflict["providerInstances"] as! [String: Any]
        var profile = map[id] as! [String: Any]
        profile["displayName"] = "User changed it"
        map[id] = profile
        conflict["providerInstances"] = map
        try JSONSerialization.data(withJSONObject: conflict).write(to: settings)
        do { _ = try exporter.previewUndo(nextRecord.id); expect(false, "conflicting undo should fail") }
        catch { expect(true, "undo refuses a later edit to a touched field") }

        let added = Account(provider: .cursor, label: "New", slug: "new", homePath: "/new-cursor")
        try exporter.apply(accounts: [added])
        let newRecord = try journal.records().first { $0.createdInstances.contains(added.t3InstanceID) }!
        let disable = try exporter.previewUndo(newRecord.id)
        try run { [exporter] in _ = try await exporter.apply(disable) }
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        let retained = (result["providerInstances"] as! [String: Any])[added.t3InstanceID] as? [String: Any]
        expect(retained?["enabled"] as? Bool == false, "undo disables a new profile without deleting conversation IDs")

        let old: [String: Any] = [id: ["driver": "codex", "environment": [["name": "HOME", "value": "hidden", "sensitive": true]]]]
        let new: [String: Any] = [id: ["driver": "codex", "environment": [["name": "HOME", "value": "/safe", "sensitive": false]]]]
        var redacted = T3SyncRecord.make(before: old, after: new, settingsURL: settings, route: "file")
        redacted.status = .applied
        let redactedJSON = String(decoding: try JSONEncoder().encode(redacted), as: UTF8.self)
        expect(!redacted.canUndo && !redactedJSON.contains("hidden"),
               "overwritten sensitive fields are not stored or offered for undo")
        var deletion = T3SyncRecord.make(before: new, after: [id: ["driver": "codex"]], settingsURL: settings, route: "file")
        deletion.status = .applied
        do { _ = try deletion.undo(in: old); expect(false, "sensitive replacement should conflict") }
        catch { expect(true, "a secret added after sync conflicts with undo of a removed environment field") }
        let second = directory.appendingPathComponent("second-settings.json")
        var changingTargets = T3Exporter(settingsURLs: [settings, second], homeDirectory: root)
        changingTargets.journal = journal
        let reviewed = try changingTargets.preview(accounts: [account])
        try Data("{}".utf8).write(to: second)
        do { try run { [changingTargets] in _ = try await changingTargets.apply(reviewed) }; expect(false, "new destination should require review") }
        catch { expect(true, "new T3 destination invalidates the preview") }
        expect(try String(contentsOf: second, encoding: .utf8) == "{}", "unreviewed destination stays untouched")
        let falseRedaction: [String: Any] = [id: ["driver": "codex", "environment": [["name": "HOME", "value": "/old", "sensitive": false, "valueRedacted": false]]]]
        var regular = T3SyncRecord.make(before: falseRedaction, after: new, settingsURL: settings, route: "server")
        regular.status = .applied
        expect(regular.canUndo, "explicit non-redaction metadata does not block ordinary undo")
        let invalidJournal = directory.appendingPathComponent("future.json")
        try Data(#"{"version":99,"records":[]}"#.utf8).write(to: invalidJournal)
        do { _ = try T3SyncJournal(fileURL: invalidJournal).records(); expect(false, "future journal should fail") }
        catch { expect(true, "unknown history format is not overwritten") }
    }

    static func run(_ operation: @Sendable @escaping () async throws -> Void) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = OSAllocatedUnfairLock<Result<Void, Error>>(initialState: .success(()))
        Task.detached {
            do { try await operation() }
            catch { outcome.withLock { $0 = .failure(error) } }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 20) == .success else { throw HarnaisError.processFailed("Recovery test timed out") }
        try outcome.withLock { try $0.get() }
    }
}
