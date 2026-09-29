import AppKit
import Domain
import Foundation
import Infrastructure

enum SkillLibraryTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let home = root.appendingPathComponent("skill-tests")
        let identity = AppIdentity(dataDirectory: home.appendingPathComponent("harnais"))
        let library = SkillLibrary(identity: identity, home: home)
        let source = home.appendingPathComponent("source/review-changes")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("references"), withIntermediateDirectories: true)
        let body = "---\nname: review-changes\ndescription: Review changes before committing.\n---\nRead the diff and summarize issues.\n"
        try Data(body.utf8).write(to: source.appendingPathComponent("SKILL.md"))
        try Data("Supporting reference".utf8).write(to: source.appendingPathComponent("references/guide.md"))
        let skill = try library.importFolder(source)
        expect(try library.load().count == 1, "shared skill import persists registry")
        expect(try Data(contentsOf: source.appendingPathComponent("references/guide.md")) == Data(contentsOf: library.directory(skill).appendingPathComponent("references/guide.md")), "shared skill copies supporting resources")
        expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path), "import leaves original skill")
        do { _ = try library.importFolder(source); expect(false, "duplicate shared name rejected") } catch { expect(true, "duplicate shared name rejected") }
        var accounts: [Account] = []
        for (index, provider) in [ProviderKind.claude, .claude, .codex, .codex, .codex, .cursor, .opencode].enumerated() {
            let profile = home.appendingPathComponent("profiles/\(index)")
            let env = provider == .opencode ? ["XDG_CONFIG_HOME": profile.path] : [:]
            let account = Account(provider: provider, label: "Test \(index)", slug: "test-\(index)", homePath: profile.path, env: env)
            accounts.append(account)
            try library.setInstalled(true, skill: skill, account: account)
            expect(library.isInstalled(skill, account: account), "shared skill installed for account \(index)")
            expect(try String(contentsOf: library.destination(skill, account: account).appendingPathComponent("SKILL.md"), encoding: .utf8) == body, "account \(index) resolves canonical skill content")
        }
        let inventory = SkillInventoryReader(library: library).scan(accounts: accounts, connections: [])
        expect(inventory.entries.filter { $0.sharedID == skill.id }.count == 7, "inventory discovers shared skill across seven profiles")
        expect(SkillGroup.build(inventory.entries).count == 1, "same skill grouped across providers")
        try library.save(skill, text: body + "Check tests too.\n")
        do {
            try library.save(skill, text: body + "Stale draft.\n", expectedText: body)
            expect(false, "stale skill editor cannot overwrite another edit")
        } catch {
            expect(try String(contentsOf: library.directory(skill).appendingPathComponent("SKILL.md"), encoding: .utf8) == body + "Check tests too.\n", "stale skill editor preserves newer instructions")
        }
        try library.save(skill, text: body + "Check tests too.\nMerged draft.\n", expectedText: body + "Check tests too.\n")
        expect(try String(contentsOf: library.directory(skill).appendingPathComponent("SKILL.md"), encoding: .utf8).contains("Merged draft."), "reloaded skill editor can save merged instructions")
        expect(try String(contentsOf: library.destination(skill, account: accounts[2]).appendingPathComponent("SKILL.md"), encoding: .utf8).contains("Check tests too."), "shared edit propagates through account link")
        try library.setInstalled(false, skill: skill, account: accounts[0])
        expect(!library.isInstalled(skill, account: accounts[0]) && library.isInstalled(skill, account: accounts[1]), "disable affects only target managed link")
        let collision = library.destination(skill, account: accounts[0])
        try FileManager.default.copyItem(at: source, to: collision)
        do { try library.setInstalled(true, skill: skill, account: accounts[0]); expect(false, "existing skill never overwritten") }
        catch { expect((try? FileManager.default.destinationOfSymbolicLink(atPath: collision.path)) == nil, "existing skill never overwritten") }
        do { try library.setInstalled(true, skill: skill, account: accounts[0], migrateMatchingCopy: true); expect(false, "different skill versions cannot migrate") }
        catch { expect(try String(contentsOf: collision.appendingPathComponent("SKILL.md"), encoding: .utf8) == body, "different skill versions cannot migrate") }
        try library.save(skill, text: body)
        try library.setInstalled(true, skill: skill, account: accounts[0], migrateMatchingCopy: true)
        expect(library.isInstalled(skill, account: accounts[0]), "identical existing copy migrates to shared link")
        let backups = try FileManager.default.contentsOfDirectory(at: identity.dataDirectory.appendingPathComponent("skill-backups"), includingPropertiesForKeys: nil)
        expect(backups.contains { $0.lastPathComponent.hasPrefix("migrated-") }, "migration archives original")
        // Replacing an owned path externally must never let remove delete the replacement.
        try FileManager.default.removeItem(at: collision)
        try FileManager.default.copyItem(at: source, to: collision)
        do { try library.remove(skill); expect(false, "external replacement blocks shared removal") }
        catch { expect(FileManager.default.fileExists(atPath: collision.path), "external replacement blocks shared removal") }
        try FileManager.default.removeItem(at: collision)
        try library.remove(skill)
        expect(try library.load().isEmpty, "remove updates shared registry")
        expect(accounts.allSatisfy { !library.isInstalled(skill, account: $0) }, "remove unlinks all owned accounts")
        expect(FileManager.default.fileExists(atPath: source.path), "removing shared leaves original source")
        let created = try library.create(name: "new-skill", description: "Run a simple check.", instructions: "Read the project summary.")
        expect(try SkillMetadata.read(library.directory(created).appendingPathComponent("SKILL.md")).name == "new-skill", "new shared skill valid metadata")
        do { _ = try library.create(name: "../escape", description: "No", instructions: "No"); expect(false, "skill name traversal rejected") }
        catch { expect(true, "skill name traversal rejected") }
        let bad = source.appendingPathComponent("references/external")
        try FileManager.default.createSymbolicLink(at: bad, withDestinationURL: home)
        do { _ = try library.importFolder(source); expect(false, "linked skill dependency rejected") }
        catch { expect(true, "linked skill dependency rejected") }
        try FileManager.default.removeItem(at: bad)
        try library.save(created, text: "---\nname: new-skill\ndescription: Provider tool workflow.\n---\nUse mcp__private__tool.\n")
        do { try library.setInstalled(true, skill: created, account: accounts[0]); expect(false, "provider tool dependency requires adaptation") }
        catch { expect(!library.isInstalled(created, account: accounts[0]), "provider tool dependency requires adaptation") }
        // Plugin components remain classified independently of their skill files.
        let codex = accounts[2]
        let cache = URL(fileURLWithPath: codex.homePath).appendingPathComponent("plugins/cache/official/front/1")
        try FileManager.default.createDirectory(at: cache.appendingPathComponent(".codex-plugin"), withIntermediateDirectories: true)
        try Data(#"{"name":"front","skills":"./skills/"}"#.utf8).write(to: cache.appendingPathComponent(".codex-plugin/plugin.json"))
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: cache.appendingPathComponent("skills/review-changes"))
        let entry = InventoryEntry(name: "front@official", kind: .plugin, source: cache.path, state: "Cached")
        let connections = [AccountConnectionInventory(accountID: codex.id, entries: [entry])]
        var snapshot = SkillInventoryReader(library: library).scan(accounts: [codex], connections: connections)
        expect(snapshot.entries.contains { $0.plugin == "front@official" && $0.state == "Activation unverified" }, "plugin skill retains activation uncertainty")
        expect(snapshot.extensionIDs.contains("\(codex.id)|\(entry.id)"), "skill-only plugin routed to Skills")
        try Data(#"{"mcpServers":{}}"#.utf8).write(to: cache.appendingPathComponent(".mcp.json"))
        snapshot = SkillInventoryReader(library: library).scan(accounts: [codex], connections: connections)
        expect(!snapshot.extensionIDs.contains("\(codex.id)|\(entry.id)"), "connection-bearing plugin stays in Connections")
        let missingLSP = InventoryEntry(name: "pyright-lsp@claude-plugins-official", kind: .plugin, source: home.appendingPathComponent("missing-registry.json").path, state: "Disabled")
        let lspSnapshot = SkillInventoryReader(library: library).scan(accounts: [accounts[0]], connections: [.init(accountID: accounts[0].id, entries: [missingLSP])])
        expect(lspSnapshot.extensionIDs.contains("\(accounts[0].id)|\(missingLSP.id)"), "disabled known LSP without cache remains an extension")
        // Trash must not reappear as a skill.
        let trash = library.nativeDirectory(accounts[0]).appendingPathComponent(".trash/old/review-changes")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: trash.appendingPathComponent("SKILL.md"))
        snapshot = SkillInventoryReader(library: library).scan(accounts: [accounts[0]], connections: [])
        expect(!snapshot.entries.contains { $0.path.contains(".trash") }, "skill inventory skips provider trash")
    }
}
