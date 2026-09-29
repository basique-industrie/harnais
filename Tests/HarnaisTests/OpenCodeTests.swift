import AppKit
import Domain
import Foundation
import Infrastructure

enum OpenCodeTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let isolation = IsolationEngine(homeDirectory: root, profilesRoot: root.appendingPathComponent("oc-profiles"))
        let plan = isolation.plan(provider: .opencode, slug: "work", importDefault: false)
        expect(plan.env["HOME"] == nil && plan.env.count == 4, "OpenCode isolates XDG paths without replacing HOME")
        let account = Account(provider: .opencode, label: "Work", slug: "work", homePath: plan.homePath, env: plan.env)
        let auth = AccountMetadata.openCodeAuthURL(for: account)
        expect(auth.path == plan.homePath + "/data/opencode/auth.json", "OpenCode auth lives in isolated data directory")
        try FileManager.default.createDirectory(at: auth.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: auth)
        expect(!AccountMetadata().appearsSignedIn(account), "empty OpenCode credentials are not signed in")
        try Data("{\"anthropic\":{\"type\":\"api\",\"key\":\"fixture\"}}".utf8).write(to: auth)
        expect(AccountMetadata().appearsSignedIn(account), "OpenCode API credentials detected")
        try Data("{\"openai\":{\"type\":\"oauth\",\"refresh\":\"fixture\"}}".utf8).write(to: auth)
        expect(AccountMetadata().appearsSignedIn(account), "OpenCode OAuth credentials detected")
        let imported = isolation.plan(provider: .opencode, slug: "default", importDefault: true)
        expect(imported.importedDefault && imported.homePath == root.appendingPathComponent(".local/share/opencode").path, "OpenCode default login import uses native data home")
        expect(ProviderKind.opencode.loginArguments == ["auth", "login"], "OpenCode login command")
        let update = BinaryUpdater.plan(provider: .opencode, binaryPath: "/tmp/opencode", realPath: "/tmp/opencode")
        expect(update?.arguments == ["upgrade"], "OpenCode native upgrade command")
        let exporter = T3Exporter(homeDirectory: root, environment: [:])
        let instance = exporter.instance(for: account)
        expect(instance.driver == "opencode" && instance.environment.contains { $0.name == "XDG_DATA_HOME" && $0.value == plan.env["XDG_DATA_HOME"] }, "T3 OpenCode export preserves isolation")
        expect(instance.config["homePath"] == nil, "T3 OpenCode export uses supported environment fields")
        let configURL = URL(fileURLWithPath: plan.env["XDG_CONFIG_HOME"]!).appendingPathComponent("opencode/opencode.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"model\":\"keep/me\",\"mcp\":{\"existing\":{\"enabled\":false}}}".utf8).write(to: configURL)
        let connection = IntegrationConnection(kind: .slack, label: "Slack", slug: "default", mcpName: "harnais-slack")
        let mcp = HarnessMCPExporter(homeDirectory: root)
        _ = try mcp.apply(connections: [connection], accounts: [account], commandPath: "/tmp/harnais", previousNames: [])
        let configJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
        let servers = configJSON["mcp"] as! [String: Any]
        let server = servers["harnais-slack"] as! [String: Any]
        expect(server["type"] as? String == "local" && server["command"] as? [String] == ["/tmp/harnais", "mcp", "serve", "harnais-slack"], "OpenCode MCP uses its native command array format")
        expect(configJSON["model"] as? String == "keep/me" && servers["existing"] != nil, "OpenCode MCP preserves unrelated config")
        _ = try mcp.apply(connections: [], accounts: [account], commandPath: "/tmp/harnais", previousNames: ["harnais-slack"])
        let cleared = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
        expect((cleared["mcp"] as? [String: Any])?["harnais-slack"] == nil, "OpenCode MCP removes disconnected entries")
        let settings = root.appendingPathComponent("opencode-t3.json")
        try Data("{\"providerInstances\":{\"opencode\":{\"driver\":\"opencode\",\"config\":{}}}}".utf8).write(to: settings)
        let t3 = T3Exporter(settingsURL: settings, homeDirectory: root)
        try t3.apply(accounts: [account])
        expect(t3.placement(of: account) == .merged, "isolated OpenCode profile is distinct from native T3 instance")
    }
}
