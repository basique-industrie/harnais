import Domain
import Foundation

/// Windowed-app settings (`terminalAppID`) in `settings.json`.
public struct SettingsStore: Sendable {
    public var file: AtomicJSONFile

    public init(identity: AppIdentity = .current) {
        self.file = AtomicJSONFile(fileURL: identity.settingsFileURL)
    }

    public init(fileURL: URL) {
        self.file = AtomicJSONFile(fileURL: fileURL)
    }

    public func load() throws -> HarnaisSettingsDocument {
        guard FileManager.default.fileExists(atPath: file.fileURL.path) else {
            return HarnaisSettingsDocument()
        }
        return try file.read(HarnaisSettingsDocument.self)
    }

    public func save(_ document: HarnaisSettingsDocument) throws {
        try file.write(document)
    }
}
