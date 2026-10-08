import Domain
import Foundation
import Infrastructure

/// Real exporter and RPC output for validation by T3's own pinned schemas.
enum T3ContractFixtures {
    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var instances: [[String: Any]] = []
        var requests: [[String: Any]] = []
        func request(_ tag: String, _ payload: [String: Any], legacy: Bool? = nil) throws {
            let text = try T3RPC.request(id: String(requests.count + 1), tag: tag,
                                         payload: JSONSerialization.data(withJSONObject: payload))
            var frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            frame["legacy"] = legacy
            requests.append(frame)
        }
        for sdk in [false, true] {
            let exporter = T3Exporter(settingsURLs: [], homeDirectory: directory, cursorUsesSDK: sdk)
            for provider in ProviderKind.allCases {
                let account = Account(provider: provider, label: "Fixture", slug: "fixture", homePath: "/tmp/harnais-contract/\(provider.rawValue)",
                                      binaryPath: "/bin/echo", accentColor: "blue", managesT3Color: true)
                let raw = try JSONSerialization.jsonObject(with: Data(exporter.snippetJSON(for: account).utf8)) as! [String: Any]
                let instance = raw[account.t3InstanceID] as! [String: Any]
                instances.append(["id": account.t3InstanceID, "sdk": sdk, "instance": instance])
                for legacy in [true, false] {
                    try request("server.updateSettings", T3SettingsUpdate.payload(
                        instanceID: account.t3InstanceID, instances: [account.t3InstanceID: instance], legacy: legacy), legacy: legacy)
                }
            }
        }
        try request("server.getSettings", [:])
        try request("server.getConfig", [:])
        try request("provider.auth.start", ["instanceId": "harnais_cursor_fixture"])
        try request("provider.auth.subscribe", ["instanceId": "harnais_cursor_fixture"])
        try request("provider.auth.cancel", ["instanceId": "harnais_cursor_fixture", "flowId": "fixture-flow"])
        let fixture: [String: Any] = ["instances": instances, "requests": requests]
        try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("harnais.json"))
    }
}
