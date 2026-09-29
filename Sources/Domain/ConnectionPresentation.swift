import Foundation

public extension CatalogConnection {
    var purpose: String {
        switch name {
        case "clangd-lsp": "C and C++ code intelligence through clangd."
        case "pyright-lsp": "Python type checking and navigation through Pyright."
        case "rust-analyzer-lsp": "Rust code intelligence through rust-analyzer."
        case "swift-lsp": "Swift code intelligence through SourceKit."
        case "ty-lsp": "Python code intelligence through ty."
        case "code-simplifier": "An agent for simplifying and reviewing code."
        case "feature-dev": "A guided feature development command and supporting agents."
        case "frontend-design": "A skill for designing and building interfaces."
        case "security-guidance": "Hooks that flag sensitive code changes."
        case "documents": "Create and review Word and document files."
        case "pdf": "Read, create and render PDF files."
        case "presentations": "Create, edit and render slide decks."
        case "spreadsheets": "Work with spreadsheet files and supported app connections."
        case "template-creator": "Create reusable artifact templates."
        case "openai-templates": "Templates for documents, slides and spreadsheets."
        case "plugin-management": "Manage plugins and connected apps inside the provider."
        case "sites": "Build and publish websites through ChatGPT Sites."
        case "teams": "Microsoft Teams access through the provider's app connection."
        case "computer-use": "Control desktop apps through the installed provider runtime."
        case "node-repl": "A persistent JavaScript runtime supplied by the provider."
        default: IntegrationKind.allCases.first { $0.rawValue == name }?.summary ?? "Installed tools and their account configuration."
        }
    }
    var categoryLabel: String {
        if name.hasSuffix("-lsp") { return "Language server" }
        if ["computer-use", "node-repl"].contains(name) { return "Provider runtime" }
        if ["teams", "sites", "plugin-management"].contains(name) { return "Provider app" }
        if isProviderPlugin { return "Provider plugin" }
        return "MCP server"
    }
    var compatibilityNote: String {
        if origin == .builtIn && occurrences.contains(where: { $0.entry.origin == .added }) { return "Includes provider-bundled and separately added installations. Each installation keeps its own origin, account and controls below." }
        if origin == .builtIn { return "Bundled with the provider. Availability depends on that provider's runtime and account permissions." }
        if name.hasSuffix("-lsp") { return "The language server can support other editors. This installed plugin configures it for \(providerLabel); it does not share a service login." }
        if ["computer-use", "node-repl"].contains(name) { return "This is a separately configured runtime. Its name alone does not establish provider ownership or compatibility; check its configuration before copying it to another coding tool." }
        if ["teams", "sites", "plugin-management"].contains(name) { return "This package uses the provider's app system. Its login is managed there. Harnais has no equivalent shared adapter for this package." }
        if IntegrationKind.allCases.contains(where: { $0 != .custom && $0.rawValue == name }) { return "The service login can be shared through Harnais. Provider plugins may also supply commands, skills or agents that need to remain installed." }
        if isProviderPlugin { return "Installed for \(providerLabel). Skills may be portable, but commands, hooks and app dependencies must be checked before installing the package in another provider. Installation here does not establish exclusivity." }
        return "This is an account configuration. Portability depends on the server's transport, authentication and local dependencies."
    }
    var documentationURL: URL? {
        if name == "ty-lsp" { return URL(string: "https://docs.astral.sh/ty/editors/") }
        if let kind = IntegrationKind.allCases.first(where: { $0 != .custom && $0.rawValue == name }) { return kind.registrationDocumentationURL }
        if occurrences.contains(where: { $0.entry.catalogName.hasSuffix("@claude-plugins-official") }) {
            return URL(string: "https://github.com/anthropics/claude-plugins-official/tree/main/plugins/" + name)
        }
        if providers == [.claude] { return URL(string: "https://code.claude.com/docs/en/plugins") }
        if providers.contains(.codex) { return URL(string: "https://developers.openai.com/plugins/build/plugins") }
        if providers.contains(.cursor) { return URL(string: "https://cursor.com/docs/plugins") }
        return nil
    }
    var activationSummary: String {
        let entries = occurrences.map(\.entry)
        if entries.allSatisfy(\.isInactive) { return "Disabled" }
        if entries.contains(where: \.isInactive) && entries.contains(where: { !$0.isInactive && !$0.isCachedOnly }) { return "Partly disabled" }
        if entries.allSatisfy({ $0.state == "Cached" || $0.parentPlugin != nil }) { return "Activation unverified" }
        if entries.contains(where: { $0.state == "Enabled" || $0.state == "Configured" }) { return "Configured" }
        return "Activation unverified"
    }
}
