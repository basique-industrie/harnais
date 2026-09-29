import AppKit
import Domain
import Foundation

public struct InstalledTerminal: Equatable, Sendable, Identifiable {
    public var kind: TerminalAppKind
    public var appURL: URL
    public var bundleIdentifier: String

    public var id: TerminalAppKind { kind }

    public init(kind: TerminalAppKind, appURL: URL, bundleIdentifier: String) {
        self.kind = kind
        self.appURL = appURL
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum TerminalLaunchPlan: Equatable, Sendable {
    /// `open -n -a App --args …` — new process so `-e` is honored.
    case openApplication(appURL: URL, arguments: [String])
    /// `open -a App file.command` — document open, no Automation prompt.
    case openDocument(appURL: URL, fileURL: URL)
}

/// Discovers installed terminal apps and opens a command in the chosen one.
///
/// Never uses Apple Events. Controlling Ghostty or Terminal via AppleScript
/// would show a system permission prompt; Launch Services `open` does not.
public struct TerminalLauncher {
    public var applicationURL: (String) -> URL?
    public var temporaryDirectory: URL

    public init(
        applicationURL: @escaping (String) -> URL?,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.applicationURL = applicationURL
        self.temporaryDirectory = temporaryDirectory
    }

    @MainActor
    public static var workspace: TerminalLauncher {
        TerminalLauncher { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
    }

    public func installedApplications() -> [InstalledTerminal] {
        TerminalAppKind.allCases.compactMap { kind in
            for bundleID in kind.bundleIdentifiers {
                if let url = applicationURL(bundleID) {
                    return InstalledTerminal(kind: kind, appURL: url, bundleIdentifier: bundleID)
                }
            }
            return nil
        }
    }

    /// Ghostty when it is installed and the user has not picked another app.
    /// An explicit saved choice wins while that app is still installed.
    public func resolve(
        preference: String?,
        installed: [InstalledTerminal]
    ) -> InstalledTerminal? {
        if let preference,
           let preferred = installed.first(where: { $0.kind.rawValue == preference }) {
            return preferred
        }
        if let ghostty = installed.first(where: { $0.kind == .ghostty }) {
            return ghostty
        }
        return installed.first(where: { $0.kind == .terminal }) ?? installed.first
    }

    public func plan(for app: InstalledTerminal, executable: URL) -> TerminalLaunchPlan {
        switch app.kind.launchMethod {
        case .openDocument:
            return .openDocument(appURL: app.appURL, fileURL: executable)
        case .ghostty:
            return .openApplication(
                appURL: app.appURL,
                arguments: ["--quit-after-last-window-closed=true", "-e", executable.path]
            )
        case .openExec:
            return .openApplication(appURL: app.appURL, arguments: ["-e", executable.path])
        case .wezterm:
            return .openApplication(appURL: app.appURL, arguments: ["start", "--", executable.path])
        case .kitty:
            return .openApplication(appURL: app.appURL, arguments: [executable.path])
        }
    }

    public func open(command: String, preference: String?) throws {
        let installed = installedApplications()
        guard let app = resolve(preference: preference, installed: installed) else {
            throw HarnaisError.processFailed("No terminal app is available.")
        }
        let executable = try runner(for: command, method: app.kind.launchMethod)
        try execute(plan(for: app, executable: executable))
    }

    public func execute(_ plan: TerminalLaunchPlan) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        switch plan {
        case .openApplication(let appURL, let arguments):
            process.arguments = ["-n", "-a", appURL.path, "--args"] + arguments
        case .openDocument(let appURL, let fileURL):
            process.arguments = ["-a", appURL.path, fileURL.path]
        }
        try process.run()
    }

    public func runner(for command: String, method: TerminalLaunchMethod) throws -> URL {
        if method != .openDocument, isDirectCommand(command) {
            return URL(fileURLWithPath: command)
        }
        return try writeCommandFile(command)
    }

    func isDirectCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespaces) == nil else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: trimmed)
    }

    func writeCommandFile(_ command: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("harnais-\(UUID().uuidString).command")
        let body: String
        if isDirectCommand(command) {
            body = "#!/bin/zsh\nexec \(ShellQuote.quote(command)) \"$@\"\n"
        } else {
            body = "#!/bin/zsh\nset -euo pipefail\n\(command)\n"
        }
        try Data(body.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
