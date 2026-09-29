import Domain
import Foundation

/// Data directory for the windowed app and the CLI.
public struct AppIdentity: Sendable, Equatable {
    public static let shippedBundleIdentifier = "com.jean.harnais"
    public static let developmentBundleIdentifier = "com.jean.harnais.dev"
    public static let current = AppIdentity()

    public let bundleIdentifier: String
    public let isDevelopment: Bool
    public let displayName: String
    public let dataDirectoryName: String
    private let dataDirectoryOverride: URL?

    public init(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? shippedBundleIdentifier,
        dataDirectory: URL? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        let isDevelopment = bundleIdentifier == Self.developmentBundleIdentifier
        self.isDevelopment = isDevelopment
        displayName = isDevelopment ? "Harnais Dev" : "Harnais"
        dataDirectoryName = ".harnais"
        dataDirectoryOverride = dataDirectory ?? Self.envDataDirectory()
    }

    /// Local e2e / test aid: point Harnais at a throwaway home.
    /// Never set in production; the app always uses `~/.harnais`.
    private static func envDataDirectory() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["HARNAIS_DATA_DIR"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        if let url = URL(string: raw), url.scheme == "file" { return url }
        return URL(fileURLWithPath: raw)
    }

    public var dataDirectory: URL {
        dataDirectoryOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(dataDirectoryName, isDirectory: true)
    }

    public var accountsFileURL: URL {
        dataDirectory.appendingPathComponent("accounts.json")
    }

    public var settingsFileURL: URL {
        dataDirectory.appendingPathComponent("settings.json")
    }

    public var quotasFileURL: URL {
        dataDirectory.appendingPathComponent("quotas.json")
    }

    public var usageCacheFileURL: URL {
        dataDirectory.appendingPathComponent("usage-cache.json")
    }

    public var profilesDirectory: URL {
        dataDirectory.appendingPathComponent("profiles", isDirectory: true)
    }

    public var binDirectory: URL {
        dataDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    public var integrationsFileURL: URL {
        dataDirectory.appendingPathComponent("integrations.json")
    }

    public var oauthClientsFileURL: URL {
        dataDirectory.appendingPathComponent("oauth-clients.json")
    }

    public var mcpApplyFileURL: URL {
        dataDirectory.appendingPathComponent("mcp-apply.json")
    }

    public var islandsFileURL: URL {
        dataDirectory.appendingPathComponent("islands.json")
    }

    public var integrationsDirectory: URL {
        dataDirectory.appendingPathComponent("integrations", isDirectory: true)
    }

    public func integrationCredentialsURL(kind: IntegrationKind, slug: String) -> URL {
        integrationsDirectory
            .appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("credentials.json")
    }
}
