import Foundation

public struct SkillInstallation: Identifiable, Sendable {
    public var id: String { "\(account.id)|\(path)|\(plugin ?? "")" }
    public let account: Account
    public let name: String
    public let summary: String
    public let path: String
    public let origin: ConnectionOrigin
    public let plugin: String?
    public let state: String
    public let fingerprint: String
    public let warnings: [String]
    public let sharedID: UUID?
    public init(account: Account, name: String, summary: String, path: String, origin: ConnectionOrigin,
                plugin: String?, state: String, fingerprint: String, warnings: [String], sharedID: UUID?) {
        self.account = account; self.name = name; self.summary = summary; self.path = path
        self.origin = origin; self.plugin = plugin; self.state = state; self.fingerprint = fingerprint
        self.warnings = warnings; self.sharedID = sharedID
    }
}

public struct SkillGroup: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public var installations: [SkillInstallation]
    public init(name: String, installations: [SkillInstallation]) { self.name = name; self.installations = installations }
    public var accountCount: Int { Set(installations.map { $0.account.id }).count }
    public var variants: Int { Set(installations.map(\.fingerprint)).count }
    public var summary: String { installations.first?.summary ?? "" }
    public static func build(_ entries: [SkillInstallation]) -> [SkillGroup] {
        Dictionary(grouping: entries, by: \.name).map { SkillGroup(name: $0.key, installations: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public struct SharedSkill: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let importedFrom: String
    public var installedPaths: [String]
    public init(id: UUID = UUID(), name: String, importedFrom: String, installedPaths: [String] = []) {
        self.id = id; self.name = name; self.importedFrom = importedFrom; self.installedPaths = installedPaths
    }
}

public struct SkillInventorySnapshot: Sendable {
    public var entries: [SkillInstallation] = []
    /// Plugin occurrence IDs positively identified as containing no connection components.
    public var extensionIDs: Set<String> = []
    public var packageComponents: [String: [String]] = [:]
    public var warnings: [String] = []
    public init() {}
}
