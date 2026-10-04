import Domain
import Foundation

/// Finds CLI tools from a cached login PATH, then common install dirs.
///
/// PATH is resolved once per process: the app environment, a non-interactive
/// login zsh (`zsh -l`), and well-known install prefixes. An interactive zsh
/// (`-lic`) runs at most once, and only if that login PATH still looks like a
/// GUI-app default with no Homebrew or shims.
public struct BinaryLocator: Sendable {
    public init() {}

    public static func which(_ tool: String) -> String? {
        PathIndex.shared.which(tool)
    }

    public static func resolve(_ provider: ProviderKind, override: String?) -> String? {
        if let override, let path = which(override) { return currentMiseInstall(path) }
        if let path = which(provider.defaultBinaryName) { return currentMiseInstall(path) }
        if provider == .cursor {
            return which("agent").map(currentMiseInstall)
        }
        return nil
    }

    /// mise keeps old versions on disk, so a saved `mise/installs/<tool>/<version>`
    /// path silently pins that version. Follow the version mise selects now.
    public static func currentMiseInstall(_ path: String) -> String {
        guard path.lowercased().contains("/mise/installs/") else { return path }
        return PathIndex.shared.miseWhich(path) ?? path
    }

    public static func shellPath() -> String {
        PathIndex.shared.pathString
    }

    public static func resetCachedPath() {
        PathIndex.shared.reset()
    }
}

private final class PathIndex: @unchecked Sendable {
    static let shared = PathIndex()
    private let lock = NSLock()
    private var directories: [String]?
    private var hits: [String: String?] = [:]

    var pathString: String {
        resolvedDirectories().joined(separator: ":")
    }

    func reset() {
        lock.lock()
        directories = nil
        hits = [:]
        lock.unlock()
    }

    func which(_ tool: String) -> String? {
        if tool.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }
        lock.lock()
        if let cached = hits[tool] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        var found: String?
        for directory in resolvedDirectories() {
            let candidate = (directory as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                // Keep the stable installer path, not our terminal symlink or a pinned release.
                let terminalDirectory = AppIdentity.current.dataDirectory.appendingPathComponent("terminal-bin").path
                if directory == terminalDirectory,
                   let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate), target.hasPrefix("/") {
                    found = target
                } else {
                    found = candidate
                }
                break
            }
        }
        lock.lock()
        hits[tool] = found
        lock.unlock()
        return found
    }

    func miseWhich(_ path: String) -> String? {
        let key = "mise-which:\(path)"
        lock.lock()
        if let cached = hits[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        var found: String?
        if let mise = which("mise") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = pathString
            let result = try? ProcessRunner().run(
                executable: mise,
                arguments: ["which", (path as NSString).lastPathComponent],
                environment: env,
                timeout: 8,
                workingDirectory: home,
                mergeStandardError: false
            )
            let output = result?.exitCode == 0 ? result?.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            if let output, output.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: output) {
                found = output
            }
        }
        lock.lock()
        hits[key] = found
        lock.unlock()
        return found
    }

    private func resolvedDirectories() -> [String] {
        lock.lock()
        if let directories {
            lock.unlock()
            return directories
        }
        lock.unlock()
        let computed = Self.discover()
        lock.lock()
        if directories == nil {
            directories = computed
        }
        let stored = directories ?? computed
        lock.unlock()
        return stored
    }

    private static func discover() -> [String] {
        var ordered: [String] = []
        func append(path: String) {
            for part in path.split(separator: ":") {
                let expanded = (String(part) as NSString).expandingTildeInPath
                guard !expanded.isEmpty, !ordered.contains(expanded) else { continue }
                ordered.append(expanded)
            }
        }
        if let env = ProcessInfo.processInfo.environment["PATH"] {
            append(path: env)
        }
        append(path: zshPath(interactive: false))
        if !hasUserInstall(ordered) {
            append(path: zshPath(interactive: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for directory in [
            "\(home)/.local/bin",
            "\(home)/.opencode/bin",
            "\(home)/.cargo/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "\(home)/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.nix-profile/bin",
            "/run/current-system/sw/bin",
            "/usr/bin",
            "/bin",
        ] where !ordered.contains(directory) {
            ordered.append(directory)
        }
        return ordered
    }

    private static func hasUserInstall(_ directories: [String]) -> Bool {
        directories.contains { path in
            path.contains("/opt/homebrew/")
                || path.contains("/.local/bin")
                || path.contains("/mise/")
                || path.contains("/.asdf/")
                || path.contains("/.volta/")
                || path.contains("/.bun/")
                || path.contains("/.cargo/bin")
        }
    }

    private static func zshPath(interactive: Bool) -> String {
        let arguments = interactive
            ? ["-l", "-i", "-c", "print -r -- $PATH"]
            : ["-l", "-c", "print -r -- $PATH"]
        let result = try? ProcessRunner().run(
            executable: "/bin/zsh", arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            timeout: interactive ? 2.5 : 1.2, mergeStandardError: false
        )
        return result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    }
}
