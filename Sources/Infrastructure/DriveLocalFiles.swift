import Darwin
import Domain
import Foundation

/// File handoff keeps workbook bytes out of an agent's conversation context.
enum DriveLocalFiles {
    static func read(_ path: String) throws -> Data {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw HarnaisError.processFailed("localPath must be an absolute file path on this Mac.") }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw HarnaisError.processFailed("Could not open localPath. Choose a regular file, not a symlink.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= DriveFileReplacement.limit else { throw HarnaisError.processFailed("localPath must be a regular file of at most 16 MB.") }
        let bytes = try handle.read(upToCount: DriveFileReplacement.limit + 1) ?? Data()
        guard bytes.count <= DriveFileReplacement.limit else { throw HarnaisError.processFailed("Local file exceeds 16 MB.") }
        return bytes
    }

    static func save(_ bytes: Data, mime: String) throws -> URL {
        // A private unique directory avoids replacing files selected by another process.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harnais-drive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let extensions = [DriveContentReader.xlsx: "xlsx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
                          "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx", "application/pdf": "pdf",
                          "text/plain": "txt", "text/csv": "csv", "application/json": "json", "application/vnd.ms-excel.sheet.macroEnabled.12": "xlsm"]
        let file = directory.appendingPathComponent("document." + (extensions[mime] ?? "bin"))
        do {
            try bytes.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
