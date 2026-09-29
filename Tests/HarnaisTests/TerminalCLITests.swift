import AppKit
import Domain
import Foundation
import Infrastructure

enum TerminalCLITests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let home = root.appendingPathComponent("terminal shared ' home")
        let selected = home.appendingPathComponent("selected")
        let other = home.appendingPathComponent("other")
        let directory = home.appendingPathComponent(".harnais/terminal-bin")
        for folder in [selected, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for provider in ProviderKind.allCases {
            for command in provider.terminalCommands {
                for (folder, version) in [(selected, "2.0.0"), (other, "1.0.0")] {
                    let path = folder.appendingPathComponent(command)
                    try "#!/bin/sh\necho '\(version)'\n".write(to: path, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
                }
            }
        }
        let rc = home.appendingPathComponent(".zshrc")
        let original = """
        export PATH="$HOME/other:/usr/bin:/bin"
        autoload -Uz add-zsh-hook
        fake_mise() { path=("$HOME/other" $path); export PATH; }
        add-zsh-hook chpwd fake_mise
        # Keep my shell settings.
        """ + "\n"
        try original.write(to: rc, atomically: true, encoding: .utf8)
        let manager = TerminalCLIManager(home: home, directory: directory)
        for provider in ProviderKind.allCases {
            let path = selected.appendingPathComponent(provider.defaultBinaryName).path
            let initial = manager.inspect(provider: provider, managedPath: path)
            expect(!initial.matches && initial.version == "1.0.0" && initial.canManage, "\(provider) terminal mismatch detected")
            let result = try manager.useHarnais(provider: provider, binaryPath: path)
            expect(result.matches && result.managed && result.version == "2.0.0", "\(provider) terminal choice verified")
        }
        let content = try String(contentsOf: rc, encoding: .utf8)
        expect(content.components(separatedBy: "# BEGIN HARNAIS TERMINAL").count == 2, "one shared shell block for all CLIs")
        expect(content.contains(original), "terminal management keeps shell settings")
        let shell = try ProcessRunner().run(executable: "/bin/zsh", arguments: ["-lic", "cd /; codex --version; claude --version; agent --version; opencode --version"],
                                           environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], timeout: 5, workingDirectory: home)
        expect(shell.exitCode == 0 && shell.output.components(separatedBy: "2.0.0").count == 5, "terminal choices survive tool-manager directory hooks")
        try manager.reset(provider: .codex)
        expect(manager.inspect(provider: .codex, managedPath: selected.appendingPathComponent("codex").path).version == "1.0.0", "reset restores original Codex PATH")
        expect(manager.inspect(provider: .claude, managedPath: selected.appendingPathComponent("claude").path).matches, "reset keeps other managed CLIs")
        for provider in ProviderKind.allCases where provider != .codex { try manager.reset(provider: provider) }
        let restored = try String(contentsOf: rc, encoding: .utf8)
        expect(!restored.contains("BEGIN HARNAIS") && restored.contains(original), "last reset removes only the managed shell block")

        try "export PATH=/usr/bin:/bin\n".write(to: rc, atomically: true, encoding: .utf8)
        let missing = manager.inspect(provider: .opencode, managedPath: selected.appendingPathComponent("opencode").path)
        expect(missing.path == nil && missing.canManage, "an installed CLI absent from PATH can be selected")
        expect(try manager.useHarnais(provider: .opencode, binaryPath: selected.appendingPathComponent("opencode").path).matches, "terminal preference adds a missing CLI to PATH")
        try manager.reset(provider: .opencode)

        try (original + "alias codex='echo overridden'\n").write(to: rc, atomically: true, encoding: .utf8)
        do {
            _ = try manager.useHarnais(provider: .codex, binaryPath: selected.appendingPathComponent("codex").path)
            expect(false, "alias conflict must not report success")
        } catch {
            expect(!(try String(contentsOf: rc, encoding: .utf8)).contains("BEGIN HARNAIS"), "failed verification restores shell config")
            expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("codex").path), "failed verification removes managed link")
        }
    }
}
