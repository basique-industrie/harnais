import Domain
import Foundation

public struct T3SyncField: Codable, Sendable, Equatable, Identifiable {
    public var instanceID: String
    public var path: [String]
    public var before: String?
    public var after: String?
    public var id: String { instanceID + ":" + path.joined(separator: ".") }
    public var title: String {
        switch path.joined(separator: ".") {
        case "displayName": "Display name"
        case "enabled": "Enabled in T3"
        case "accentColor": "Account color"
        case "config.binaryPath": "CLI command"
        case "config.homePath": "Profile folder"
        case "config.shadowHomePath": "Shadow folder"
        default: "Environment: " + (path.last ?? "Unknown")
        }
    }
}

/// Only Harnais-managed, non-secret fields are retained. Credentials, model
/// choices and arbitrary environment values never enter the activity journal.
public struct T3SyncRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case planned, applied, failed, undone }
    public var id = UUID()
    public var createdAt = Date()
    public var settingsPath: String
    public var route: String
    public var status: Status = .planned
    public var undoOf: UUID?
    public var fields: [T3SyncField]
    public var createdInstances: [String]
    public var drivers: [String: String]
    public var hasUnrecordedChanges: Bool
    public var instanceIDs: [String] { Array(Set(drivers.keys)).sorted() }
    public var canUndo: Bool { status == .applied && undoOf == nil && !hasUnrecordedChanges && !instanceIDs.isEmpty }

    static let topFields = ["displayName", "enabled", "accentColor"]
    static let configFields = ["binaryPath", "homePath", "shadowHomePath"]
    static let environmentFields = ["HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "CURSOR_CONFIG_DIR", "XDG_CONFIG_HOME", "AGENT_CLI_CREDENTIAL_STORE"]

    public static func make(before: [String: Any], after: [String: Any], settingsURL: URL,
                            route: String, undoOf: UUID? = nil) -> T3SyncRecord {
        var fields: [T3SyncField] = []
        var created: [String] = []
        var drivers: [String: String] = [:]
        var unrecorded = false
        for id in after.keys.sorted() where id.hasPrefix("harnais_") {
            guard let next = after[id] as? [String: Any] else { continue }
            let old = before[id] as? [String: Any] ?? [:]
            if NSDictionary(dictionary: old).isEqual(to: next) { continue }
            drivers[id] = next["driver"] as? String
            if before[id] == nil { created.append(id) }
            for path in topFields.map({ [$0] }) + configFields.map({ ["config", $0] }) + environmentFields.map({ ["environment", $0] }) {
                let prior = value(in: old, path: path)
                let desired = value(in: next, path: path)
                if prior != desired {
                    if prior == nil && rawValue(in: old, path: path) != nil { unrecorded = true }
                    fields.append(T3SyncField(instanceID: id, path: path, before: prior, after: desired))
                }
            }
            // Rebuild just the allowed changes. Any remaining difference means
            // this sync changed something we cannot safely store or undo.
            var reconstructed = old
            if before[id] == nil { reconstructed["driver"] = next["driver"] }
            for field in fields where field.instanceID == id { set(field.after, path: field.path, in: &reconstructed) }
            if normalized(reconstructed) != normalized(next) { unrecorded = true }
        }
        return T3SyncRecord(settingsPath: settingsURL.path, route: route, undoOf: undoOf,
                            fields: fields, createdInstances: created, drivers: drivers,
                            hasUnrecordedChanges: unrecorded)
    }

    /// Refuse changed fields and missing/replaced profiles. Preserve all other
    /// current settings. Never remove an ID that conversations can refer to.
    public func undo(in current: [String: Any]) throws -> [String: Any] {
        guard canUndo else { throw HarnaisError.processFailed("This sync cannot be undone.") }
        var result = current
        for id in instanceIDs {
            guard id.hasPrefix("harnais_"), var instance = current[id] as? [String: Any], instance["driver"] as? String == drivers[id] else {
                throw HarnaisError.processFailed("The T3 profile has changed since this sync. Undo was cancelled.")
            }
            let changes = fields.filter { $0.instanceID == id }
            for field in changes {
                guard Self.allowed(field.path), Self.value(in: instance, path: field.path) == field.after,
                      field.after != nil || Self.rawValue(in: instance, path: field.path) == nil else {
                    throw HarnaisError.processFailed("T3 settings changed after this sync (\(field.title)). Undo was cancelled.")
                }
            }
            if createdInstances.contains(id) {
                instance["enabled"] = false
            } else {
                for field in changes { Self.set(field.before, path: field.path, in: &instance) }
            }
            result[id] = instance
        }
        return result
    }

    private static func allowed(_ path: [String]) -> Bool {
        if path.count == 1 { return topFields.contains(path[0]) }
        guard path.count == 2 else { return false }
        return path[0] == "config" ? configFields.contains(path[1]) : path[0] == "environment" && environmentFields.contains(path[1])
    }

    private static func rawValue(in instance: [String: Any], path: [String]) -> Any? {
        if path.count == 1 { return instance[path[0]] }
        if path[0] == "config" { return (instance["config"] as? [String: Any])?[path[1]] }
        let entries = (instance["environment"] as? [[String: Any]] ?? []).filter { $0["name"] as? String == path[1] }
        return entries.isEmpty ? nil : entries
    }

    private static func value(in instance: [String: Any], path: [String]) -> String? {
        if path.count == 1 {
            if path[0] == "enabled" { return (instance[path[0]] as? Bool).map { $0 ? "true" : "false" } }
            return instance[path[0]] as? String
        }
        if path[0] == "config" { return (instance["config"] as? [String: Any])?[path[1]] as? String }
        let entries = (instance["environment"] as? [[String: Any]] ?? []).filter { $0["name"] as? String == path[1] }
        guard entries.count == 1, let entry = entries.first,
              entry["sensitive"] as? Bool != true, entry["valueRedacted"] as? Bool != true,
              Set(entry.keys).isSubset(of: ["name", "value", "sensitive", "valueRedacted"])
        else { return nil }
        return entry["value"] as? String
    }

    private static func set(_ value: String?, path: [String], in instance: inout [String: Any]) {
        if path.count == 1 {
            instance[path[0]] = path[0] == "enabled" ? value.map { $0 == "true" } as Any? : value
        } else if path[0] == "config" {
            var config = instance["config"] as? [String: Any] ?? [:]
            config[path[1]] = value
            instance["config"] = config
        } else {
            var environment = instance["environment"] as? [[String: Any]] ?? []
            environment.removeAll { $0["name"] as? String == path[1] }
            if let value { environment.append(["name": path[1], "value": value, "sensitive": false]) }
            instance["environment"] = environment
        }
    }

    private static func normalized(_ value: [String: Any]) -> NSDictionary {
        var result = value
        if let config = result["config"] as? [String: Any], config.isEmpty { result["config"] = nil }
        if var env = result["environment"] as? [[String: Any]] {
            env = env.map { entry in
                var entry = entry
                if entry["sensitive"] as? Bool == false { entry["sensitive"] = nil }
                if entry["valueRedacted"] as? Bool == false { entry["valueRedacted"] = nil }
                return entry
            }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
            result["environment"] = env.isEmpty ? nil : env
        }
        return NSDictionary(dictionary: result)
    }
}
