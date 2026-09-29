import Domain
import Foundation

/// Encodes Claude / Codex / Cursor isolation so callers never invent HOME overrides.
public struct IsolationEngine: Sendable {
    public var identity: AppIdentity
    public var homeDirectory: URL
    public var profilesRoot: URL

    public init(
        identity: AppIdentity = .current,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        profilesRoot: URL? = nil
    ) {
        self.identity = identity
        self.homeDirectory = homeDirectory
        self.profilesRoot = profilesRoot ?? identity.profilesDirectory
    }

    public func plan(
        provider: ProviderKind,
        slug: String,
        importDefault: Bool,
        codexMode: CodexIsolationMode = .isolated
    ) -> IsolationPlan {
        switch provider {
        case .claude:
            if importDefault {
                return IsolationPlan(
                    homePath: homeDirectory.appendingPathComponent(".claude").path,
                    env: [:],
                    importedDefault: true
                )
            }
            let home = profilePath(provider: .claude, slug: slug)
            return IsolationPlan(homePath: home, env: ["CLAUDE_CONFIG_DIR": home])
        case .codex:
            if importDefault {
                return IsolationPlan(
                    homePath: homeDirectory.appendingPathComponent(".codex").path,
                    env: ["CODEX_HOME": homeDirectory.appendingPathComponent(".codex").path],
                    importedDefault: true,
                    codexMode: .isolated
                )
            }
            if codexMode == .t3Shadow {
                let shared = homeDirectory.appendingPathComponent(".codex").path
                let shadow = profilePath(provider: .codex, slug: slug)
                return IsolationPlan(
                    homePath: shared,
                    shadowHomePath: shadow,
                    env: ["CODEX_HOME": shadow],
                    codexMode: .t3Shadow
                )
            }
            let home = profilePath(provider: .codex, slug: slug)
            return IsolationPlan(
                homePath: home,
                env: ["CODEX_HOME": home],
                codexMode: .isolated
            )
        case .opencode:
            if importDefault {
                return IsolationPlan(
                    homePath: homeDirectory.appendingPathComponent(".local/share/opencode").path,
                    env: [:], importedDefault: true
                )
            }
            let home = profilePath(provider: .opencode, slug: slug)
            return IsolationPlan(homePath: home, env: [
                "XDG_DATA_HOME": home + "/data",
                "XDG_CONFIG_HOME": home + "/config",
                "XDG_CACHE_HOME": home + "/cache",
                "XDG_STATE_HOME": home + "/state",
            ])
        case .cursor:
            if importDefault {
                return IsolationPlan(
                    homePath: homeDirectory.appendingPathComponent(".cursor").path,
                    env: [:],
                    importedDefault: true
                )
            }
            let home = profilePath(provider: .cursor, slug: slug)
            return IsolationPlan(
                homePath: home,
                env: [
                    "CURSOR_CONFIG_DIR": home,
                    "AGENT_CLI_CREDENTIAL_STORE": "file",
                ]
            )
        }
    }

    public func profilePath(provider: ProviderKind, slug: String) -> String {
        profilesRoot
            .appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .path
    }

    public func materialize(_ plan: IsolationPlan) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: plan.homePath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if let shadow = plan.shadowHomePath {
            try fm.createDirectory(
                atPath: shadow,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    public func spawnEnvironment(for account: Account) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BinaryLocator.shellPath()
        env.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        for (key, value) in account.env {
            env[key] = (value as NSString).expandingTildeInPath
        }
        return env
    }

    /// True when `path` is inside `~/.harnais/profiles`, never `~/.claude` / `~/.codex`.
    public func isManaged(_ path: String) -> Bool {
        let root = profilesRoot.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return candidate == root || candidate.hasPrefix(prefix)
    }

    /// Deletes Harnais-created profile folders. Imported vendor homes stay.
    public func removeManagedHomes(for account: Account) {
        if let shadow = account.shadowHomePath, isManaged(shadow) {
            try? FileManager.default.removeItem(atPath: shadow)
        }
        if !account.importedDefault, isManaged(account.homePath) {
            try? FileManager.default.removeItem(atPath: account.homePath)
        }
    }
}
