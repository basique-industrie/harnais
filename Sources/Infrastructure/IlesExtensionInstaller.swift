import Domain
import Foundation

/// Installs the Iles extension that reads `~/.harnais/quotas.json`.
///
/// Iles has no built-in Harnais source: this extension is the integration.
/// Its probe also triggers `harnais quotas` in the background when the feed
/// goes stale, so Iles owns refresh scheduling and Harnais just provides
/// the accounts, isolation, and probes.
public struct IlesExtensionInstaller: Sendable {
    public var identity: AppIdentity
    public var sourceDirectory: URL?
    public var destinations: [URL]

    public init(
        identity: AppIdentity = .current,
        sourceDirectory: URL? = nil,
        destinations: [URL]? = nil
    ) {
        self.identity = identity
        self.sourceDirectory = sourceDirectory
        self.destinations = destinations ?? [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".iles/extensions/harnais"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".iles-dev/extensions/harnais"),
        ]
    }

    public func isInstalled() -> Bool {
        destinations.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func install() throws -> [URL] {
        let destinations = self.destinations
        guard let source = bundledExtensionDirectory() else {
            throw HarnaisError.processFailed("Harnais is missing its bundled Iles extension.")
        }
        var installed: [URL] = []
        for destination in destinations {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            let probe = destination.appendingPathComponent("probe.sh")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probe.path)
            installed.append(destination)
        }
        return installed
    }

    func bundledExtensionDirectory() -> URL? {
        if let sourceDirectory, FileManager.default.fileExists(atPath: sourceDirectory.path) {
            return sourceDirectory
        }
        return Self.bundledExtensionDirectory(applicationBundle: .main)
    }

    /// Packaged apps keep `Harnais_Infrastructure.bundle` under
    /// `Contents/Resources`. SPM's generated `Bundle.module` looks next to the
    /// `.app` (or beside the test executable) and must not be the only lookup.
    public static func bundledExtensionDirectory(applicationBundle: Bundle) -> URL? {
        var roots: [URL] = []
        if let resources = applicationBundle.resourceURL {
            roots.append(resources)
        }
        roots.append(applicationBundle.bundleURL)
        roots.append(applicationBundle.bundleURL.appendingPathComponent("Contents/Resources"))
        if let executableDirectory = applicationBundle.executableURL?.deletingLastPathComponent() {
            roots.append(executableDirectory)
            roots.append(executableDirectory.appendingPathComponent("../Resources").standardizedFileURL)
        }
        return bundledExtensionDirectory(searchRoots: roots)
    }

    public static func bundledExtensionDirectory(searchRoots: [URL]) -> URL? {
        let fileManager = FileManager.default
        let bundleNames = [
            "Harnais_Infrastructure.bundle",
            "Infrastructure_Infrastructure.bundle",
        ]
        var seen = Set<String>()
        for root in searchRoots {
            let key = root.standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            for name in bundleNames {
                let url = root.appendingPathComponent(name).appendingPathComponent("iles-extension")
                if fileManager.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }
}
