import Foundation

/// Collections organize the UI only. Members keep their identities, versions and ownership.
public struct SkillCollection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let icon: String
    public var groups: [SkillGroup]
    public var origin: ConnectionOrigin {
        groups.contains { $0.installations.contains { $0.origin == .added } } ? .added : .builtIn
    }
    public var originLabels: String {
        [ConnectionOrigin.added, .builtIn].filter { origin in groups.contains { $0.installations.contains { $0.origin == origin } } }.map(\.rawValue).joined(separator: " + ")
    }
    public var accountCount: Int { Set(groups.flatMap(\.installations).map { $0.account.id }).count }
    public var providers: [ProviderKind] { ProviderKind.allCases.filter { provider in groups.contains { $0.installations.contains { $0.account.provider == provider } } } }
    public func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query) || summary.localizedCaseInsensitiveContains(query) ||
        groups.contains { $0.matches(query) }
    }
    public static func build(_ groups: [SkillGroup]) -> [SkillCollection] {
        Dictionary(grouping: groups, by: \.collectionKey).map { key, members in
            let presentation = details(key)
            return SkillCollection(id: key, title: presentation?.0 ?? members[0].displayTitle,
                summary: presentation?.1 ?? members[0].summary,
                icon: presentation?.2 ?? members[0].iconName,
                groups: members.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending })
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private static func details(_ key: String) -> (String, String, String)? {
        switch key {
        case "artifacts": ("Artifacts & templates", "Documents, PDFs, presentations, spreadsheets and reusable templates.", "doc.on.doc")
        case "slack": ("Slack", "Messaging, search, Block Kit and Slack app development.", "slack")
        case "atlassian": ("Atlassian", "Jira, Confluence, planning and team knowledge.", "atlassian")
        case "aikido": ("Aikido", "Security findings, scanning and setup.", "aikido")
        case "browser": ("Browser automation", "Browser and Chrome workflows from your installed providers.", "globe")
        case "sites": ("Sites", "Website building, publishing and preview troubleshooting.", "rectangle.3.group")
        case "skill-tools": ("Skills & plugins", "Discover, create, install and manage reusable extensions.", "puzzlepiece.extension")
        default: nil
        }
    }
}

public extension SkillGroup {
    var displayTitle: String { Self.displayTitle(name) }
    static func displayTitle(_ name: String) -> String {
        let key = name.lowercased()
        let titles = ["docx": "Word documents", "docs": "Document workflows", "documents": "Documents", "pdf": "PDF", "pptx": "PowerPoint", "presentations": "Presentations", "xlsx": "Excel spreadsheets", "spreadsheets": "Spreadsheets", "excel-live-control": "Excel live control", "block-kit": "Block Kit", "slack-api": "Slack API", "slack-cli": "Slack CLI", "slack-docs": "Slack documentation", "imagegen": "Image generation", "openai-docs": "OpenAI documentation", "excalidraw-skill": "Excalidraw", "unslop": "Writing cleanup", "built-in-browser": "Built-in browser", "control-in-app-browser": "In-app browser", "chrome-browser": "Chrome browser", "control-chrome": "Control Chrome", "jira-sprint-dashboard": "Jira sprint dashboard", "x-post": "Post to X"]
        if let title = titles[key] { return title }
        let stem = key.hasPrefix("artifact-template-") ? String(key.dropFirst("artifact-template-".count)) : name
        let words = stem.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
    var collectionKey: String {
        let key = name.lowercased()
        let plugins = Set(installations.compactMap(\.plugin).map { InventoryEntry.serviceName($0) })
        if plugins.contains("slack") || key.hasPrefix("slack-") || ["block-kit", "create-slack-app", "test-slack-app"].contains(key) { return "slack" }
        if plugins.contains("atlassian") { return "atlassian" }
        if plugins.contains("aikido") || key.hasPrefix("aikido-") { return "aikido" }
        if key.hasPrefix("artifact-template-") || ["docs", "docx", "documents", "pdf", "pptx", "presentations", "xlsx", "spreadsheets", "excel-live-control", "template-creator"].contains(key) { return "artifacts" }
        if ["built-in-browser", "control-in-app-browser", "chrome-browser", "control-chrome"].contains(key) { return "browser" }
        if ["sites-building", "sites-hosting", "sites-preview-troubleshooting"].contains(key) { return "sites" }
        if ["skill-creator", "skill-installer", "plugin-creator", "plugin-management", "find-skills"].contains(key) { return "skill-tools" }
        return "skill|" + name
    }
    var iconName: String {
        let key = name.lowercased()
        if collectionKey == "slack" { return "slack" }
        if collectionKey == "atlassian" { return "atlassian" }
        if collectionKey == "aikido" { return "aikido" }
        if key == "excalidraw-skill" { return "excalidraw" }
        if ["xlsx", "spreadsheets", "excel-live-control"].contains(key) { return "tablecells" }
        if ["pptx", "presentations"].contains(key) { return "rectangle.stack" }
        if key.hasPrefix("artifact-template-") { return "square.grid.2x2" }
        if collectionKey == "artifacts" { return "doc.text" }
        if collectionKey == "browser" { return "globe" }
        if collectionKey == "sites" { return "rectangle.3.group" }
        if collectionKey == "skill-tools" { return "puzzlepiece.extension" }
        switch key {
        case "imagegen": return "photo"
        case "frontend-design": return "paintbrush.pointed"
        case "computer-use": return "cursorarrow"
        case "visualize": return "chart.bar.xaxis"
        case "deep-research", "openai-docs": return "magnifyingglass"
        case "review-agent": return "checkmark.bubble"
        case "import-memory": return "brain"
        case "morning": return "sun.max"
        case "unslop": return "pencil.line"
        case "x-post": return "bubble.left"
        default: return "text.book.closed"
        }
    }
    func matches(_ query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query) || displayTitle.localizedCaseInsensitiveContains(query) || summary.localizedCaseInsensitiveContains(query) ||
        installations.contains { ($0.plugin ?? "").localizedCaseInsensitiveContains(query) || $0.account.provider.displayName.localizedCaseInsensitiveContains(query) }
    }
}
