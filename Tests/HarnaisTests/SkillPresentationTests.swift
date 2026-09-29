import AppKit
import Domain
import Foundation
import Infrastructure

enum SkillPresentationTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let home = root.appendingPathComponent("skill-presentation-tests")
        let library = SkillLibrary(identity: AppIdentity(dataDirectory: home.appendingPathComponent("harnais")), home: home)
        let claude = Account(provider: .claude, label: "Personal", slug: "personal", homePath: home.appendingPathComponent(".claude").path)
        let codex = Account(provider: .codex, label: "Work", slug: "work", homePath: home.appendingPathComponent(".codex").path)
        func skill(_ name: String, _ account: Account = claude, plugin: String? = nil, origin: ConnectionOrigin = .added) -> SkillInstallation {
            SkillInstallation(account: account, name: name, summary: "Test skill", path: library.nativeDirectory(account).appendingPathComponent(name + "/SKILL.md").path,
                origin: origin, plugin: plugin, state: "Configured", fingerprint: "test", warnings: [], sharedID: nil)
        }
        let entries = [skill("docx"), skill("pdf"), skill("artifact-template-business-review", codex),
            skill("slack-search", plugin: "slack@claude-plugins-official"), skill("block-kit", plugin: "slack@claude-plugins-official"),
            skill("capture-tasks-from-meeting-notes", plugin: "atlassian@claude-plugins-official"),
            skill("scan", plugin: "aikido-cursor-plugin@cursor-public"), skill("setup"),
            skill("chrome-browser"), skill("control-chrome", codex, origin: .builtIn)]
        let collections = SkillCollection.build(SkillGroup.build(entries))
        let artifacts = collections.first { $0.id == "artifacts" }!
        expect(artifacts.groups.count == 3 && artifacts.accountCount == 2, "artifact collection groups provider tools and templates without inflating account count")
        expect(collections.first { $0.id == "slack" }?.groups.count == 2, "Slack collection includes Block Kit")
        expect(collections.first { $0.id == "atlassian" }?.groups.count == 1, "Atlassian membership uses plugin ownership")
        expect(collections.first { $0.id == "aikido" }?.groups.count == 1 && collections.contains { $0.id == "skill|setup" }, "generic setup skill not mistaken for Aikido")
        let browser = collections.first { $0.id == "browser" }!
        expect(browser.groups.count == 2 && browser.origin == .added && browser.originLabels == "Added + Built-in", "mixed-origin collection appears once with truthful origins")
        expect(artifacts.matches("business") && artifacts.matches("PDF") && artifacts.matches("artifacts"), "collection search matches friendly names and member names")
        expect(SkillGroup.displayTitle("artifact-template-business-review") == "Business review", "template identifier prefix hidden in display name")
        expect(SkillGroup.displayTitle("docx") == "Word documents" && SkillGroup.displayTitle("slack-api") == "Slack API", "readable titles preserve important acronyms")
        expect(collections.first { $0.id == "slack" }?.icon == "slack" && artifacts.icon == "doc.on.doc", "collection icons match content")
        expect(Set(collections.flatMap(\.groups).flatMap(\.installations).map(\.id)) == Set(entries.map(\.id)), "collection grouping loses no installation")
        expect(SkillCollection.build(SkillGroup.build([skill("sites-building"), skill("sites-hosting"), skill("sites-preview-troubleshooting")])).first?.groups.count == 3, "Sites workflow skills share one collection")
        let tool = SkillFileManagement(library: library)
        let source = library.nativeDirectory(claude).appendingPathComponent("local-review")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let body = "---\nname: local-review\ndescription: Local fixture.\n---\nReview changes.\n"
        try Data(body.utf8).write(to: source.appendingPathComponent("SKILL.md"))
        try Data("Resource".utf8).write(to: source.appendingPathComponent("reference.txt"))
        let cursor = Account(provider: .cursor, label: "Work", slug: "work", homePath: home.appendingPathComponent(".cursor").path)
        let read = SkillInventoryReader(library: library).scan(accounts: [claude, cursor], connections: [])
        let local = read.entries.first { $0.account.id == claude.id && $0.name == "local-review" }!
        expect(tool.canArchive(local), "standalone skill offers removal")
        expect(tool.affectedAccounts(local, inventory: read.entries).count == 2, "removal identifies inherited account impact")
        let backup = try tool.archive(local)
        expect(!FileManager.default.fileExists(atPath: source.path) && FileManager.default.fileExists(atPath: backup.appendingPathComponent("reference.txt").path), "local removal archives entire package")
        try tool.restore(backup, entry: local)
        expect(try String(contentsOf: source.appendingPathComponent("SKILL.md"), encoding: .utf8) == body, "local restore recovers original instructions")
        try Data((body + "Edited outside Harnais.\n").utf8).write(to: source.appendingPathComponent("SKILL.md"))
        do { _ = try tool.archive(local); expect(false, "stale inventory cannot remove changed skill") }
        catch { expect(FileManager.default.fileExists(atPath: source.path), "stale inventory cannot remove changed skill") }
        expect(!tool.canArchive(skill("skill-creator", codex, origin: .builtIn)), "builtin skills excluded from local removal")
        expect(!tool.canArchive(skill("slack-search", plugin: "slack@official")), "plugin skills excluded from local removal")
        let synced = SkillInstallation(account: claude, name: "docs", summary: "Synced", path: library.nativeDirectory(claude).appendingPathComponent("synced/docs/SKILL.md").path, origin: .added, plugin: nil, state: "Local files", fingerprint: "", warnings: [], sharedID: nil)
        expect(!tool.canArchive(synced), "provider sync ownership protected")
        let outside = home.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let alias = library.nativeDirectory(claude).appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let nested = SkillInstallation(account: claude, name: "nested", summary: "", path: alias.appendingPathComponent("nested/SKILL.md").path, origin: .added, plugin: nil, state: "Local files", fingerprint: "", warnings: [], sharedID: nil)
        expect(!tool.canArchive(nested), "linked ancestor cannot expose external folder to removal")
        // Restore cannot overwrite a newly created installation.
        try Data(body.utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let second = try tool.archive(local)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        do { try tool.restore(second, entry: local); expect(false, "restore refuses replacement path") }
        catch { expect(FileManager.default.fileExists(atPath: second.path), "restore refuses replacement path") }
    }
}

// The same seven-account layout used by the local app, with disposable settings.
