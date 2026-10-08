import CryptoKit
import Domain
import Foundation

public struct T3SyncPreview: Sendable, Identifiable {
    public enum Action: Sendable { case sync([Account], T3InstanceChanges), undo(UUID) }
    public let id = UUID()
    public let createdAt = Date()
    public var action: Action
    public var records: [T3SyncRecord]
    public var fingerprints: [String: String]
    public var isUndo: Bool { if case .undo = action { return true }; return false }
    public var hasChanges: Bool { records.contains { !$0.instanceIDs.isEmpty } }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func validate(_ expected: [String: String]) throws {
        for (path, hash) in expected {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), fingerprint(data) == hash else {
                throw HarnaisError.processFailed("T3 settings changed since this preview. Preview again before applying.")
            }
        }
    }
}

extension T3Exporter {
    public func preview(accounts: [Account], changes: T3InstanceChanges = T3InstanceChanges()) throws -> T3SyncPreview {
        let urls = settingsURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { throw HarnaisError.t3SettingsMissing }
        var records: [T3SyncRecord] = []
        var fingerprints: [String: String] = [:]
        for url in urls {
            let before = try Data(contentsOf: url)
            let after = try mergedSettings(accounts: accounts, data: before, changes: changes)
            records.append(T3SyncRecord.make(before: try Self.instances(before), after: try Self.instances(after),
                                             settingsURL: url, route: T3Server.running(settingsURL: url) == nil ? "file" : "server"))
            fingerprints[url.path] = T3SyncPreview.fingerprint(before)
        }
        return T3SyncPreview(action: .sync(accounts, changes), records: records, fingerprints: fingerprints)
    }

    public func previewUndo(_ id: UUID) throws -> T3SyncPreview {
        let record = try undoRecord(id)
        let url = URL(fileURLWithPath: record.settingsPath)
        let before = try Data(contentsOf: url)
        let instances = try Self.instances(before)
        let after = try record.undo(in: instances)
        let reverse = T3SyncRecord.make(before: instances, after: after, settingsURL: url,
                                       route: T3Server.running(settingsURL: url) == nil ? "file" : "server", undoOf: id)
        return T3SyncPreview(action: .undo(id), records: [reverse], fingerprints: [url.path: T3SyncPreview.fingerprint(before)])
    }

    @discardableResult
    public func apply(_ preview: T3SyncPreview) async throws -> T3SyncRoute {
        try T3SyncPreview.validate(preview.fingerprints)
        switch preview.action {
        case .sync(let accounts, let changes):
            let currentTargets = Set(settingsURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path))
            guard currentTargets == Set(preview.fingerprints.keys) else {
                throw HarnaisError.processFailed("The T3 destinations changed. Preview again before applying.")
            }
            return try await sync(accounts: accounts, changes: changes, expectations: preview.fingerprints)
        case .undo(let id):
            let record = try undoRecord(id)
            let url = URL(fileURLWithPath: record.settingsPath)
            let route: T3SyncRoute
            if let server = T3Server.running(settingsURL: url) {
                // Undo never falls back after a server error: its state must be
                // unambiguous before any recovery operation is attempted again.
                try await updateThroughServer(server, settingsURL: url, expectations: preview.fingerprints, undoOf: id) {
                    try record.undo(in: $0)
                }
                route = .server
            } else {
                let before = try Data(contentsOf: url)
                var root = try Self.root(before)
                root["providerInstances"] = try record.undo(in: try Self.instances(before))
                let after = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
                try writeFiles([(url: url, original: before, output: after)], expectations: preview.fingerprints, undoOf: id)
                route = .file
            }
            try journal?.mark(id, status: .undone)
            return route
        }
    }

    private func undoRecord(_ id: UUID) throws -> T3SyncRecord {
        guard let record = try journal?.records().first(where: { $0.id == id }), record.canUndo,
              settingsURLs.contains(where: { $0.standardizedFileURL.path == record.settingsPath }) else {
            throw HarnaisError.processFailed("This sync is no longer available for undo.")
        }
        return record
    }
    static func root(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["providerInstances"] == nil || root["providerInstances"] is [String: Any] else {
            throw HarnaisError.t3SettingsInvalid
        }
        return root
    }
    static func instances(_ data: Data) throws -> [String: Any] { try root(data)["providerInstances"] as? [String: Any] ?? [:] }
}
