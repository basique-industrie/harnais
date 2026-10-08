import Domain
import Foundation
import Infrastructure

enum T3CursorSDKTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let sdkBuild = T3Build(appURL: root.appendingPathComponent("Nightly.app"), name: "Nightly",
                              version: "0.0.46-nightly.1", channel: .nightly, usesCursorSDK: true)
        let cliBuild = T3Build(appURL: root.appendingPathComponent("Stable.app"), name: "Stable",
                              version: "0.0.43", channel: .stable, usesCursorSDK: false)
        expect(!T3Installation(builds: []).usesOnlyCursorSDK, "unknown T3 installation retains CLI compatibility")
        expect(!T3Installation(builds: [cliBuild]).usesOnlyCursorSDK, "CLI T3 retains Cursor isolation")
        expect(!T3Installation(builds: [sdkBuild, cliBuild]).usesOnlyCursorSDK, "mixed T3 builds retain Cursor isolation")
        expect(T3Installation(builds: [sdkBuild]).usesOnlyCursorSDK, "SDK-only T3 omits CLI isolation")

        let directory = root.appendingPathComponent("t3-cursor-sdk")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = directory.appendingPathComponent("settings.json")
        let sdk = T3Exporter(settingsURL: settings, homeDirectory: root, cursorUsesSDK: true)
        let cli = T3Exporter(settingsURL: settings, homeDirectory: root, cursorUsesSDK: false)
        let account = Account(provider: .cursor, label: "Work", slug: "work", homePath: "/tmp/cursor-work",
                              binaryPath: "/bin/echo", env: ["CURSOR_CONFIG_DIR": "/tmp/cursor-work",
                                                          "AGENT_CLI_CREDENTIAL_STORE": "file"])
        let proposed = sdk.instance(for: account)
        expect(proposed.config.isEmpty && proposed.environment.isEmpty, "new SDK profile contains no CLI config or environment")
        expect(proposed.enabled && proposed.displayName == "Cursor Work", "new SDK profile is named and enabled")
        let cliInstance = cli.instance(for: account)
        expect(cliInstance.config["binaryPath"] == "/bin/echo", "CLI build still gets the Cursor binary")
        expect(cliInstance.environment.contains { $0.name == "CURSOR_CONFIG_DIR" }, "CLI build still gets the Cursor home")

        let original = Data(#"""
        {"theme":"dark","providerInstances":{
          "harnais_cursor_work":{"driver":"cursor","displayName":"Old name","enabled":false,
            "config":{"binaryPath":"/old/cursor-agent","customModels":[{"id":"custom"}],"futureFlag":true},
            "environment":[{"name":"CURSOR_CONFIG_DIR","value":"/tmp/cursor-work"},
              {"name":"AGENT_CLI_CREDENTIAL_STORE","value":"file"},
              {"name":"CURSOR_API_KEY","value":"fixture-key","sensitive":true},
              {"name":"CUSTOM","value":"preserve"}],"futureField":42},
          "cursor":{"driver":"cursor","config":{"unchanged":true}},
          "harnais_cursor_retired":{"driver":"cursor","enabled":false,"config":{}}
        }}
        """#.utf8)
        try original.write(to: settings)
        let auth = directory.appendingPathComponent("provider-auth/\(account.t3InstanceID)/cursor.json")
        try FileManager.default.createDirectory(at: auth.deletingLastPathComponent(), withIntermediateDirectories: true)
        let credentials = Data(#"{"apiKey":"fixture-t3-login"}"#.utf8)
        try credentials.write(to: auth)
        try sdk.apply(accounts: [account])
        let output = try Data(contentsOf: settings)
        let object = try T3SyncSafetyTests.object(output)
        let instances = object["providerInstances"] as! [String: Any]
        let saved = instances[account.t3InstanceID] as! [String: Any]
        let config = saved["config"] as! [String: Any]
        let environment = saved["environment"] as! [[String: Any]]
        expect(config["binaryPath"] == nil, "SDK migration clears the obsolete binary path")
        expect(config["customModels"] != nil && config["futureFlag"] as? Bool == true, "SDK migration preserves T3 model and unknown config")
        expect(saved["futureField"] as? Int == 42 && saved["enabled"] as? Bool == false, "SDK migration preserves extra fields and disabled state")
        expect(environment.count == 2 && environment.first?["name"] as? String == "CURSOR_API_KEY", "SDK migration removes only the two CLI variables")
        expect(environment.first?["sensitive"] as? Bool == true, "SDK migration preserves T3-owned API keys and sensitivity")
        expect(instances["harnais_cursor_retired"] != nil && instances["cursor"] != nil, "SDK migration preserves conversation IDs and built-in providers")
        expect(try Data(contentsOf: auth) == credentials, "SDK migration leaves T3's login data untouched")
        try sdk.apply(accounts: [account])
        expect(try Data(contentsOf: settings) == output, "repeated SDK sync is a no-op")
        let enabled = try T3SyncSafetyTests.object(sdk.mergedSettings(accounts: [account], data: output,
            changes: T3InstanceChanges(enable: [account.t3InstanceID])))
        let enabledInstance = (enabled["providerInstances"] as! [String: Any])[account.t3InstanceID] as! [String: Any]
        expect(enabledInstance["enabled"] as? Bool == true, "re-adding an SDK profile enables the same instance")
        try JSONSerialization.data(withJSONObject: enabled).write(to: settings)
        expect(sdk.placement(of: account) == .merged, "SDK placement matches the instance ID without CURSOR_CONFIG_DIR")
        var renamed = account
        renamed.label = "Renamed"
        expect(sdk.placement(of: renamed) == .merged, "renaming an SDK profile keeps its instance and login mapping")

        let native = Data(#"{"providerInstances":{"custom":{"driver":"cursor","config":{},"environment":[{"name":"CURSOR_CONFIG_DIR","value":"/tmp/cursor-work","sensitive":false}]}}}"#.utf8)
        let sdkInstances = try T3SyncSafetyTests.object(sdk.mergedSettings(accounts: [account], data: native))["providerInstances"] as! [String: Any]
        let cliInstances = try T3SyncSafetyTests.object(cli.mergedSettings(accounts: [account], data: native))["providerInstances"] as! [String: Any]
        expect(sdkInstances[account.t3InstanceID] != nil, "SDK credentials never deduplicate by a legacy CLI path")
        expect(cliInstances[account.t3InstanceID] == nil, "CLI credentials still deduplicate matching homes")
        let restored = try T3SyncSafetyTests.object(cli.mergedSettings(accounts: [account], data: output))["providerInstances"] as! [String: Any]
        let restoredInstance = restored[account.t3InstanceID] as! [String: Any]
        let restoredEnvironment = restoredInstance["environment"] as! [[String: Any]]
        expect(restoredEnvironment.contains { $0["name"] as? String == "CURSOR_CONFIG_DIR" }, "installing a CLI build restores profile isolation")
        expect(restoredEnvironment.contains { $0["name"] as? String == "CURSOR_API_KEY" }, "restoring CLI compatibility keeps T3-owned credentials")
    }
}
