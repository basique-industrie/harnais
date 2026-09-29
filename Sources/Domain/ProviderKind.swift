import Foundation

/// Providers Harnais can isolate into named accounts.
public enum ProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude
    case codex
    case cursor
    case opencode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        }
    }

    public var defaultBinaryName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "cursor-agent"
        case .opencode: "opencode"
        }
    }

    public var wrapperPrefix: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "agent"
        case .opencode: "opencode"
        }
    }

    public var terminalCommands: [String] {
        self == .cursor ? ["cursor-agent", "agent"] : [defaultBinaryName]
    }

    public var loginArguments: [String] {
        switch self {
        case .claude: ["auth", "login"]
        case .codex: ["login"]
        case .cursor: ["login"]
        case .opencode: ["auth", "login"]
        }
    }

    public var t3Driver: String {
        switch self {
        case .claude: "claudeAgent"
        case .codex: "codex"
        case .cursor: "cursor"
        case .opencode: "opencode"
        }
    }

    public var npmPackageName: String? {
        switch self {
        case .claude: "@anthropic-ai/claude-code"
        case .codex: "@openai/codex"
        case .cursor: nil
        case .opencode: "opencode-ai"
        }
    }

    public var installURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.com/product/claude-code")!
        case .codex: URL(string: "https://developers.openai.com/codex/cli")!
        case .cursor: URL(string: "https://cursor.com/cli")!
        case .opencode: URL(string: "https://opencode.ai/docs/")!
        }
    }
}

/// Codex can share T3 session history via a shadow home, or stay fully isolated.
public enum CodexIsolationMode: String, Codable, Sendable, CaseIterable {
    case isolated
    case t3Shadow
}
