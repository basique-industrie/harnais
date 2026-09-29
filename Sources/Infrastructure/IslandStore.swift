import Domain
import Foundation

/// Persists `islands.json` (island ring publish toggles). The quota feed
/// itself always stays complete; this config only filters the probe output
/// and the in-app Islands preview.
public struct IslandStore: Sendable {
    public var file: AtomicJSONFile

    public init(identity: AppIdentity = .current) {
        self.file = AtomicJSONFile(fileURL: identity.islandsFileURL)
    }

    public init(fileURL: URL) {
        self.file = AtomicJSONFile(fileURL: fileURL)
    }

    public func load() throws -> IslandPublishConfig {
        guard FileManager.default.fileExists(atPath: file.fileURL.path) else {
            return IslandPublishConfig()
        }
        return try file.read(IslandPublishConfig.self)
    }

    public func save(_ document: IslandPublishConfig) throws {
        try file.write(document)
    }
}
