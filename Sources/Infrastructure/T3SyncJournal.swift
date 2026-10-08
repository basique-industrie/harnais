import Domain
import Foundation

public struct T3SyncJournal: Sendable {
    public var file: AtomicJSONFile
    public init(identity: AppIdentity = .current) {
        file = AtomicJSONFile(fileURL: identity.dataDirectory.appendingPathComponent("t3-sync-history.json"))
    }
    public init(fileURL: URL) { file = AtomicJSONFile(fileURL: fileURL) }
    private struct Document: Codable { var version = 1; var records: [T3SyncRecord] = [] }

    public func records() throws -> [T3SyncRecord] {
        try file.withLock { try load().records.sorted { $0.createdAt > $1.createdAt } }
    }
    public func save(_ record: T3SyncRecord) throws {
        try file.withLock {
            var document = try load()
            document.records.removeAll { $0.id == record.id }
            document.records.append(record)
            document.records = Array(document.records.sorted { $0.createdAt > $1.createdAt }.prefix(100))
            try file.writeUnlocked(document)
        }
    }
    public func mark(_ id: UUID, status: T3SyncRecord.Status) throws {
        try file.withLock {
            var document = try load()
            guard let index = document.records.firstIndex(where: { $0.id == id }) else {
                throw HarnaisError.processFailed("This sync is no longer in the activity history.")
            }
            document.records[index].status = status
            try file.writeUnlocked(document)
        }
    }
    private func load() throws -> Document {
        guard FileManager.default.fileExists(atPath: file.fileURL.path) else { return Document() }
        let document = try file.readUnlocked(Document.self)
        guard document.version == 1 else { throw HarnaisError.processFailed("This sync history needs a newer Harnais version.") }
        return document
    }
}
