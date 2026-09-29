import Domain
import Foundation

public struct TerminalCLIStatus: Sendable {
    public var path: String?
    public var version: String?
    public var matches = false
    public var managed = false
    public var canManage = false
    public var message = "Checking terminal…"
}

/// A dedicated PATH directory keeps terminal selection independent of installers.
/// The zsh hooks run after tool-manager hooks, including mise's directory changes.
public struct TerminalCLIManager: Sendable {
    public var home: URL
    public var directory: URL
    private let runner = ProcessRunner()
    private let start = "# BEGIN HARNAIS TERMINAL"
    private let end = "# END HARNAIS TERMINAL"

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, directory: URL = AppIdentity.current.dataDirectory.appendingPathComponent("terminal-bin")) {
        self.home = home
        self.directory = directory
    }

    private var rc: URL { home.appendingPathComponent(".zshrc").resolvingSymlinksInPath() }
    private var state: AtomicJSONFile { AtomicJSONFile(fileURL: directory.appendingPathComponent("selections.json")) }
    private var block: String {
        """
        \(start)
        _harnais_terminal_path() {
          local harnais_bin=\(ShellQuote.quote(directory.path))
          path=("$harnais_bin" "${(@)path:#$harnais_bin}")
          export PATH
        }
        autoload -Uz add-zsh-hook
        add-zsh-hook chpwd _harnais_terminal_path
        add-zsh-hook precmd _harnais_terminal_path
        _harnais_terminal_path
        \(end)
        """
    }

    public func inspect(provider: ProviderKind, managedPath: String?) -> TerminalCLIStatus {
        let managed = ((try? state.read([String: String].self)) ?? [:])[provider.rawValue] != nil
        return probe(provider: provider, managedPath: managedPath, managed: managed)
    }

    private func probe(provider: ProviderKind, managedPath: String?, managed: Bool) -> TerminalCLIStatus {
        var status = TerminalCLIStatus()
        status.managed = managed
        let tool = ShellQuote.quote(provider.defaultBinaryName)
        var env = ["HOME": home.path, "USER": NSUserName(), "LOGNAME": NSUserName(),
                   "SHELL": "/bin/zsh", "TERM": "dumb", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        // These select startup files; inherited PATH and mise session state must not leak in.
        if home == FileManager.default.homeDirectoryForCurrentUser {
            for key in ["ZDOTDIR", "XDG_CONFIG_HOME", "MISE_GLOBAL_CONFIG_FILE"] {
                env[key] = ProcessInfo.processInfo.environment[key]
            }
        }
        do {
            let result = try runner.run(executable: "/bin/zsh", arguments: ["-lic", """
            print -r -- "__HARNAIS_KIND__$(whence -w \(tool))"
            if [[ $(whence -w \(tool)) == \(ShellQuote.quote(provider.defaultBinaryName + ": command")) ]]; then
              print -r -- "__HARNAIS_PATH__$(whence -p \(tool))"
              print -r -- "__HARNAIS_VERSION__$(command \(tool) --version 2>/dev/null)"
            fi
            """], environment: env, timeout: 10, workingDirectory: home)
            let lines = result.output.components(separatedBy: "\n")
            func value(_ prefix: String) -> String? {
                lines.last(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
            }
            guard result.exitCode == 0, let path = value("__HARNAIS_PATH__"), !path.isEmpty else {
                let missing = value("__HARNAIS_KIND__") == provider.defaultBinaryName + ": none"
                status.canManage = missing && (managedPath.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false)
                status.message = missing ? "Not on terminal PATH" : "Overridden by a shell alias or function"
                return status
            }
            status.path = path
            status.version = value("__HARNAIS_VERSION__").flatMap(ConnectionProbe.parseVersion)
            status.matches = managedPath.map { Self.sameExecutable(path, $0) } ?? false
            status.canManage = managedPath.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false
            status.message = status.matches ? "Same installation" : "Different installation"
        } catch {
            status.message = "Could not check terminal. \(error.localizedDescription)"
        }
        return status
    }

    public func useHarnais(provider: ProviderKind, binaryPath: String) throws -> TerminalCLIStatus {
        guard binaryPath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: binaryPath),
              !URL(fileURLWithPath: binaryPath).standardizedFileURL.path.hasPrefix(directory.path + "/") else {
            throw HarnaisError.processFailed("Choose an installed CLI outside Harnais's terminal directory.")
        }
        // Custom ZDOTDIR shells require editing their own startup file, not ~/.zshrc.
        if home == FileManager.default.homeDirectoryForCurrentUser,
           let zdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"], zdotdir != home.path {
            throw HarnaisError.processFailed("Your shell uses ZDOTDIR. Add the CLI to that shell's PATH manually.")
        }
        return try state.withLock {
            var selections = try readSelections()
            guard selections[provider.rawValue] == nil else {
                throw HarnaisError.processFailed("Reset this CLI's terminal preference first.")
            }
            let original = try readRC()
            let updated = try addingBlock(to: original)
            for command in provider.terminalCommands {
                if (try? directory.appendingPathComponent(command).resourceValues(forKeys: [.isSymbolicLinkKey])) != nil {
                    throw HarnaisError.processFailed("A terminal entry already exists for \(command). It was not replaced.")
                }
            }
            var created: [URL] = []
            do {
                for command in provider.terminalCommands {
                    let link = directory.appendingPathComponent(command)
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: binaryPath))
                    created.append(link)
                }
                try writeRC(updated)
                let status = probe(provider: provider, managedPath: binaryPath, managed: true)
                guard status.matches else {
                    throw HarnaisError.processFailed("Another shell setting still overrides this CLI. No terminal preference was saved.")
                }
                selections[provider.rawValue] = binaryPath
                try state.writeUnlocked(selections)
                var managed = status
                managed.managed = true
                return managed
            } catch {
                for link in created { try? FileManager.default.removeItem(at: link) }
                if (try? readRC()) == updated { try writeRC(original) }
                throw error
            }
        }
    }

    public func reset(provider: ProviderKind) throws {
        try state.withLock {
            var selections = try readSelections()
            guard let target = selections[provider.rawValue] else { return }
            for command in provider.terminalCommands {
                let link = directory.appendingPathComponent(command)
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target else {
                    throw HarnaisError.processFailed("The terminal entry for \(command) was changed outside Harnais. It was not removed.")
                }
            }
            let original = try readRC()
            var updated = original
            if selections.count == 1, let range = try blockRange(in: original) {
                guard String(original[range]) == block else {
                    throw HarnaisError.processFailed("The Harnais block in .zshrc was edited. Restore it before resetting.")
                }
                updated.removeSubrange(range)
            }
            var removed: [URL] = []
            do {
                try writeRC(updated)
                for command in provider.terminalCommands {
                    let link = directory.appendingPathComponent(command)
                    try FileManager.default.removeItem(at: link)
                    removed.append(link)
                }
                selections.removeValue(forKey: provider.rawValue)
                try state.writeUnlocked(selections)
            } catch {
                for link in removed {
                    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
                }
                if (try? readRC()) == updated { try writeRC(original) }
                throw error
            }
        }
    }

    public static func sameExecutable(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath() == URL(fileURLWithPath: rhs).resolvingSymlinksInPath()
    }

    private func readSelections() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: state.fileURL.path) else { return [:] }
        return try state.readUnlocked([String: String].self)
    }

    private func readRC() throws -> String {
        FileManager.default.fileExists(atPath: rc.path) ? try String(contentsOf: rc, encoding: .utf8) : ""
    }

    private func blockRange(in text: String) throws -> Range<String.Index>? {
        guard let first = text.range(of: start) else {
            if text.contains(end) { throw HarnaisError.processFailed("Incomplete Harnais block in .zshrc.") }
            return nil
        }
        guard let last = text.range(of: end, range: first.upperBound..<text.endIndex),
              text.range(of: start, range: first.upperBound..<text.endIndex) == nil else {
            throw HarnaisError.processFailed("Incomplete or duplicate Harnais block in .zshrc.")
        }
        return first.lowerBound..<last.upperBound
    }

    private func addingBlock(to text: String) throws -> String {
        if let range = try blockRange(in: text) {
            guard String(text[range]) == block else {
                throw HarnaisError.processFailed("The Harnais block in .zshrc was edited. It was not replaced.")
            }
            return text
        }
        return text + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n") + block + "\n"
    }

    private func writeRC(_ text: String) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: rc.path)[.posixPermissions]) ?? 0o600
        try text.write(to: rc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: rc.path)
    }
}
