import Domain
import Foundation

/// What T3 last reported for one provider instance, from its status cache
/// (`<T3 home>/caches/<instanceId>.json`) or `server.getConfig`. The cache can lag behind the app.
public struct T3ProviderStatus: Sendable, Equatable {
    public enum Auth: String, Sendable {
        case authenticated, unauthenticated, unknown
    }

    public struct UsageWindow: Sendable, Equatable {
        public var label: String
        public var usedPercent: Double
        public var resetsAt: Date?

        public init(label: String, usedPercent: Double, resetsAt: Date? = nil) {
            self.label = label
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    public var instanceID: String
    public var driver: String
    public var auth: Auth
    public var email: String?
    public var planLabel: String?
    public var checkedAt: Date?
    public var usageWindows: [UsageWindow]
    /// Where the provider shows usage when T3 cannot read it, e.g. ChatGPT for managed Codex.
    public var externalUsageURL: URL?

    public init(instanceID: String, driver: String, auth: Auth, email: String? = nil,
                planLabel: String? = nil, checkedAt: Date? = nil,
                usageWindows: [UsageWindow] = [], externalUsageURL: URL? = nil) {
        self.instanceID = instanceID
        self.driver = driver
        self.auth = auth
        self.email = email
        self.planLabel = planLabel
        self.checkedAt = checkedAt
        self.usageWindows = usageWindows
        self.externalUsageURL = externalUsageURL
    }

    public static func parse(_ data: Data) -> T3ProviderStatus? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap(parse(object:))
    }

    /// Statuses from a `server.getConfig` result.
    public static func parseConfig(_ data: Data) -> [T3ProviderStatus] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = object["providers"] as? [[String: Any]]
        else { return [] }
        return providers.compactMap(parse(object:))
    }

    static func parse(object: [String: Any]) -> T3ProviderStatus? {
        guard let instanceID = object["instanceId"] as? String,
              let driver = object["driver"] as? String
        else { return nil }
        let auth = object["auth"] as? [String: Any] ?? [:]
        let usage = object["usageLimits"] as? [String: Any] ?? [:]
        let windows = (usage["windows"] as? [[String: Any]] ?? []).compactMap { window -> UsageWindow? in
            guard let used = window["usedPercent"] as? Double else { return nil }
            return UsageWindow(
                label: window["label"] as? String ?? window["kind"] as? String ?? "Limit",
                usedPercent: used,
                resetsAt: (window["resetsAt"] as? String).flatMap(Self.date)
            )
        }
        let external = (usage["externalUsage"] as? [String: Any])?["url"] as? String
        return T3ProviderStatus(
            instanceID: instanceID,
            driver: driver,
            auth: (auth["status"] as? String).flatMap(Auth.init(rawValue:)) ?? .unknown,
            email: auth["email"] as? String,
            planLabel: auth["label"] as? String,
            checkedAt: (object["checkedAt"] as? String).flatMap(Self.date),
            usageWindows: windows,
            externalUsageURL: external.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        )
    }

    private static func date(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

public struct T3ProviderStatusReader: Sendable {
    public var cacheDirectories: [URL]

    public init(cacheDirectories: [URL]) {
        self.cacheDirectories = cacheDirectories
    }

    /// T3 keeps provider caches under its home (`~/.t3/caches`), next to `userdata/` and `dev/`.
    public init(settingsURLs: [URL]) {
        var directories: [URL] = []
        for url in settingsURLs {
            let directory = url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("caches", isDirectory: true).standardizedFileURL
            if !directories.contains(directory) { directories.append(directory) }
        }
        self.init(cacheDirectories: directories)
    }

    public func status(instanceID: String) -> T3ProviderStatus? {
        guard !instanceID.contains("/"), !instanceID.hasPrefix(".") else { return nil }
        let statuses = cacheDirectories.compactMap { directory -> T3ProviderStatus? in
            let url = directory.appendingPathComponent("\(instanceID).json")
            return (try? Data(contentsOf: url)).flatMap(T3ProviderStatus.parse)
        }
        return statuses.max { ($0.checkedAt ?? .distantPast) < ($1.checkedAt ?? .distantPast) }
    }
}

/// A ChatGPT account T3 signs in to itself (`setupMode: managed`). T3 keeps its tokens in its own
/// secret store and no Harnais profile backs it; Harnais only reads the settings and status cache.
public struct T3ManagedAccount: Sendable, Equatable, Identifiable {
    public var instanceID: String
    public var displayName: String
    public var enabled: Bool
    public var status: T3ProviderStatus?

    public var id: String { instanceID }

    public init(instanceID: String, displayName: String, enabled: Bool, status: T3ProviderStatus? = nil) {
        self.instanceID = instanceID
        self.displayName = displayName
        self.enabled = enabled
        self.status = status
    }

    /// The ChatGPT account page T3 links to for managed Codex usage.
    public static let usagePage = URL(string: "https://chatgpt.com/#settings/Usage")!

    public static func parse(settings data: Data) -> [T3ManagedAccount] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let instances = root["providerInstances"] as? [String: Any]
        else { return [] }
        return instances.compactMap { id, value -> T3ManagedAccount? in
            guard let object = value as? [String: Any],
                  object["driver"] as? String == ProviderKind.codex.t3Driver,
                  (object["config"] as? [String: Any])?["setupMode"] as? String == "managed"
            else { return nil }
            let name = (object["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return T3ManagedAccount(
                instanceID: id,
                displayName: name?.isEmpty == false ? name! : "ChatGPT",
                enabled: object["enabled"] as? Bool ?? true
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func read(settingsURLs: [URL], statuses: T3ProviderStatusReader) -> [T3ManagedAccount] {
        var accounts: [T3ManagedAccount] = []
        for url in settingsURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            for var account in parse(settings: data) where !accounts.contains(where: { $0.id == account.id }) {
                account.status = statuses.status(instanceID: account.instanceID)
                accounts.append(account)
            }
        }
        return accounts
    }
}
