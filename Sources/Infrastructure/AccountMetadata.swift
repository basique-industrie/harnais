import Domain
import Foundation

/// Reads vendor metadata after login, without copying tokens.
public struct AccountMetadata: Sendable {
    public init() {}

    public func planLabel(for account: Account) -> String? {
        switch account.provider {
        case .claude:
            return SubscriptionLabel.claude(
                subscriptionType: claudeSubscriptionType(
                    configDir: account.env["CLAUDE_CONFIG_DIR"] ?? defaultClaudeDir(account)
                ),
                authMethod: nil
            )
        case .codex:
            return SubscriptionLabel.codex(planType: codexPlanType(for: account))
        case .opencode:
            let logins = OpenCodeAccountReader.accounts(for: account)
            if logins.count == 1 { return logins[0].plan ?? logins[0].loginMethod }
            return logins.isEmpty ? nil : "\(logins.count) providers"
        case .cursor:
            return nil
        }
    }

    public func codexPlanType(for account: Account) -> String? {
        codexPlanType(home: account.env["CODEX_HOME"] ?? account.homePath)
    }

    private func claudeSubscriptionType(configDir: String) -> String? {
        let url = URL(fileURLWithPath: configDir).appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let type = oauth["subscriptionType"] as? String,
              !type.isEmpty
        else { return nil }
        return type
    }

    private func codexPlanType(home: String) -> String? {
        let auth = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: auth),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let plan = root["plan_type"] as? String ?? root["chatgpt_plan_type"] as? String {
            return plan
        }
        let tokens = root["tokens"] as? [String: Any] ?? [:]
        if let plan = tokens["plan_type"] as? String ?? tokens["chatgpt_plan_type"] as? String {
            return plan
        }
        guard let access = tokens["access_token"] as? String,
              let claims = JWTPayload.dictionary(access)
        else { return nil }
        let chatgpt = claims["https://api.openai.com/auth"] as? [String: Any]
        return chatgpt?["chatgpt_plan_type"] as? String
    }

    public func email(for account: Account) -> String? {
        switch account.provider {
        case .claude:
            return claudeEmail(configDir: account.env["CLAUDE_CONFIG_DIR"] ?? defaultClaudeDir(account))
        case .codex:
            return codexEmail(home: account.env["CODEX_HOME"] ?? account.homePath)
        case .opencode:
            let logins = OpenCodeAccountReader.accounts(for: account)
            return logins.count == 1 ? logins[0].email : nil
        case .cursor:
            return cursorEmail(configDir: account.env["CURSOR_CONFIG_DIR"] ?? account.homePath)
        }
    }

    public func appearsSignedIn(_ account: Account) -> Bool {
        if email(for: account) != nil { return true }
        switch account.provider {
        case .opencode:
            return !OpenCodeAccountReader.accounts(for: account).isEmpty
        case .claude:
            let dir = account.env["CLAUDE_CONFIG_DIR"] ?? defaultClaudeDir(account)
            let credentials = URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json")
            let claudeJSON = URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
            return FileManager.default.fileExists(atPath: credentials.path)
                || FileManager.default.fileExists(atPath: claudeJSON.path)
        case .codex:
            let home = account.env["CODEX_HOME"] ?? account.shadowHomePath ?? account.homePath
            return FileManager.default.fileExists(atPath: (home as NSString).appendingPathComponent("auth.json"))
        case .cursor:
            let dir = account.env["CURSOR_CONFIG_DIR"] ?? account.homePath
            return FileManager.default.fileExists(
                atPath: (dir as NSString).appendingPathComponent("auth.json")
            )
        }
    }

    /// Size and mtime of vendor login files. Used to detect a fresh login without
    /// treating a stale `auth.json` as success.
    public func credentialSnapshot(for account: Account) -> CredentialSnapshot {
        var files: [String: CredentialSnapshot.File] = [:]
        for url in credentialURLs(for: account) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? NSNumber
            else { continue }
            files[url.path] = CredentialSnapshot.File(
                modified: modified.timeIntervalSince1970,
                size: size.intValue
            )
        }
        return CredentialSnapshot(files: files)
    }

    public func loginCompleted(_ account: Account, since baseline: CredentialSnapshot) -> Bool {
        appearsSignedIn(account) && credentialSnapshot(for: account) != baseline
    }

    private func credentialURLs(for account: Account) -> [URL] {
        switch account.provider {
        case .opencode:
            return [Self.openCodeAuthURL(for: account)]
        case .claude:
            let dir = URL(fileURLWithPath: account.env["CLAUDE_CONFIG_DIR"] ?? defaultClaudeDir(account))
            return [
                dir.appendingPathComponent(".credentials.json"),
                dir.appendingPathComponent(".claude.json"),
            ]
        case .codex:
            let home = URL(fileURLWithPath: account.env["CODEX_HOME"] ?? account.shadowHomePath ?? account.homePath)
            return [home.appendingPathComponent("auth.json")]
        case .cursor:
            let dir = URL(fileURLWithPath: account.env["CURSOR_CONFIG_DIR"] ?? account.homePath)
            return [dir.appendingPathComponent("auth.json")]
        }
    }

    public static func openCodeAuthURL(for account: Account) -> URL {
        if let dataHome = account.env["XDG_DATA_HOME"] {
            return URL(fileURLWithPath: dataHome).appendingPathComponent("opencode/auth.json")
        }
        return URL(fileURLWithPath: account.homePath).appendingPathComponent("auth.json")
    }

    private func defaultClaudeDir(_ account: Account) -> String {
        if account.importedDefault {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        }
        return account.homePath
    }

    private func claudeEmail(configDir: String) -> String? {
        let url = URL(fileURLWithPath: configDir).appendingPathComponent(".claude.json")
        let homeFallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        for candidate in [url, homeFallback] {
            guard let data = try? Data(contentsOf: candidate),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = root["oauthAccount"] as? [String: Any],
                  let email = oauth["emailAddress"] as? String,
                  !email.isEmpty
            else { continue }
            return email
        }
        return nil
    }

    private func codexEmail(home: String) -> String? {
        let auth = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: auth),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let email = JWTPayload.mailbox(root["email"] as? String) { return email }
        let tokens = root["tokens"] as? [String: Any] ?? [:]
        if let email = JWTPayload.mailbox(tokens["email"] as? String) { return email }
        for key in ["id_token", "access_token"] {
            if let token = tokens[key] as? String, let email = JWTPayload.email(token) {
                return email
            }
        }
        return nil
    }

    private func cursorEmail(configDir: String) -> String? {
        let auth = URL(fileURLWithPath: configDir).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: auth),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let email = JWTPayload.mailbox(root["email"] as? String) { return email }
        if let token = root["accessToken"] as? String ?? root["access_token"] as? String {
            return JWTPayload.email(token)
        }
        return nil
    }
}

public struct CredentialSnapshot: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public var modified: TimeInterval
        public var size: Int

        public init(modified: TimeInterval, size: Int) {
            self.modified = modified
            self.size = size
        }
    }

    public var files: [String: File]

    public init(files: [String: File] = [:]) {
        self.files = files
    }
}
