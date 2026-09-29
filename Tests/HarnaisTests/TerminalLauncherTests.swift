import AppKit
import Domain
import Foundation
import Infrastructure

enum TerminalLauncherTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        func expectEqual<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            expect(got == want, "\(message) (got \(got), want \(want))")
        }

        let ghosttyURL = URL(fileURLWithPath: "/Applications/Ghostty.app")
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let itermURL = URL(fileURLWithPath: "/Applications/iTerm.app")
        let launcher = TerminalLauncher { bundleID in
            switch bundleID {
            case "com.mitchellh.ghostty": ghosttyURL
            case "com.apple.Terminal": terminalURL
            case "com.googlecode.iterm2": itermURL
            default: nil
            }
        }
        let terminalApps = launcher.installedApplications()
        expectEqual(terminalApps.map(\.kind), [.ghostty, .terminal, .iterm], "terminal catalog lists installed apps in order")
        expectEqual(
            launcher.resolve(preference: nil, installed: terminalApps)?.kind,
            .ghostty,
            "Open in Terminal defaults to Ghostty when it is installed"
        )
        expectEqual(
            launcher.resolve(preference: "terminal", installed: terminalApps)?.kind,
            .terminal,
            "saved terminal preference wins over Ghostty"
        )
        let withoutGhostty = terminalApps.filter { $0.kind != .ghostty }
        expectEqual(
            launcher.resolve(preference: "ghostty", installed: withoutGhostty)?.kind,
            .terminal,
            "missing Ghostty preference falls back to Terminal.app"
        )
        let ghostty = terminalApps.first { $0.kind == .ghostty }!
        let runner = URL(fileURLWithPath: "/tmp/harnais-test.command")
        let ghosttyPlan = launcher.plan(for: ghostty, executable: runner)
        if case .openApplication(let url, let arguments) = ghosttyPlan {
            expectEqual(url, ghosttyURL, "Ghostty launch targets Ghostty.app")
            expectEqual(
                arguments,
                ["--quit-after-last-window-closed=true", "-e", runner.path],
                "Ghostty launch uses a new process with -e"
            )
        } else {
            expect(false, "Ghostty launch uses open -na")
        }
        let terminalApp = terminalApps.first { $0.kind == .terminal }!
        let terminalPlan = launcher.plan(for: terminalApp, executable: runner)
        if case .openDocument(let url, let fileURL) = terminalPlan {
            expectEqual(url, terminalURL, "Terminal.app launch targets Terminal.app")
            expectEqual(fileURL, runner, "Terminal.app opens a .command file")
        } else {
            expect(false, "Terminal.app launch opens a document")
        }
        let iterm = terminalApps.first { $0.kind == .iterm }!
        let itermPlan = launcher.plan(for: iterm, executable: runner)
        if case .openDocument(let url, let fileURL) = itermPlan {
            expectEqual(url, itermURL, "iTerm launch targets iTerm.app")
            expectEqual(fileURL, runner, "iTerm opens a .command file")
        } else {
            expect(false, "iTerm launch opens a document")
        }
        let termTmp = root.appendingPathComponent("term-tmp")
        try FileManager.default.createDirectory(at: termTmp, withIntermediateDirectories: true)
        let fileLauncher = TerminalLauncher(applicationURL: { _ in nil }, temporaryDirectory: termTmp)
        expectEqual(
            try fileLauncher.runner(for: "/bin/zsh", method: .ghostty).path,
            "/bin/zsh",
            "Ghostty -e can run an executable wrapper directly"
        )
        let terminalRunner = try fileLauncher.runner(for: "/bin/zsh", method: .openDocument)
        expectEqual(terminalRunner.pathExtension, "command", "Terminal.app needs a .command document")
        expect(
            try String(contentsOf: terminalRunner, encoding: .utf8).contains("exec '/bin/zsh'"),
            "Terminal .command execs the wrapper"
        )
        let shellRunner = try fileLauncher.runner(for: "echo hi", method: .ghostty)
        expectEqual(shellRunner.pathExtension, "command", "non-executable commands become a .command file")
        expect(
            try String(contentsOf: shellRunner, encoding: .utf8).contains("echo hi"),
            "Ghostty .command runs the inline command"
        )

        let settingsURL = root.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: settingsURL)
        try store.save(HarnaisSettingsDocument(terminalAppID: "ghostty"))
        expectEqual(try store.load().terminalAppID, "ghostty", "settings store round-trips the terminal choice")
    }
}
