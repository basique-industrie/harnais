import Domain
import Foundation
import Infrastructure
import os

enum T3Command {
    static func run(_ command: String, arguments: [String], accounts: [Account]) throws {
        let exporter = T3Exporter()
        if command == "t3-history" {
            try printJSON(T3SyncJournal().records())
            return
        }
        let preview: T3SyncPreview
        if command == "t3-undo" {
            guard let raw = arguments.first, let id = UUID(uuidString: raw) else {
                throw HarnaisError.processFailed("Usage: harnais t3-undo <history-id> [--apply]")
            }
            preview = try exporter.previewUndo(id)
        } else {
            preview = try exporter.preview(accounts: accounts)
        }
        if command == "t3-preview" || (command == "t3-undo" && !arguments.contains("--apply")) {
            try printJSON(preview.records)
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = OSAllocatedUnfairLock<Result<Void, Error>>(initialState: .success(()))
        Task.detached {
            do { _ = try await exporter.apply(preview) }
            catch { outcome.withLock { $0 = .failure(error) } }
            semaphore.signal()
        }
        semaphore.wait()
        try outcome.withLock { try $0.get() }
        print(command == "t3-undo" ? "T3 sync undone" : "Updated in T3 Code")
    }
    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
