import AppKit
import Domain
import Foundation
import Infrastructure

enum T3SyncSafetyTests {
    static func verifyCopy(registry: URL, settings: URL) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let accounts = try decoder.decode(AccountRegistryDocument.self, from: Data(contentsOf: registry)).accounts
        let exporter = T3Exporter(settingsURL: settings)
        let original = try Data(contentsOf: settings)
        let preview = try exporter.mergedSettings(accounts: accounts, data: original)
        var before = try object(original)
        var after = try object(preview)
        let oldInstances = before.removeValue(forKey: "providerInstances") as! [String: Any]
        let newInstances = after.removeValue(forKey: "providerInstances") as! [String: Any]
        guard equal(before, after), Set(oldInstances.keys) == Set(newInstances.keys) else {
            throw HarnaisError.processFailed("Copy check: unexpected changes outside existing profiles.")
        }
        var renames = 0
        for key in oldInstances.keys {
            var old = oldInstances[key] as! [String: Any]
            var new = newInstances[key] as! [String: Any]
            let oldName = old.removeValue(forKey: "displayName")
            let newName = new.removeValue(forKey: "displayName")
            guard equal(old, new) else { throw HarnaisError.processFailed("Copy check: changes beyond profile names.") }
            if !equal(oldName, newName) { renames += 1 }
        }
        try exporter.apply(accounts: accounts)
        guard try Data(contentsOf: settings) == preview else { throw HarnaisError.processFailed("Copy check: apply differs from preview.") }
        try exporter.apply(accounts: accounts)
        guard try Data(contentsOf: settings) == preview else { throw HarnaisError.processFailed("Copy check: repeated sync changed settings.") }
        print("Verified copied settings: \(renames) name updates; all IDs, login paths, credentials, enabled flags and other settings unchanged. Repeated sync is a no-op.")
    }

    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let directory = root.appendingPathComponent("t3-sync-safety")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = directory.appendingPathComponent("settings.json")
        let exporter = T3Exporter(settingsURL: settings, homeDirectory: root)
        let account = Account(provider: .codex, label: "Renamed", slug: "work", homePath: "/tmp/codex-work",
                              binaryPath: "/bin/echo", env: ["CODEX_HOME": "/tmp/codex-work"])
        let original = Data(#"""
        {"theme":"dark","textGenerationModelSelection":{"instanceId":"harnais_codex_work","model":"custom"},
        "providerInstances":{
          "codex":{"driver":"codex","enabled":false,"config":{"binaryPath":"custom-codex"}},
          "harnais_codex_retired":{"driver":"codex","config":{"homePath":"/old"}},
          "harnais_codex_work":{"driver":"codex","displayName":"Old name","enabled":false,
            "config":{"enabled":false,"homePath":"/tmp/codex-work","shadowHomePath":"/old-shadow","binaryPath":"/bin/echo","customModels":[{"id":"custom"}],"futureOption":{"keep":true}},
            "environment":[{"name":"TOKEN","value":"fixture-secret","sensitive":true},{"name":"EXTRA","value":"yes"}],
            "futureField":{"keep":42}}
        }}
        """#.utf8)
        try original.write(to: settings)
        try exporter.apply(accounts: [account])
        let output = try Data(contentsOf: settings)
        let before = try object(original)
        let after = try object(output)
        let oldInstances = before["providerInstances"] as! [String: Any]
        let newInstances = after["providerInstances"] as! [String: Any]
        let updated = newInstances[account.t3InstanceID] as! [String: Any]
        let saved = oldInstances[account.t3InstanceID] as! [String: Any]
        let config = updated["config"] as! [String: Any]
        expect(updated["displayName"] as? String == "Codex Renamed", "sync updates display name without changing ID")
        expect(updated["enabled"] as? Bool == false && config["enabled"] as? Bool == false, "sync preserves disabled profiles")
        expect(config["shadowHomePath"] == nil, "sync clears an obsolete shadow login")
        expect(config["homePath"] as? String == account.homePath, "sync keeps correct login home")
        expect(equal(config["customModels"], (saved["config"] as! [String: Any])["customModels"]), "sync preserves custom models")
        expect(equal(config["futureOption"], (saved["config"] as! [String: Any])["futureOption"]), "sync preserves unknown config")
        expect(equal(updated["futureField"], saved["futureField"]), "sync preserves unknown instance fields")
        expect(equal(updated["environment"], saved["environment"]), "sync preserves secrets and custom environment")
        expect(equal(newInstances["codex"], oldInstances["codex"]), "sync preserves native provider settings")
        expect(equal(newInstances["harnais_codex_retired"], oldInstances["harnais_codex_retired"]), "sync preserves retired conversation links")
        expect(equal(after["textGenerationModelSelection"], before["textGenerationModelSelection"]) && after["theme"] as? String == "dark", "sync preserves root settings and model selections")
        let backups = directory.appendingPathComponent("harnais-backups")
        let files = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        expect(try files.count == 1 && Data(contentsOf: files[0]) == original, "sync backs up exact original bytes")
        let permissions = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
        expect(permissions?.intValue == 0o600, "backup is readable only by its owner")
        try exporter.apply(accounts: [account])
        expect((try Data(contentsOf: settings)) == output, "repeated sync leaves identical bytes")
        expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count == 1, "no-op sync does not create another backup")
        expect(try exporter.mergedSettings(accounts: [], data: output) == output, "empty account registry does not remove T3 profiles")
        var withEnvironment = account
        withEnvironment.env["EXTRA"] = "updated"
        let envResult = try object(exporter.mergedSettings(accounts: [withEnvironment], data: output))
        let envInstance = (envResult["providerInstances"] as! [String: Any])[account.t3InstanceID] as! [String: Any]
        let updatedEnvironment = envInstance["environment"] as! [[String: Any]]
        expect(updatedEnvironment.count == 2 && updatedEnvironment.first { $0["name"] as? String == "EXTRA" }?["value"] as? String == "updated", "sync updates managed environment without duplicates")
        expect(updatedEnvironment.first { $0["name"] as? String == "TOKEN" }?["sensitive"] as? Bool == true, "sync keeps unrelated sensitive environment entries")

        let blockedDirectory = directory.appendingPathComponent("backup-blocked")
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        let blockedSettings = blockedDirectory.appendingPathComponent("settings.json")
        try original.write(to: blockedSettings)
        try Data().write(to: blockedDirectory.appendingPathComponent("harnais-backups"))
        do {
            try T3Exporter(settingsURL: blockedSettings).apply(accounts: [account])
            expect(false, "sync requires a successful backup")
        } catch { expect((try Data(contentsOf: blockedSettings)) == original, "backup failure leaves settings untouched") }

        for bad in ["invalid", "[]", #"{"providerInstances":[]}"#,
                    #"{"providerInstances":{"harnais_codex_work":{"driver":"claudeAgent"}}}"#,
                    #"{"providerInstances":{"harnais_codex_work":{"driver":"codex","config":[]}}}"#,
                    #"{"providerInstances":{"harnais_codex_work":{"driver":"codex","environment":{}}}}"#] {
            let data = Data(bad.utf8)
            try data.write(to: settings)
            do { try exporter.apply(accounts: [account]); expect(false, "unsafe sync is rejected") }
            catch { expect((try Data(contentsOf: settings)) == data, "rejected sync leaves original untouched") }
        }
        let valid = directory.appendingPathComponent("valid.json")
        try original.write(to: valid)
        do {
            try T3Exporter(settingsURLs: [valid, settings]).apply(accounts: [account])
            expect(false, "all destinations validated before writing")
        } catch { expect((try Data(contentsOf: valid)) == original, "invalid second destination leaves first untouched") }

        var other = account
        other.slug = "a-b"
        var collision = account
        collision.slug = "a_b"
        do { _ = try exporter.mergedSettings(accounts: [other, collision], data: original); expect(false, "ID collision rejected") }
        catch { expect(true, "ID collision rejected") }

        // T3 environment objects carry a Bool. They cannot be decoded as [String: String].
        let native = Data(#"{"providerInstances":{"custom":{"driver":"opencode","environment":[{"name":"XDG_DATA_HOME","value":"/isolated-data","sensitive":false}],"config":{}}}}"#.utf8)
        let openCode = Account(provider: .opencode, label: "Work", slug: "work", homePath: "/isolated-data/opencode", env: ["XDG_DATA_HOME": "/isolated-data"])
        let deduped = try object(exporter.mergedSettings(accounts: [openCode], data: native))
        expect((deduped["providerInstances"] as? [String: Any])?.count == 1, "sync recognizes existing OpenCode isolation with typed environment")
    }

    static func object(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func equal(_ left: Any?, _ right: Any?) -> Bool {
        guard let left, let right else { return left == nil && right == nil }
        return NSDictionary(dictionary: ["value": left]).isEqual(to: ["value": right])
    }
}
