import Darwin
import Domain
import Foundation

/// Owner-only atomic JSON replace with a last-known-good backup.
/// Mutating callers should use `withLock` around read-modify-write so the
/// CLI and the windowed app cannot interleave `accounts.json` updates.
public struct AtomicJSONFile: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public var lockURL: URL {
        fileURL.appendingPathExtension("lock")
    }

    public func withLock<T>(timeout: TimeInterval = 8, _ body: () throws -> T) throws -> T {
        try ExclusiveFileLock(url: lockURL, timeout: timeout).lock(body)
    }

    public func read<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try withLock { try readUnlocked(type, decoder: decoder) }
    }

    public func write<T: Encodable>(_ value: T, pretty: Bool = true, encoder: JSONEncoder = JSONEncoder()) throws {
        try withLock { try writeUnlocked(value, pretty: pretty, encoder: encoder) }
    }

    public func readUnlocked<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = try Data(contentsOf: fileURL)
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    public func writeUnlocked<T: Encodable>(
        _ value: T,
        pretty: Bool = true,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let current = try? Data(contentsOf: fileURL) {
            let backup = fileURL.appendingPathExtension("backup")
            try current.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

struct ExclusiveFileLock: Sendable {
    var url: URL
    var timeout: TimeInterval = 8

    func lock<T>(_ body: () throws -> T) throws -> T {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // O_CREAT opens one stable inode even when two processes arrive together.
        // FileManager.createFile can replace the inode and split the lock.
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw HarnaisError.processFailed("Could not open lock \(url.lastPathComponent).")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            flock(handle.fileDescriptor, LOCK_UN)
            try? handle.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            if Date() > deadline {
                throw HarnaisError.processFailed("Could not lock \(url.lastPathComponent).")
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return try body()
    }
}
