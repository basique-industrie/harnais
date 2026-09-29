import Domain
import Foundation
import CryptoKit

/// Removal for standalone user files. Plugin, synced and built-in skill ownership
/// stays with the provider; shared skills use SkillLibrary instead.
public struct SkillFileManagement: Sendable {
    public let library: SkillLibrary
    public init(library: SkillLibrary = SkillLibrary()) { self.library = library }
    public func canArchive(_ entry: SkillInstallation) -> Bool {
        guard entry.origin == .added, entry.plugin == nil, entry.sharedID == nil else { return false }
        let file = URL(fileURLWithPath: entry.path).standardizedFileURL
        guard file.lastPathComponent == "SKILL.md" else { return false }
        let protected = [".system", "synced", ".trash", "plugins"]
        guard !file.pathComponents.contains(where: { protected.contains($0) }) else { return false }
        var roots = [library.nativeDirectory(entry.account)]
        if entry.account.provider != .claude { roots.append(library.home.appendingPathComponent(".agents/skills")) }
        if entry.account.provider == .cursor || entry.account.provider == .opencode { roots.append(library.home.appendingPathComponent(".claude/skills")) }
        if entry.account.provider == .cursor { roots.append(library.home.appendingPathComponent(".codex/skills")) }
        return roots.contains { root in
            // Resolve existing parents, not the removed leaf. Foundation can use
            // different /var and /private/var spellings once a file is absent.
            guard let parent = canonicalDirectory(file.deletingLastPathComponent().deletingLastPathComponent()),
                  let realRoot = canonicalDirectory(root),
                  parent == realRoot || parent.hasPrefix(realRoot + "/") else { return false }
            let relative = String(parent.dropFirst(realRoot.count)) + "/" + file.deletingLastPathComponent().lastPathComponent
            return !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") })
        }
    }
    private func canonicalDirectory(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func affectedAccounts(_ entry: SkillInstallation, inventory: [SkillInstallation]) -> [Account] {
        let path = URL(fileURLWithPath: entry.path).standardizedFileURL.path
        return Dictionary(grouping: inventory.filter { URL(fileURLWithPath: $0.path).standardizedFileURL.path == path }, by: { $0.account.id })
            .values.compactMap { $0.first?.account }.sorted { $0.provider.displayName + $0.label < $1.provider.displayName + $1.label }
    }
    public func archive(_ entry: SkillInstallation) throws -> URL {
        guard canArchive(entry) else { throw HarnaisError.processFailed("Manage this skill through its owning provider or shared library.") }
        return try library.file.withLock {
            let file = URL(fileURLWithPath: entry.path)
            let source = file.deletingLastPathComponent()
            let data = try Data(contentsOf: file)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == entry.fingerprint else { throw HarnaisError.processFailed("The skill changed since the inventory was read. Refresh before removing it.") }
            let backup = library.identity.dataDirectory.appendingPathComponent("skill-backups/local-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let destination = backup.appendingPathComponent(source.lastPathComponent)
            let receipt = ["originalPath": source.path, "name": entry.name]
            try JSONSerialization.data(withJSONObject: receipt, options: .prettyPrinted).write(to: backup.appendingPathComponent("restore.json"), options: .atomic)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
    }
    public func restore(_ archived: URL, entry: SkillInstallation) throws {
        guard canArchive(entry), archived.standardizedFileURL.path.hasPrefix(library.identity.dataDirectory.appendingPathComponent("skill-backups").standardizedFileURL.path + "/") else {
            throw HarnaisError.processFailed("This archive is not managed by Harnais.")
        }
        try library.file.withLock {
            let destination = URL(fileURLWithPath: entry.path).deletingLastPathComponent()
            guard !FileManager.default.fileExists(atPath: destination.path), (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
                throw HarnaisError.processFailed("A skill already exists at the original path. Nothing was overwritten.")
            }
            let receiptURL = archived.deletingLastPathComponent().appendingPathComponent("restore.json")
            let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: String]
            guard receipt?["originalPath"] == destination.path, receipt?["name"] == entry.name else {
                throw HarnaisError.processFailed("The archive does not match this installation.")
            }
            try FileManager.default.moveItem(at: archived, to: destination)
        }
    }
}
