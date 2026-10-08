import Domain
import Foundation
import Infrastructure

enum AccountColorTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        var account = Account(provider: .cursor, label: "Work", slug: "work", homePath: root.appendingPathComponent("cursor-work").path)
        let originalID = account.id
        let originalT3ID = account.t3InstanceID
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as! [String: Any]
        old.removeValue(forKey: "accentColor")
        old.removeValue(forKey: "managesT3Color")
        let decoded = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: old))
        expect(decoded.color == nil && decoded.managesT3Color == nil, "legacy account needs no color migration")
        let registry = AccountRegistry(fileURL: root.appendingPathComponent("color-accounts.json"))
        account.accentColor = "violet"
        try registry.add(account)
        var renamed = try registry.accounts()[0]
        renamed.label = "Work renamed"
        try registry.update(renamed)
        let saved = try registry.accounts()[0]
        expect(saved.id == originalID && saved.t3InstanceID == originalT3ID && saved.color == .violet,
               "color and identities survive save, reload and rename")
        let exporter = T3Exporter(settingsURLs: [], homeDirectory: root, cursorUsesSDK: true)
        let existing: [String: Any] = [account.t3InstanceID: [
            "driver": "cursor", "displayName": "Custom", "accentColor": "#123456", "enabled": false,
            "config": ["model": "chosen", "apiKey": "test-secret"], "customField": true
        ]]
        let unmanaged = try exporter.mergedProviderInstances(accounts: [account], into: existing)[account.t3InstanceID] as! [String: Any]
        expect(unmanaged["accentColor"] as? String == "#123456", "ordinary sync preserves custom T3 colors")
        expect(exporter.instance(for: account).accentColor == nil, "colors are not exported without opt-in")
        account.managesT3Color = true
        let managed = try exporter.mergedProviderInstances(accounts: [account], into: existing)[account.t3InstanceID] as! [String: Any]
        expect(managed["accentColor"] as? String == AccountColor.violet.hex, "explicit color management updates T3")
        expect((managed["config"] as? [String: String])?["apiKey"] == "test-secret"
               && (managed["config"] as? [String: String])?["model"] == "chosen"
               && managed["enabled"] as? Bool == false && managed["customField"] as? Bool == true,
               "color sync preserves credentials, models, flags and unknown fields")
        let snippet = try JSONSerialization.jsonObject(with: Data(exporter.snippetJSON(for: account).utf8)) as! [String: Any]
        expect((snippet[account.t3InstanceID] as? [String: Any])?["accentColor"] as? String == AccountColor.violet.hex,
               "manual JSON export includes opted-in color")
        account.accentColor = nil
        let cleared = try exporter.mergedProviderInstances(accounts: [account], into: existing)[account.t3InstanceID] as! [String: Any]
        expect(cleared["accentColor"] == nil, "managed Default clears the T3 override")
        account.accentColor = "a-future-color"
        expect(account.color == nil, "unknown stored colors do not break account loading")
    }
}
