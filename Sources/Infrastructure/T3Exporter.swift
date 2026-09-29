import Domain
import Foundation

public struct T3ProviderInstance: Codable, Sendable, Equatable {
    public var driver: String
    public var displayName: String
    public var enabled: Bool
    public var config: [String: String]
    public var environment: [T3EnvironmentVariable]

    public init(
        driver: String,
        displayName: String,
        enabled: Bool = true,
        config: [String: String] = [:],
        environment: [T3EnvironmentVariable] = []
    ) {
        self.driver = driver
        self.displayName = displayName
        self.enabled = enabled
        self.config = config
        self.environment = environment
    }
}

public struct T3EnvironmentVariable: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var sensitive: Bool

    public init(name: String, value: String, sensitive: Bool = false) {
        self.name = name
        self.value = value
        self.sensitive = sensitive
    }
}

public struct T3Exporter: Sendable {
    public var settingsURLs: [URL]
    public var homeDirectory: URL

    /// Packaged T3 Code writes `~/.t3/userdata/settings.json`. Older guesses
    /// used Application Support; T3 Code Dev may use `~/.t3/dev/userdata`.
    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        settingsURLs = Self.existingSettingsURLs(home: homeDirectory, environment: environment)
    }

    public init(
        settingsURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.homeDirectory = homeDirectory
        settingsURLs = [settingsURL]
    }

    public init(
        settingsURLs: [URL],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.homeDirectory = homeDirectory
        self.settingsURLs = settingsURLs
    }

    public static func candidateSettingsURLs(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var urls: [URL] = []
        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            if !urls.contains(standardized) {
                urls.append(standardized)
            }
        }
        if let t3Home = environment["T3CODE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t3Home.isEmpty {
            let base: URL
            if t3Home.hasPrefix("~") {
                let expanded = (t3Home as NSString).expandingTildeInPath
                base = URL(fileURLWithPath: expanded, isDirectory: true)
            } else if t3Home.hasPrefix("/") {
                base = URL(fileURLWithPath: t3Home, isDirectory: true)
            } else {
                base = home.appendingPathComponent(t3Home, isDirectory: true)
            }
            add(base.appendingPathComponent("userdata", isDirectory: true).appendingPathComponent("settings.json"))
            add(base.appendingPathComponent("settings.json"))
        }
        add(
            home.appendingPathComponent(".t3", isDirectory: true)
                .appendingPathComponent("userdata", isDirectory: true)
                .appendingPathComponent("settings.json")
        )
        add(
            home.appendingPathComponent(".t3", isDirectory: true)
                .appendingPathComponent("dev", isDirectory: true)
                .appendingPathComponent("userdata", isDirectory: true)
                .appendingPathComponent("settings.json")
        )
        add(
            home.appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("T3 Code", isDirectory: true)
                .appendingPathComponent("userdata", isDirectory: true)
                .appendingPathComponent("settings.json")
        )
        return urls
    }

    public static func existingSettingsURLs(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        candidateSettingsURLs(home: home, environment: environment).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    public func instance(for account: Account) -> T3ProviderInstance {
        var config: [String: String] = [:]
        if let binary = BinaryLocator.resolve(account.provider, override: account.binaryPath) {
            config["binaryPath"] = binary
        }
        switch account.provider {
        case .claude:
            if !account.importedDefault {
                config["homePath"] = account.homePath
            }
        case .codex:
            config["homePath"] = account.homePath
            if let shadow = account.shadowHomePath {
                config["shadowHomePath"] = shadow
            }
        case .cursor, .opencode:
            break
        }
        var environment: [T3EnvironmentVariable] = []
        for (key, value) in account.env.sorted(by: { $0.key < $1.key }) {
            if account.provider == .claude && key == "CLAUDE_CONFIG_DIR" { continue }
            if account.provider == .codex && key == "CODEX_HOME" { continue }
            environment.append(T3EnvironmentVariable(name: key, value: value))
        }
        return T3ProviderInstance(
            driver: account.provider.t3Driver,
            displayName: "\(account.provider.displayName) \(account.label)",
            config: config,
            environment: environment
        )
    }

    public func snippetJSON(for account: Account) throws -> String {
        let payload = [account.t3InstanceID: instance(for: account).asJSONObject()]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public func placement(of account: Account) -> T3AccountPlacement {
        if isVendorDefaultLogin(account) { return .nativeDefault }
        if exportedInstanceIDs().contains(account.t3InstanceID) { return .merged }
        return .notMerged
    }

    public func apply(accounts: [Account]) throws {
        let targets = settingsURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !targets.isEmpty else {
            throw HarnaisError.t3SettingsMissing
        }
        try apply(accounts: accounts, to: targets)
    }

    public func apply(accounts: [Account], to settingsURL: URL) throws {
        try apply(accounts: accounts, to: [settingsURL])
    }

    private func apply(accounts: [Account], to targets: [URL]) throws {
        // Validate every destination before touching any of them.
        let changes = try targets.map { url in
            guard FileManager.default.fileExists(atPath: url.path) else { throw HarnaisError.t3SettingsMissing }
            let original = try Data(contentsOf: url)
            return (url: url, original: original, output: try mergedSettings(accounts: accounts, data: original))
        }.filter { $0.original != $0.output }
        for change in changes {
            let directory = change.url.deletingLastPathComponent().appendingPathComponent("harnais-backups")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let backup = directory.appendingPathComponent("settings-\(UUID().uuidString).json")
            guard FileManager.default.createFile(atPath: backup.path, contents: change.original,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw HarnaisError.processFailed("Could not back up T3 Code settings. Sync was cancelled.")
            }
        }
        var written: [(url: URL, original: Data, output: Data)] = []
        do {
            for change in changes {
                guard try Data(contentsOf: change.url) == change.original else {
                    throw HarnaisError.processFailed("T3 Code settings changed during sync. Try again.")
                }
                try change.output.write(to: change.url, options: .atomic)
                written.append(change)
            }
        } catch {
            // Never roll back over a newer edit from T3. Each original is also backed up.
            for change in written.reversed() where (try? Data(contentsOf: change.url)) == change.output {
                try? change.original.write(to: change.url, options: .atomic)
            }
            throw error
        }
    }

    /// Pure preview, also used to verify sync against copies of real settings.
    public func mergedSettings(accounts: [Account], data: Data) throws -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["providerInstances"] == nil || root["providerInstances"] is [String: Any]
        else { throw HarnaisError.t3SettingsInvalid }
        var instances = root["providerInstances"] as? [String: Any] ?? [:]
        let ids = accounts.map(\.t3InstanceID)
        guard Set(ids).count == ids.count else {
            throw HarnaisError.processFailed("Two Harnais profiles have the same T3 Code identifier. Sync was cancelled.")
        }
        for account in accounts where shouldExport(account, into: instances) {
            let proposed = instance(for: account)
            let desired = proposed.asJSONObject()
            guard let saved = instances[account.t3InstanceID] else {
                instances[account.t3InstanceID] = desired
                continue
            }
            guard var existing = saved as? [String: Any],
                  existing["driver"] as? String == account.provider.t3Driver,
                  existing["config"] == nil || existing["config"] is [String: Any],
                  existing["environment"] == nil || existing["environment"] is [[String: Any]]
            else {
                throw HarnaisError.processFailed("The T3 Code profile for \(account.label) has an incompatible configuration. Sync was cancelled.")
            }
            existing["displayName"] = desired["displayName"]
            var config = existing["config"] as? [String: Any] ?? [:]
            for (key, value) in proposed.config { config[key] = value }
            // A removed shadow must not keep routing this profile to an old login.
            if account.provider == .codex { config["shadowHomePath"] = account.shadowHomePath }
            existing["config"] = config
            var environment = existing["environment"] as? [[String: Any]] ?? []
            let desiredEnvironment = desired["environment"] as? [[String: Any]] ?? []
            let names = Set(desiredEnvironment.compactMap { $0["name"] as? String })
            environment.removeAll { names.contains($0["name"] as? String ?? "") }
            environment.append(contentsOf: desiredEnvironment)
            if !environment.isEmpty || existing["environment"] != nil { existing["environment"] = environment }
            // Preserve enabled flags, model choices, launch options, secrets and unknown fields.
            instances[account.t3InstanceID] = existing
        }
        // Keep all existing IDs, including retired profiles referenced by conversations.
        root["providerInstances"] = instances
        if let original = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
           original.isEqual(to: root) { return data }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// T3 already shows a built-in slot for each driver (`claudeAgent`, `codex`,
    /// `cursor`) from `providers.<driver>`, even when that key is missing from
    /// `providerInstances`. Imported `~/.claude` / `~/.codex` / `~/.cursor`
    /// accounts are that same login, so writing `harnais_*` duplicates them.
    func shouldExport(_ account: Account, into instances: [String: Any]) -> Bool {
        if isVendorDefaultLogin(account) {
            return false
        }
        if instances[account.t3InstanceID] != nil { return true }
        let proposed = isolationIdentity(for: account)
        for (key, value) in instances where !key.hasPrefix("harnais_") {
            guard let object = value as? [String: Any],
                  let existing = isolationIdentity(from: object)
            else { continue }
            if existing == proposed {
                return false
            }
        }
        return true
    }
}

private struct T3IsolationIdentity: Equatable {
    var driver: String
    var homePath: String
    var shadowHomePath: String?
}

private extension T3Exporter {
    func exportedInstanceIDs() -> Set<String> {
        var ids: Set<String> = []
        for url in settingsURLs {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let instances = root["providerInstances"] as? [String: Any]
            else { continue }
            for key in instances.keys where key.hasPrefix("harnais_") {
                ids.insert(key)
            }
        }
        return ids
    }

    func isVendorDefaultLogin(_ account: Account) -> Bool {
        if account.shadowHomePath != nil {
            return false
        }
        if account.importedDefault {
            return true
        }
        return resolvedPath(account.homePath) == vendorDefaultHome(for: account.provider)
    }

    func isolationIdentity(for account: Account) -> T3IsolationIdentity {
        isolationIdentity(
            driver: account.provider.t3Driver,
            homePath: account.provider == .opencode ? AccountMetadata.openCodeAuthURL(for: account).deletingLastPathComponent().path : (account.importedDefault ? nil : account.homePath),
            shadowHomePath: account.shadowHomePath,
            provider: account.provider
        )
    }

    func isolationIdentity(from object: [String: Any]) -> T3IsolationIdentity? {
        guard let driver = object["driver"] as? String,
              let provider = provider(forDriver: driver)
        else { return nil }
        let config = object["config"] as? [String: Any] ?? [:]
        let environment = object["environment"] as? [[String: Any]] ?? []
        let openCodeData = environment.first { $0["name"] as? String == "XDG_DATA_HOME" }?["value"] as? String
        let cursorHome = environment.first { $0["name"] as? String == "CURSOR_CONFIG_DIR" }?["value"] as? String
        return isolationIdentity(
            driver: driver,
            homePath: provider == .opencode ? openCodeData.map { $0 + "/opencode" } : (provider == .cursor ? cursorHome : config["homePath"] as? String),
            shadowHomePath: config["shadowHomePath"] as? String,
            provider: provider
        )
    }

    func isolationIdentity(
        driver: String,
        homePath: String?,
        shadowHomePath: String?,
        provider: ProviderKind
    ) -> T3IsolationIdentity {
        T3IsolationIdentity(
            driver: driver,
            homePath: resolvedPath(homePath) ?? vendorDefaultHome(for: provider),
            shadowHomePath: resolvedPath(shadowHomePath)
        )
    }

    func provider(forDriver driver: String) -> ProviderKind? {
        ProviderKind.allCases.first { $0.t3Driver == driver }
    }

    func vendorDefaultHome(for provider: ProviderKind) -> String {
        let folder: String
        switch provider {
        case .claude: folder = ".claude"
        case .codex: folder = ".codex"
        case .cursor: folder = ".cursor"
        case .opencode: folder = ".local/share/opencode"
        }
        return homeDirectory.appendingPathComponent(folder).standardizedFileURL.path
    }

    func resolvedPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed == "~" {
            return homeDirectory.standardizedFileURL.path
        }
        if trimmed.hasPrefix("~/") {
            let rest = String(trimmed.dropFirst(2))
            return homeDirectory.appendingPathComponent(rest).standardizedFileURL.path
        }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            .standardizedFileURL.path
    }
}

extension T3ProviderInstance {
    func asJSONObject() -> [String: Any] {
        var object: [String: Any] = [
            "driver": driver,
            "displayName": displayName,
            "enabled": enabled,
            "config": config,
        ]
        if !environment.isEmpty {
            object["environment"] = environment.map {
                ["name": $0.name, "value": $0.value, "sensitive": $0.sensitive]
            }
        }
        return object
    }
}
