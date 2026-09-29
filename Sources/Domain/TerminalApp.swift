import Foundation

/// External terminal apps Harnais can target from Open in Terminal.
public enum TerminalAppKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case ghostty
    case terminal
    case iterm
    case warp
    case alacritty
    case kitty
    case wezterm

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ghostty: "Ghostty"
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .warp: "Warp"
        case .alacritty: "Alacritty"
        case .kitty: "Kitty"
        case .wezterm: "WezTerm"
        }
    }

    public var bundleIdentifiers: [String] {
        switch self {
        case .ghostty: ["com.mitchellh.ghostty"]
        case .terminal: ["com.apple.Terminal"]
        case .iterm: ["com.googlecode.iterm2"]
        case .warp: ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        case .alacritty: ["org.alacritty", "io.alacritty"]
        case .kitty: ["net.kovidgoyal.kitty"]
        case .wezterm: ["com.github.wez.wezterm"]
        }
    }

    public var launchMethod: TerminalLaunchMethod {
        switch self {
        case .terminal, .iterm: .openDocument
        case .ghostty: .ghostty
        case .wezterm: .wezterm
        case .kitty: .kitty
        case .warp, .alacritty: .openExec
        }
    }
}

public enum TerminalLaunchMethod: Equatable, Sendable {
    /// `open -a App file.command` — Launch Services, no Automation prompt.
    case openDocument
    /// New Ghostty process with `-e` so the wrapper is `initial-command`.
    case ghostty
    /// `open -n -a App --args -e <executable>`
    case openExec
    /// `open -n -a WezTerm --args start -- <executable>`
    case wezterm
    /// `open -n -a kitty --args <executable>`
    case kitty
}

/// Windowed-app preferences. Accounts stay in `accounts.json`.
public struct HarnaisSettingsDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var terminalAppID: String?
    public var autoStartCodexWeeks: Bool?

    public init(schemaVersion: Int = 1, terminalAppID: String? = nil, autoStartCodexWeeks: Bool? = nil) {
        self.schemaVersion = schemaVersion
        self.terminalAppID = terminalAppID
        self.autoStartCodexWeeks = autoStartCodexWeeks
    }
}
