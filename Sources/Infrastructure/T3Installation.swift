import AppKit
import Foundation

/// One installed T3 Code app bundle.
public struct T3Build: Sendable, Equatable, Identifiable {
    public enum Channel: String, Sendable {
        case stable, preview, nightly

        public var displayName: String {
            switch self {
            case .stable: "Stable"
            case .preview: "Preview"
            case .nightly: "Nightly"
            }
        }
    }

    public var appURL: URL
    public var name: String
    public var version: String?
    public var channel: Channel
    /// Builds from the 0.0.46 nightlies run Cursor through the bundled `@cursor/sdk`. That runtime
    /// ignores `cursor-agent`, `binaryPath` and `CURSOR_CONFIG_DIR`: each Cursor provider in T3,
    /// including the default one, has its own sign-in. Older builds still use the CLI profile.
    public var usesCursorSDK: Bool

    public var id: String { appURL.path }

    public init(appURL: URL, name: String, version: String?, channel: Channel, usesCursorSDK: Bool) {
        self.appURL = appURL
        self.name = name
        self.version = version
        self.channel = channel
        self.usesCursorSDK = usesCursorSDK
    }

    public init(appURL: URL) {
        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let version = info["CFBundleShortVersionString"] as? String
        let scope = appURL.appendingPathComponent("Contents/Resources/node_modules/@cursor", isDirectory: true)
        let packages = (try? FileManager.default.contentsOfDirectory(atPath: scope.path)) ?? []
        self.init(
            appURL: appURL,
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
                ?? appURL.deletingPathExtension().lastPathComponent,
            version: version,
            channel: Self.channel(forVersion: version),
            usesCursorSDK: packages.contains { $0.hasPrefix("sdk") }
        )
    }

    /// `0.0.46-nightly.20261007.2774` → nightly; untagged versions are stable releases.
    public static func channel(forVersion version: String?) -> Channel {
        let tag = version?.split(separator: "-", maxSplits: 1).dropFirst().first?.lowercased() ?? ""
        if tag.hasPrefix("nightly") { return .nightly }
        if tag.hasPrefix("preview") { return .preview }
        return .stable
    }
}

/// Installed T3 Code apps. Stable and Nightly share this bundle ID and `~/.t3/userdata/settings.json`.
public struct T3Installation: Sendable {
    public static let bundleIdentifier = "com.t3tools.t3code"
    public var builds: [T3Build]

    public init(builds: [T3Build]) { self.builds = builds }

    public init(appURLs: [URL]) {
        self.init(builds: appURLs.map(T3Build.init(appURL:)))
    }

    public static func installed() -> T3Installation {
        T3Installation(appURLs: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier))
    }

    public var signsInToCursorSeparately: Bool {
        builds.contains(where: \.usesCursorSDK)
    }

    /// Shared settings must retain CLI isolation if any installed build needs it.
    /// With no known build, keep the compatible CLI export until T3 is detected.
    public var usesOnlyCursorSDK: Bool {
        !builds.isEmpty && builds.allSatisfy(\.usesCursorSDK)
    }
}
