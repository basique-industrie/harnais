import AppKit
import Domain
import Foundation
import Infrastructure

enum WhatsAppConnectionTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let home = root.appendingPathComponent("whatsapp-test")
        let identity = AppIdentity(dataDirectory: home.appendingPathComponent("data"))
        let bridge = WhatsAppBridge(identity: identity)
        let downloads = bridge.directory.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let document = downloads.appendingPathComponent("fixture.txt")
        try Data("Received document fixture".utf8).write(to: document)
        expect(try bridge.readDocument(path: document.path, mime: "application/octet-stream")["text"] == "Received document fixture", "WhatsApp reader detects a downloaded document's type")
        let outside = home.appendingPathComponent("private.txt")
        try Data("Not a WhatsApp document".utf8).write(to: outside)
        do { _ = try bridge.readDocument(path: outside.path, mime: "text/plain"); expect(false, "WhatsApp reader rejects paths outside downloads") }
        catch { expect(true, "WhatsApp reader rejects paths outside downloads") }
        let link = downloads.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do { _ = try bridge.readDocument(path: link.path, mime: "text/plain"); expect(false, "WhatsApp reader rejects symlink escape") }
        catch { expect(true, "WhatsApp reader rejects symlink escape") }
        expect(IntegrationKind.whatsapp.authKind == .vendor && !IntegrationKind.whatsapp.needsRegisteredOAuthClient, "WhatsApp uses a linked device without an OAuth app")
        let accounts = [ProviderKind.claude, .codex, .cursor, .claude, .codex, .opencode, .codex].enumerated().map { index, provider in
            Account(provider: provider, label: "Fixture \(index)", slug: "fixture-\(index)", homePath: home.appendingPathComponent("profile-\(index)").path,
                env: provider == .opencode ? ["XDG_CONFIG_HOME": home.appendingPathComponent("profile-\(index)").path] : [:])
        }
        let connection = IntegrationConnection(kind: .whatsapp, label: "Personal", slug: "personal", mcpName: "harnais-whatsapp-personal", lastLoginAt: Date())
        let exporter = HarnessMCPExporter(homeDirectory: home, identity: identity)
        let report = try exporter.apply(connections: [connection], accounts: accounts, commandPath: identity.binDirectory.appendingPathComponent("harnais").path, previousNames: [])
        expect(report.mcpNames == [connection.mcpName], "WhatsApp exports one shared connection")
        let inventory = ConnectionInventoryReader(homeDirectory: home, identity: identity).scan(accounts: accounts, connections: [connection])
        expect(inventory.count == 7 && inventory.allSatisfy { $0.entries.contains { $0.name == connection.mcpName && $0.origin == .shared } }, "all seven accounts recognize WhatsApp as Shared")
        expect(inventory.allSatisfy { $0.entries.contains { $0.name == connection.mcpName && $0.warnings.contains { $0.contains("session is missing") } } }, "missing WhatsApp login is reported honestly")
    }
}
