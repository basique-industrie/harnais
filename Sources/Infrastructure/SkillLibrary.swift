import Domain
import Foundation
import CryptoKit

public struct SkillMetadata: Sendable {
    public let name: String
    public let summary: String
    public let text: String
    public let warnings: [String]
    public var estimatedTokens: Int { max(1, (text.utf8.count + 3) / 4) }

    public static func read(_ file: URL) throws -> SkillMetadata {
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 1_000_000 else { throw HarnaisError.processFailed("The skill file is too large to preview.") }
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            throw HarnaisError.processFailed("SKILL.md needs YAML name and description fields.")
        }
        func field(_ key: String) -> String {
            guard let index = lines[1..<end].firstIndex(where: { $0.hasPrefix(key + ":") }) else { return "" }
            var value = String(lines[index].dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if ["|", ">", "|-", ">-"].contains(value) {
                value = lines[(index + 1)..<end].prefix { $0.hasPrefix(" ") || $0.isEmpty }.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            }
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
            return value
        }
        let name = field("name"), summary = field("description")
        guard !name.isEmpty, !summary.isEmpty else {
            throw HarnaisError.processFailed("The skill needs a name and description.")
        }
        var warnings: [String] = []
        if name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) == nil || name.count > 64 || name == "synced" || summary.count > 1024 {
            warnings.append("This provider's metadata needs adaptation for other providers: use a lowercase name with single hyphens and a description of at most 1024 characters.")
        }
        let dependencies = ["${CLAUDE_PLUGIN_ROOT}", "${PLUGIN_ROOT}", "${CODEX_HOME}", "mcp__", "app://", "skill://", "/opt/", "../", "context: fork", "allowed-tools:", "agent:", "!`", "disable-model-invocation:"]
        if dependencies.contains(where: { text.contains($0) }) { warnings.append("Contains provider-specific instructions or external dependencies. Review and adapt before sharing.") }
        if text.contains("/Users/") || text.contains("~/.codex") || text.contains("~/.claude") { warnings.append("References local or provider paths that may not exist in another account.") }
        let toolMetadata = file.deletingLastPathComponent().appendingPathComponent("agents/openai.yaml")
        if let declarations = try? String(contentsOf: toolMetadata, encoding: .utf8), declarations.contains("dependencies:") {
            warnings.append("Declares tool dependencies in agents/openai.yaml. Verify those tools for each provider before sharing.")
        }
        return SkillMetadata(name: name, summary: summary, text: text, warnings: warnings)
    }
}

/// One owned source folder, linked into selected native skill directories. Existing
/// installations are never overwritten or deleted to make room for a shared skill.
public struct SkillLibrary: Sendable {
    public var identity: AppIdentity
    public var home: URL
    public init(identity: AppIdentity = .current, home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.identity = identity; self.home = home }
    public var root: URL { identity.dataDirectory.appendingPathComponent("skills") }
    public var file: AtomicJSONFile { AtomicJSONFile(fileURL: identity.dataDirectory.appendingPathComponent("skills.json")) }
    public func load() throws -> [SharedSkill] {
        try file.withLock { try loadUnlocked() }
    }
    private func loadUnlocked() throws -> [SharedSkill] {
        FileManager.default.fileExists(atPath: file.fileURL.path) ? try file.readUnlocked([SharedSkill].self) : []
    }
    public func directory(_ skill: SharedSkill) -> URL { root.appendingPathComponent(skill.id.uuidString).appendingPathComponent(skill.name) }
    public func nativeDirectory(_ account: Account) -> URL {
        let path: String
        switch account.provider {
        case .codex: path = account.env["CODEX_HOME"] ?? account.shadowHomePath ?? account.homePath
        case .claude: path = account.env["CLAUDE_CONFIG_DIR"] ?? account.shadowHomePath ?? account.homePath
        case .cursor: path = account.env["CURSOR_CONFIG_DIR"] ?? account.shadowHomePath ?? account.homePath
        case .opencode: path = (account.env["XDG_CONFIG_HOME"] ?? home.appendingPathComponent(".config").path) + "/opencode"
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).appendingPathComponent("skills")
    }
    public func destination(_ skill: SharedSkill, account: Account) -> URL { nativeDirectory(account).appendingPathComponent(skill.name) }
    public func isInstalled(_ skill: SharedSkill, account: Account) -> Bool { ownsLink(destination(skill, account: account), target: directory(skill)) }
    private func ownsLink(_ link: URL, target: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil else { return false }
        return link.resolvingSymlinksInPath().standardizedFileURL.path == target.resolvingSymlinksInPath().standardizedFileURL.path
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil }
    public func importFolder(_ selected: URL) throws -> SharedSkill {
        let source = selected.resolvingSymlinksInPath()
        let metadata = try SkillMetadata.read(source.appendingPathComponent("SKILL.md"))
        guard metadata.name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil, metadata.name.count <= 64, metadata.name != "synced", source.lastPathComponent == metadata.name else { throw HarnaisError.processFailed("The folder name must match the skill name before importing.") }
        try validateTree(source)
        return try file.withLock {
            var skills = try loadUnlocked()
            guard !skills.contains(where: { $0.name == metadata.name }) else { throw HarnaisError.processFailed("A shared skill with this name already exists. Edit it or choose a different name.") }
            let skill = SharedSkill(name: metadata.name, importedFrom: source.path)
            let destination = directory(skill)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                skills.append(skill); try file.writeUnlocked(skills)
                return skill
            } catch { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()); throw error }
        }
    }
    public func create(name: String, description: String, instructions: String) throws -> SharedSkill {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Validate before using the name as a path component.
        guard name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil else { throw HarnaisError.processFailed("Use a lowercase name with single hyphens.") }
        let dir = temp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let quoted = String(decoding: try JSONSerialization.data(withJSONObject: [description]), as: UTF8.self).dropFirst().dropLast()
        try Data("---\nname: \(name)\ndescription: \(quoted)\n---\n\n\(instructions)\n".utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        return try importFolder(dir)
    }
    public func save(_ skill: SharedSkill, text: String, expectedText: String? = nil) throws {
        try file.withLock {
            guard try loadUnlocked().contains(where: { $0.id == skill.id }) else { throw HarnaisError.processFailed("This shared skill was removed. Refresh the library.") }
            try validateTree(directory(skill))
            let target = directory(skill).appendingPathComponent("SKILL.md")
            if let expectedText, try String(contentsOf: target, encoding: .utf8) != expectedText {
                throw HarnaisError.processFailed("This skill changed outside this editor. Your draft is preserved. Copy your edits, then reload the saved instructions and merge them before saving.")
            }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(text.utf8).write(to: temp); defer { try? FileManager.default.removeItem(at: temp) }
            let metadata = try SkillMetadata.read(temp)
            guard metadata.name == skill.name else { throw HarnaisError.processFailed("Keep the skill name unchanged. Import a separate skill to use a new name.") }
            let backup = identity.dataDirectory.appendingPathComponent("skill-backups/\(skill.id)/\(UUID().uuidString).md")
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: target, to: backup)
            try Data(text.utf8).write(to: target, options: .atomic)
        }
    }
    public func setInstalled(_ enabled: Bool, skill: SharedSkill, account: Account, migrateMatchingCopy: Bool = false) throws {
        try file.withLock {
            var skills = try loadUnlocked()
            guard let index = skills.firstIndex(where: { $0.id == skill.id }) else { throw HarnaisError.processFailed("Refresh the shared skill library.") }
            let target = directory(skills[index]), link = destination(skill, account: account)
            if enabled {
                let metadata = try SkillMetadata.read(target.appendingPathComponent("SKILL.md"))
                guard metadata.warnings.isEmpty else { throw HarnaisError.processFailed("Review and adapt the flagged dependencies in SKILL.md before enabling this shared copy.") }
                try validateTree(target)
                var migrated: URL?
                if exists(link) && !ownsLink(link, target: target) {
                    guard migrateMatchingCopy, (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil,
                          try treeDigest(link) == treeDigest(target) else {
                        throw HarnaisError.processFailed("A different or linked skill already exists in this account. Harnais will not overwrite it. Only an identical folder can be migrated.")
                    }
                    let backup = identity.dataDirectory.appendingPathComponent("skill-backups/migrated-\(UUID().uuidString)/\(skill.name)")
                    try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.moveItem(at: link, to: backup)
                    migrated = backup
                }
                let created = !exists(link)
                do {
                if created {
                    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                }
                if !skills[index].installedPaths.contains(link.path) { skills[index].installedPaths.append(link.path) }
                try file.writeUnlocked(skills)
                } catch {
                    if created, ownsLink(link, target: target) { try? FileManager.default.removeItem(at: link) }
                    if let migrated { try? FileManager.default.moveItem(at: migrated, to: link) }
                    throw error
                }
            } else {
                guard !exists(link) || ownsLink(link, target: target) else { throw HarnaisError.processFailed("This path belongs to another installation. Nothing was removed.") }
                let owned = ownsLink(link, target: target)
                if owned { try FileManager.default.removeItem(at: link) }
                skills[index].installedPaths.removeAll { $0 == link.path }
                do { try file.writeUnlocked(skills) }
                catch { if owned { try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target) }; throw error }
            }
        }
    }
    public func remove(_ skill: SharedSkill) throws {
        try file.withLock {
            var skills = try loadUnlocked()
            guard let current = skills.first(where: { $0.id == skill.id }) else { return }
            let target = directory(current)
            let links = current.installedPaths.map { URL(fileURLWithPath: $0) }
            guard links.allSatisfy({ !exists($0) || ownsLink($0, target: target) }) else { throw HarnaisError.processFailed("An installation was replaced outside Harnais. Resolve that path before removing the shared skill.") }
            // Archive the complete shared folder for recovery instead of deleting it.
            let archive = identity.dataDirectory.appendingPathComponent("skill-backups/removed-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
            var removed: [URL] = []
            do {
                for link in links where ownsLink(link, target: target) { try FileManager.default.removeItem(at: link); removed.append(link) }
                try FileManager.default.moveItem(at: target, to: archive)
                skills.removeAll { $0.id == current.id }; try file.writeUnlocked(skills)
            } catch {
                if exists(archive) { try? FileManager.default.moveItem(at: archive, to: target) }
                for link in removed { try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target) }
                throw error
            }
        }
    }
    public func hasConflict(_ skill: SharedSkill, account: Account) -> Bool {
        exists(destination(skill, account: account)) && !isInstalled(skill, account: account)
    }
    private func treeDigest(_ root: URL) throws -> [String: String] {
        try validateTree(root)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { throw HarnaisError.processFailed("Cannot compare skill folders.") }
        var hashes: [String: String] = [:]
        for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let relative = String(url.path.dropFirst(root.path.count))
            let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            hashes[relative] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() + ":" + String(mode & 0o111)
        }
        return hashes
    }
    private func validateTree(_ source: URL) throws {
        guard let items = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]) else { throw HarnaisError.processFailed("Cannot read the skill folder.") }
        var count = 0, bytes = 0
        for case let file as URL in items {
            count += 1
            let attributes = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
            guard attributes.isSymbolicLink != true else { throw HarnaisError.processFailed("The skill contains a linked dependency. Make its supporting files self-contained before importing.") }
            bytes += attributes.fileSize ?? 0
            guard count <= 10_000, bytes <= 50_000_000 else { throw HarnaisError.processFailed("The skill folder exceeds 50 MB or 10,000 files.") }
        }
    }
}
