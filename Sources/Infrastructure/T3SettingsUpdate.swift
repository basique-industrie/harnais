import Foundation

/// The Stable 0.0.45 API replaces the complete provider map. Newer builds accept
/// single-instance mutations. Both paths must verify the returned settings: older
/// Effect schemas silently discard fields they do not recognize.
public enum T3SettingsUpdate {
    public static func usesLegacyPatch(version: String?) -> Bool {
        guard let version,
              let patch = Int(version.split(separator: "-")[0].split(separator: ".").last ?? ""),
              version.hasPrefix("0.0.") else { return false }
        return patch <= 45
    }

    public static func payload(instanceID: String, instances: [String: Any], legacy: Bool) -> [String: Any] {
        if legacy { return ["patch": ["providerInstances": instances]] }
        return ["patch": [String: Any](), "providerInstanceMutation": [
            "operation": "upsert", "instanceId": instanceID, "instance": instances[instanceID] ?? [:]
        ]]
    }

    /// Compare only changed fields, allowing T3 to fill in its own defaults.
    public static func changesLanded(before: [String: Any], desired: [String: Any], actual: [String: Any]) -> Bool {
        for key in Set(before.keys).union(desired.keys) {
            let old = before[key], new = desired[key]
            if equal(old, new) { continue }
            if let next = new as? [String: Any] {
                guard let saved = actual[key] as? [String: Any],
                      changesLanded(before: old as? [String: Any] ?? [:], desired: next, actual: saved)
                else { return false }
            } else if !equal(new, actual[key]) { return false }
        }
        return true
    }

    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a = a as? NSObject, let b = b as? NSObject else { return false }
        return a == b
    }
}
