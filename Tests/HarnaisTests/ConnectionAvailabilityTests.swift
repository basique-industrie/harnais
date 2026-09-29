import AppKit
import Domain
import Foundation
import Infrastructure

enum ConnectionAvailabilityTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let home = root.appendingPathComponent("availability")
        let identity = AppIdentity(dataDirectory: home.appendingPathComponent("harnais"))
        let accounts = [ProviderKind.claude, .codex, .cursor, .claude, .codex, .opencode, .codex].enumerated().map { index, provider in
            Account(provider: provider, label: "Fixture \(index)", slug: "fixture-\(index)", homePath: home.appendingPathComponent("profile-\(index)").path,
                env: provider == .opencode ? ["XDG_CONFIG_HOME": home.appendingPathComponent("profile-\(index)").path] : [:])
        }
        let exporter = HarnessMCPExporter(homeDirectory: home, identity: identity)
        var connection = IntegrationConnection(kind: .excalidraw, label: "Fixture", slug: "fixture", mcpName: "harnais-fixture")
        func configured(_ account: Account) throws -> Bool {
            let base = URL(fileURLWithPath: account.homePath)
            let path = base.appendingPathComponent(account.provider == .codex ? "config.toml" : account.provider == .claude ? ".claude.json" : account.provider == .cursor ? "mcp.json" : "opencode/opencode.json")
            let text = try String(contentsOf: path, encoding: .utf8)
            return text.contains("harnais-fixture")
        }
        let before = try JSONEncoder().encode(connection)
        expect(try JSONDecoder().decode(IntegrationConnection.self, from: before).isEnabled(for: accounts[0].id), "legacy connection defaults to enabled")
        _ = try exporter.apply(connections: [connection], accounts: accounts, commandPath: "/fixture/harnais", previousNames: [])
        expect(try accounts.allSatisfy(configured), "all seven accounts initially configured")
        for account in accounts {
            connection.excludedAccountIDs = [account.id]
            for _ in 0..<2 { _ = try exporter.apply(connections: [connection], accounts: accounts, commandPath: "/fixture/harnais", previousNames: [connection.mcpName]) }
            expect(try !configured(account), "opt-out survives repeated sync for \(account.provider.rawValue) \(account.label)")
            expect(try accounts.filter { $0.id != account.id }.allSatisfy(configured), "opt-out preserves other accounts for \(account.label)")
            let inventory = ConnectionInventoryReader(homeDirectory: home, identity: identity).scan(accounts: accounts, connections: [connection])
            let entry = inventory.first { $0.accountID == account.id }?.entries.first { $0.name == connection.mcpName }
            expect(entry?.state == "Sync off" && entry?.warnings.isEmpty == true, "intentional opt-out is not a missing-connection warning")
        }
        connection.excludedAccountIDs = nil
        _ = try exporter.apply(connections: [connection], accounts: accounts, commandPath: "/fixture/harnais", previousNames: [connection.mcpName])
        expect(try accounts.allSatisfy(configured), "re-enabling restores all seven accounts")
        var peer = accounts[2]; peer.id = UUID()
        expect(exporter.accountsSharingConfiguration(with: peer.id, accounts: accounts + [peer]) == [peer.id, accounts[2].id], "shared configuration accounts are identified together")
        connection.excludedAccountIDs = [peer.id]
        _ = try exporter.apply(connections: [connection], accounts: accounts + [peer], commandPath: "/fixture/harnais", previousNames: [connection.mcpName])
        expect(try !configured(accounts[2]), "shared-file opt-out wins over another account enable")
        let service = IntegrationService(identity: identity, homeDirectory: home)
        try service.registry.add(connection)
        let updated = try service.updateSettings(connection, label: "Fixture", mcpName: connection.mcpName, endpoint: "", token: "", clientID: "", clientSecret: "", shared: false, excludedAccountIDs: [accounts[0].id])
        let saved = try service.registry.connections()[0]
        expect(saved.excludedAccountIDs == [accounts[0].id] && saved.excludedFromApply, "account choices persist beside global pause")
        let resumed = try service.updateSettings(updated, label: "Fixture", mcpName: connection.mcpName, endpoint: "", token: "", clientID: "", clientSecret: "", shared: true)
        expect(!resumed.isEnabled(for: accounts[0].id) && resumed.isEnabled(for: accounts[1].id), "resuming global sharing preserves account opt-outs")
    }
}
