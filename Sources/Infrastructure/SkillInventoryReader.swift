import Domain
import Foundation
import CryptoKit
import TOMLDecoder

public struct SkillInventoryReader: Sendable {
    public var library: SkillLibrary
    public init(library: SkillLibrary = SkillLibrary()) { self.library = library }

    public func scan(accounts: [Account], connections: [AccountConnectionInventory]) -> SkillInventorySnapshot {
        var result = SkillInventorySnapshot()
        let shared: [SharedSkill]
        do { shared = try library.load() } catch { result.warnings.append("The shared skill registry could not be read."); shared = [] }
        var filesByRoot: [String: [URL]] = [:]
        var metadataByPath: [String: SkillMetadata] = [:]
        var fingerprints: [String: String] = [:]
        var sharedByPath: [String: SharedSkill] = [:]
        for skill in shared {
            let path = library.directory(skill).appendingPathComponent("SKILL.md").resolvingSymlinksInPath().path
            if sharedByPath[path] == nil { sharedByPath[path] = skill }
        }
        func files(_ root: URL) -> [URL] {
            if let cached = filesByRoot[root.path] { return cached }
            let found = skillFiles(root)
            filesByRoot[root.path] = found
            return found
        }
        for account in accounts {
            var seen: Set<String> = []
            let native = library.nativeDirectory(account)
            var roots: [(URL, String, ConnectionOrigin)] = [(native, "Local files", .added)]
            if account.provider != .claude {
                roots.append((library.home.appendingPathComponent(".agents/skills"), "Inherited global files", .added))
            }
            if account.provider == .cursor || account.provider == .opencode {
                roots.append((library.home.appendingPathComponent(".claude/skills"), "Inherited Claude files", .added))
            }
            if account.provider == .cursor { roots.append((library.home.appendingPathComponent(".codex/skills"), "Inherited Codex files", .added)) }
            if account.provider == .codex {
                roots.append((native.appendingPathComponent(".system"), "Provider system files", .builtIn))
                roots.append((URL(fileURLWithPath: "/etc/codex/skills"), "Administrator files", .builtIn))
            }
            let config = native.deletingLastPathComponent().appendingPathComponent("config.toml")
            let codexConfig = account.provider == .codex ? read(config) : [:]
            let policies = (codexConfig["skills"] as? [String: Any])?["config"] as? [[String: Any]] ?? []
            let disabledPaths = Set(policies.filter { $0["enabled"] as? Bool == false }.compactMap { $0["path"] as? String }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).resolvingSymlinksInPath().path })
            func collect(_ root: URL, state: String, origin: ConnectionOrigin, plugin: String? = nil) {
                for file in files(root) {
                    let resolved = file.resolvingSymlinksInPath()
                    // Same canonical file inherited through two compatible roots is one installation.
                    guard seen.insert(resolved.path + "|" + (plugin ?? "")).inserted else { continue }
                    let metadata = metadataByPath[resolved.path] ?? (try? SkillMetadata.read(file))
                    metadataByPath[resolved.path] = metadata
                    let fingerprint = fingerprints[resolved.path] ?? SHA256.hash(data: Data((metadata?.text ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
                    fingerprints[resolved.path] = fingerprint
                    let owner = sharedByPath[resolved.path]
                    let disabled = disabledPaths.contains(resolved.path) || disabledPaths.contains(resolved.deletingLastPathComponent().path)
                    var warnings = metadata?.warnings ?? ["Invalid or unsupported SKILL.md metadata. Open the source to review it."]
                    if plugin != nil { warnings.append("Belongs to a plugin. Copying this skill does not install its other tools, hooks or agents.") }
                    result.entries.append(SkillInstallation(account: account,
                        name: metadata?.name ?? file.deletingLastPathComponent().lastPathComponent,
                        summary: metadata?.summary ?? "Could not read the skill description.", path: file.path,
                        origin: owner != nil ? .shared : origin, plugin: plugin,
                        state: disabled ? "Disabled by Codex" : state,
                        fingerprint: fingerprint, warnings: warnings, sharedID: owner?.id))
                }
            }
            for (root, state, origin) in roots { collect(root, state: state, origin: origin) }
            let entries = connections.first { $0.accountID == account.id }?.entries ?? []
            for entry in entries where entry.kind == .plugin {
                let paths = pluginRoots(entry: entry, native: native, provider: account.provider)
                if paths.isEmpty {
                    // Known language-server packages can retain disabled settings after
                    // their files are removed. Keep their controls with extensions.
                    let knownLSPs = ["clangd-lsp", "pyright-lsp", "rust-analyzer-lsp", "swift-lsp", "ty-lsp"]
                    if account.provider == .claude, knownLSPs.contains(InventoryEntry.serviceName(entry.name)),
                       !entries.contains(where: { $0.parentPlugin == entry.name }) {
                        let id = "\(account.id)|\(entry.id)"
                        result.packageComponents[id] = ["Language servers"]
                        result.extensionIDs.insert(id)
                    }
                    continue
                }
                var components: Set<String> = []
                for path in paths {
                    let manifest = pluginManifest(path)
                    var skillRoots: [URL] = []
                    let declared = manifest["skills"]
                    let relatives = (declared as? [String]) ?? (declared as? String).map { [$0] } ?? ["skills"]
                    for relative in relatives {
                        let candidate = path.appendingPathComponent(relative).standardizedFileURL
                        guard candidate.path.hasPrefix(path.standardizedFileURL.path + "/") else { continue }
                        skillRoots.append(candidate)
                    }
                    if declared == nil, FileManager.default.fileExists(atPath: path.appendingPathComponent("SKILL.md").path) { skillRoots.append(path) }
                    for skillRoot in skillRoots {
                        if !files(skillRoot).isEmpty { components.insert("Skills") }
                        collect(skillRoot, state: entry.presentationState, origin: entry.origin, plugin: entry.name)
                    }
                    for (key, folder, title) in [("commands", "commands", "Commands"), ("agents", "agents", "Agents"), ("hooks", "hooks", "Hooks"), ("lspServers", ".lsp.json", "Language servers"), ("mcpServers", ".mcp.json", "MCP"), ("apps", ".app.json", "Apps")] {
                        if manifest[key] != nil || FileManager.default.fileExists(atPath: path.appendingPathComponent(folder).path) { components.insert(title) }
                    }
                    if FileManager.default.fileExists(atPath: path.appendingPathComponent("mcp.json").path) { components.insert("MCP") }
                    if let extensions = manifest["extensions"] as? [String: [String: Any]],
                       let openai = extensions["com.openai"], openai["apps"] != nil || openai["mcpServers"] != nil { components.insert("Apps") }
                }
                if entries.contains(where: { $0.parentPlugin == entry.name }) { components.insert("MCP") }
                let occurrenceID = "\(account.id)|\(entry.id)"
                result.packageComponents[occurrenceID] = components.sorted()
                if !components.isEmpty && components.isDisjoint(with: ["MCP", "Apps"]) { result.extensionIDs.insert(occurrenceID) }
            }
        }
        return result
    }

    /// Bounded traversal follows skill-folder links, but skips cache/trash/system
    /// directories unless explicitly supplied as a root. Never traverses script trees.
    private func skillFiles(_ root: URL) -> [URL] {
        var found: [URL] = [], visited: Set<String> = []
        func walk(_ directory: URL, depth: Int) {
            guard depth <= 6, found.count < 1000, visited.insert(directory.resolvingSymlinksInPath().path).inserted else { return }
            let direct = directory.appendingPathComponent("SKILL.md")
            if FileManager.default.fileExists(atPath: direct.path) { found.append(direct); return }
            if directory.lastPathComponent == "SKILL.md", FileManager.default.fileExists(atPath: directory.path) { found.append(directory); return }
            for child in directories(directory) where !child.lastPathComponent.hasPrefix(".") && !["node_modules", "scripts", "assets", "references"].contains(child.lastPathComponent) {
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return found
    }
    private func directories(_ root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { var directory: ObjCBool = false; return FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory) && directory.boolValue }
            .sorted { $0.path < $1.path }
    }
    private func pluginRoots(entry: InventoryEntry, native: URL, provider: ProviderKind) -> [URL] {
        if provider == .claude {
            let registry = read(URL(fileURLWithPath: entry.source))
            let records = (registry["plugins"] as? [String: [[String: Any]]])?[entry.name] ?? []
            return records.compactMap { ($0["installPath"] as? String).map { URL(fileURLWithPath: $0) } }
        }
        if entry.source.contains("/plugins/cache/") { return [URL(fileURLWithPath: entry.source)] }
        let parts = entry.name.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [] }
        let cache = native.deletingLastPathComponent().appendingPathComponent("plugins/cache/\(parts[1])/\(parts[0])")
        let versions = directories(cache).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        return versions.first.map { [$0] } ?? []
    }
    private func pluginManifest(_ root: URL) -> [String: Any] {
        for path in ["plugin.json", ".codex-plugin/plugin.json", ".claude-plugin/plugin.json", ".cursor-plugin/plugin.json"] {
            let file = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: file.path) { return read(file) }
        }
        return [:]
    }
    private func read(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if url.pathExtension == "toml" { return (try? Dictionary(TOMLTable(source: String(decoding: data, as: UTF8.self)))) ?? [:] }
        return ((try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any]) ?? [:]
    }
}
