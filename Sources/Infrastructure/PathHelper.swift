import Foundation

/// Offers to append `~/.harnais/bin` to the login PATH once.
public struct PathHelper: Sendable {
    public var identity: AppIdentity
    public var zshrcURL: URL

    public init(
        identity: AppIdentity = .current,
        zshrcURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    ) {
        self.identity = identity
        self.zshrcURL = zshrcURL
    }

    public var binPath: String { identity.binDirectory.path }

    public var snippet: String {
        """
        # harnais
        export PATH="\(binPath):$PATH"
        """
    }

    public func isConfigured() -> Bool {
        guard let contents = try? String(contentsOf: zshrcURL, encoding: .utf8) else {
            return false
        }
        return contents.contains(binPath)
    }

    public func install() throws {
        if isConfigured() { return }
        let addition = "\n\(snippet)\n"
        if FileManager.default.fileExists(atPath: zshrcURL.path) {
            let handle = try FileHandle(forWritingTo: zshrcURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(addition.utf8))
        } else {
            try addition.write(to: zshrcURL, atomically: true, encoding: .utf8)
        }
    }
}
