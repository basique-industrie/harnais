import Foundation
import Infrastructure

enum T3SettingsUpdateTests {
    static func run(expect: (Bool, String) -> Void) {
        let config = Data(#"{"providers":[{"instanceId":"work"}],"settings":{"providerInstances":{"work":{"driver":"claudeAgent","enabled":false,"config":{"homePath":"/work","customModels":["saved-model"]}}}}}"#.utf8)
        let instances = try? T3SettingsUpdate.providerInstances(fromConfig: config)
        let work = instances?["work"] as? [String: Any]
        expect(work?["enabled"] as? Bool == false
               && (work?["config"] as? [String: Any])?["customModels"] as? [String] == ["saved-model"],
               "settings from getConfig preserve existing profiles and user options")
        expect((try? T3SettingsUpdate.providerInstances(fromConfig: Data(#"{"settings":{"providerInstances":{}}}"#.utf8)))?.isEmpty == true,
               "an explicitly empty provider map can receive a first profile")
        for invalid in ["null", "{", #"{"providerInstances":{}}"#, #"{"settings":{}}"#,
                        #"{"settings":{"providerInstances":[]}}"#, #"{"settings":null}"#] {
            do {
                _ = try T3SettingsUpdate.providerInstances(fromConfig: Data(invalid.utf8))
                expect(false, "invalid server settings must stop sync")
            } catch T3ServerError.rejected {
                // Rejection forbids the file fallback used for an unavailable server.
            } catch {
                expect(false, "invalid server settings must reject sync without a file fallback")
            }
        }
        expect(T3SettingsUpdate.usesLegacyPatch(version: "0.0.45"), "Stable uses its full-map settings API")
        expect(!T3SettingsUpdate.usesLegacyPatch(version: "0.0.46-nightly.20261008.2813"), "Nightly uses atomic profile mutations")
        expect(!T3SettingsUpdate.usesLegacyPatch(version: "1.0.0"), "future major version uses mutations")
        let before: [String: Any] = ["profile": ["displayName": "old", "config": ["homePath": "/old", "apiKey": "redacted"]]]
        let desired: [String: Any] = ["profile": ["displayName": "new", "config": ["homePath": "/new", "apiKey": "redacted"]]]
        expect(!T3SettingsUpdate.changesLanded(before: before, desired: desired, actual: before), "ignored mutations are rejected")
        expect(T3SettingsUpdate.changesLanded(before: before, desired: desired, actual: desired), "applied mutation is recognized")
        let partial: [String: Any] = ["profile": ["displayName": "new", "config": ["homePath": "/old"]]]
        expect(!T3SettingsUpdate.changesLanded(before: before, desired: desired, actual: partial), "partially applied mutation is rejected")
        let defaults: [String: Any] = ["profile": ["displayName": "new", "enabled": true, "config": ["homePath": "/new", "apiKey": "redacted", "timeout": 30]], "other": [:]]
        expect(T3SettingsUpdate.changesLanded(before: before, desired: desired, actual: defaults), "server defaults do not make successful writes fail")
        expect(!T3SettingsUpdate.changesLanded(before: ["color": "red"], desired: [:], actual: ["color": "red"]), "ignored deletion is detected")
        expect(T3SettingsUpdate.changesLanded(before: ["color": "red"], desired: [:], actual: [:]), "successful deletion is recognized")
    }
}
