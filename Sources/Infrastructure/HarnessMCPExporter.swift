import Domain
import Foundation
import TOMLDecoder

public struct HarnaisCLIInstaller: Sendable {
    public var identity: AppIdentity

    public init(identity: AppIdentity = .current) {
        self.identity = identity
    }

    public var wrapperURL: URL {
        identity.binDirectory.appendingPathComponent("harnais")
    }

    public func install() throws -> String {
        let source = Self.resolvedExecutable()
        try FileManager.default.createDirectory(
            at: identity.binDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let body = """
        #!/bin/zsh
        set -euo pipefail
        exec \(ShellQuote.quote(source)) "$@"
        """
        try Data(body.utf8).write(to: wrapperURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapperURL.path)
        return wrapperURL.path
    }

    public static func resolvedExecutable() -> String {
        let invoked = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let directory = invoked.deletingLastPathComponent()
        let sibling = directory.appendingPathComponent("harnais")
        if sibling.path != invoked.path, FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling.path
        }
        return invoked.path
    }
}

enum CodexMCPToml {
    static let startMarker = "# BEGIN HARNAIS MCP"
    static let endMarker = "# END HARNAIS MCP"

    static func apply(existing: String, command: String, servers: [(name: String, args: [String])]) -> String {
        let block = render(command: command, servers: servers)
        if let range = markedRange(in: existing) {
            var next = existing
            next.replaceSubrange(range, with: block)
            return next
        }
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return block + "\n" }
        return trimmed + "\n\n" + block + "\n"
    }

    static func render(command: String, servers: [(name: String, args: [String])]) -> String {
        guard !servers.isEmpty else {
            return "\(startMarker)\n\(endMarker)"
        }
        var lines = [startMarker]
        for server in servers {
            lines.append("[mcp_servers.\(quoteKey(server.name))]")
            lines.append("command = \(quote(command))")
            lines.append("args = [\(server.args.map(quote).joined(separator: ", "))]")
            lines.append("")
        }
        if lines.last == "" { lines.removeLast() }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    static func markedRange(in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: startMarker),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex)
        else { return nil }
        var upper = end.upperBound
        if upper < text.endIndex, text[upper] == "\n" {
            upper = text.index(after: upper)
        }
        return start.lowerBound..<upper
    }

    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func quoteKey(_ value: String) -> String {
        if value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return value
        }
        return quote(value)
    }
}

public struct HarnessMCPExporter: Sendable {
    public var homeDirectory: URL
    public var identity: AppIdentity

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        identity: AppIdentity = .current
    ) {
        self.homeDirectory = homeDirectory
        self.identity = identity
    }

    public func apply(
        connections: [IntegrationConnection],
        accounts: [Account],
        commandPath: String,
        previousNames: [String]
    ) throws -> MCPApplyReport {
        let active = connections.filter { !$0.excludedFromApply }
        let current = active.map(\.mcpName)
        // Validate every destination before writing the first file.
        let planned = try targets(accounts: accounts).map { target -> PreparedMCPFile in
            // Accounts sharing one provider settings file must agree. An opt-out
            // wins, so sync can never reactivate a disabled account indirectly.
            let enabled = active.filter { Set($0.excludedAccountIDs ?? []).isDisjoint(with: target.accountIDs) }
            let names = enabled.map(\.mcpName)
            let removed = Set(previousNames + connections.map(\.mcpName)).subtracting(names)
            func arguments(_ connection: IntegrationConnection) -> [String] {
                let readOnly = connection.kind == .grafana && !(Set(connection.readOnlyAccountIDs ?? []).intersection(target.accountIDs)).isEmpty
                return ["mcp", "serve", connection.mcpName] + (readOnly ? ["--read-only"] : [])
            }
            let before = FileManager.default.fileExists(atPath: target.url.path) ? try Data(contentsOf: target.url) : nil
            let after: Data
            switch target.format {
            case .codexToml:
                let existing = before.map { String(decoding: $0, as: UTF8.self) } ?? ""
                _ = try TOMLTable(source: existing)
                var outside = existing
                if let range = CodexMCPToml.markedRange(in: outside) { outside.removeSubrange(range) }
                let root = try Dictionary(TOMLTable(source: outside))
                let servers = root["mcp_servers"] as? [String: Any] ?? [:]
                for name in names where servers[name] != nil {
                    throw HarnaisError.processFailed("\(name) already exists in \(target.url.path). Choose a different shared server name in its settings.")
                }
                let next = CodexMCPToml.apply(existing: existing, command: commandPath,
                    servers: enabled.map { ($0.mcpName, arguments($0)) })
                _ = try TOMLTable(source: next)
                after = Data(next.utf8)
            case .jsonMcpServers, .openCodeJSON:
                var root: [String: Any] = [:]
                if let before {
                    guard let parsed = try JSONSerialization.jsonObject(with: before, options: [.json5Allowed]) as? [String: Any] else {
                        throw HarnaisError.processFailed("Could not read \(target.url.path). No connection settings were changed.")
                    }
                    root = parsed
                }
                let openCode = target.format == .openCodeJSON
                let key = openCode ? "mcp" : "mcpServers"
                if root[key] != nil && !(root[key] is [String: Any]) {
                    throw HarnaisError.processFailed("The MCP section in \(target.url.path) is invalid.")
                }
                var container = root[key] as? [String: Any] ?? [:]
                let v2 = openCode && container["servers"] is [String: Any]
                var servers = v2 ? container["servers"] as! [String: Any] : container
                func owned(_ value: Any?, name: String) -> Bool {
                    guard let row = value as? [String: Any] else { return false }
                    let accepted = [["mcp", "serve", name], ["mcp", "serve", name, "--read-only"]]
                    if row["command"] as? String == commandPath, let args = row["args"] as? [String], accepted.contains(args) { return true }
                    return accepted.contains { row["command"] as? [String] == [commandPath] + $0 }
                }
                for name in removed where owned(servers[name], name: name) { servers.removeValue(forKey: name) }
                for connection in enabled {
                    let name = connection.mcpName
                    if servers[name] != nil && !owned(servers[name], name: name) {
                        throw HarnaisError.processFailed("\(name) already exists in \(target.url.path). Choose a different shared server name in its settings.")
                    }
                    if openCode {
                        servers[name] = ["type": "local", "command": [commandPath] + arguments(connection), v2 ? "disabled" : "enabled": !v2]
                    } else {
                        servers[name] = ["type": "stdio", "command": commandPath, "args": arguments(connection)]
                    }
                }
                if v2 { container["servers"] = servers; root[key] = container } else { root[key] = servers }
                after = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            }
            return PreparedMCPFile(url: target.url, before: before, after: after)
        }
        var written: [PreparedMCPFile] = []
        do {
            for item in planned {
                try AtomicJSONFile(fileURL: item.url).withLock {
                    let now = try? Data(contentsOf: item.url)
                    guard now == item.before else {
                        throw HarnaisError.processFailed("\(item.url.lastPathComponent) changed during sync. Refresh and try again.")
                    }
                    if let before = item.before {
                        let backup = item.url.appendingPathExtension("harnais-backup")
                        try before.write(to: backup, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                    }
                    try item.after.write(to: item.url, options: .atomic)
                    written.append(item)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: item.url.path)
                }
            }
        } catch {
            for item in written.reversed() {
                try? AtomicJSONFile(fileURL: item.url).withLock {
                    guard (try? Data(contentsOf: item.url)) == item.after else { return }
                    if let before = item.before {
                        try before.write(to: item.url, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: item.url.path)
                    }
                    else { try FileManager.default.removeItem(at: item.url) }
                }
            }
            throw error
        }
        return MCPApplyReport(files: planned.map { $0.url.path }, mcpNames: current, commandPath: commandPath)
    }

    public func accountsSharingConfiguration(with accountID: UUID, accounts: [Account]) -> Set<UUID> {
        targets(accounts: accounts).first { $0.accountIDs.contains(accountID) }?.accountIDs ?? [accountID]
    }

    func targets(accounts: [Account]) -> [MCPTarget] {
        var items: [MCPTarget] = [
            MCPTarget(
                url: homeDirectory.appendingPathComponent(".cursor/mcp.json"),
                format: .jsonMcpServers,
                createIfMissing: true
            ),
            MCPTarget(
                url: homeDirectory.appendingPathComponent(".claude.json"),
                format: .jsonMcpServers,
                createIfMissing: false
            ),
            MCPTarget(
                url: homeDirectory.appendingPathComponent(".codex/config.toml"),
                format: .codexToml,
                createIfMissing: false
            ),
        ]
        func add(_ url: URL, format: MCPFileFormat, createIfMissing: Bool, accountID: UUID) {
            let path = url.standardizedFileURL.path
            if let index = items.firstIndex(where: { $0.url.standardizedFileURL.path == path }) {
                items[index].accountIDs.insert(accountID)
                return
            }
            items.append(MCPTarget(url: url, format: format, createIfMissing: createIfMissing, accountIDs: [accountID]))
        }
        for account in accounts {
            switch account.provider {
            case .opencode:
                let json = account.env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("opencode/opencode.json") }
                    ?? homeDirectory.appendingPathComponent(".config/opencode/opencode.json")
                let jsonc = json.deletingPathExtension().appendingPathExtension("jsonc")
                let config = account.env["OPENCODE_CONFIG"].map { URL(fileURLWithPath: $0) }
                    ?? (FileManager.default.fileExists(atPath: jsonc.path) ? jsonc : json)
                add(config, format: .openCodeJSON, createIfMissing: true, accountID: account.id)
            case .cursor:
                add(
                    URL(fileURLWithPath: account.env["CURSOR_CONFIG_DIR"] ?? account.homePath).appendingPathComponent("mcp.json"),
                    format: .jsonMcpServers,
                    createIfMissing: !account.importedDefault, accountID: account.id
                )
            case .claude:
                add(
                    account.importedDefault && account.env["CLAUDE_CONFIG_DIR"] == nil
                        ? homeDirectory.appendingPathComponent(".claude.json")
                        : URL(fileURLWithPath: account.env["CLAUDE_CONFIG_DIR"] ?? account.homePath).appendingPathComponent(".claude.json"),
                    format: .jsonMcpServers,
                    createIfMissing: !account.importedDefault, accountID: account.id
                )
            case .codex:
                let home = account.env["CODEX_HOME"] ?? account.shadowHomePath ?? account.homePath
                add(
                    URL(fileURLWithPath: home).appendingPathComponent("config.toml"),
                    format: .codexToml,
                    createIfMissing: !account.importedDefault, accountID: account.id
                )
            }
        }
        return items.filter { target in
            target.createIfMissing || FileManager.default.fileExists(atPath: target.url.path)
        }
    }

 }

private struct PreparedMCPFile {
    var url: URL
    var before: Data?
    var after: Data
}

struct MCPTarget {
    var url: URL
    var format: MCPFileFormat
    var createIfMissing: Bool
    var accountIDs: Set<UUID> = []
}

enum MCPFileFormat {
    case openCodeJSON
    case jsonMcpServers
    case codexToml
}
