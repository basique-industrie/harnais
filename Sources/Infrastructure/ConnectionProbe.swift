import Domain
import Foundation

/// CLI + auth health check, using the same commands T3 uses (`--version`,
/// `claude auth status`, `agent about`) plus on-disk metadata for Codex.
public struct ConnectionProbe: Sendable {
    public var runner: ProcessRunner
    public var metadata: AccountMetadata
    public var isolation: IsolationEngine

    public init(
        runner: ProcessRunner = ProcessRunner(),
        metadata: AccountMetadata = AccountMetadata(),
        isolation: IsolationEngine = IsolationEngine()
    ) {
        self.runner = runner
        self.metadata = metadata
        self.isolation = isolation
    }

    /// PATH + vendor files only. Used for the first paint before a live probe.
    public func snapshot(_ account: Account) -> ConnectionReport {
        let binary = BinaryLocator.resolve(account.provider, override: account.binaryPath)
        let email = metadata.email(for: account) ?? (account.provider == .opencode ? nil : JWTPayload.mailbox(account.accountEmail))
        let signedIn = metadata.appearsSignedIn(account)
        return ConnectionReport.resolved(
            installed: binary != nil,
            binaryPath: binary,
            authenticated: signedIn,
            email: email,
            authLabel: metadata.planLabel(for: account),
            message: Self.unauthenticatedMessage(for: account.provider, signedIn: signedIn, installed: binary != nil)
        ).withConnectedAccounts(OpenCodeAccountReader.accounts(for: account))
    }

    public func probe(_ account: Account) -> ConnectionReport {
        let binary = BinaryLocator.resolve(account.provider, override: account.binaryPath)
        let checkedAt = Date()
        let diskEmail = metadata.email(for: account) ?? (account.provider == .opencode ? nil : JWTPayload.mailbox(account.accountEmail))
        let diskSignedIn = metadata.appearsSignedIn(account)

        guard let binary else {
            return ConnectionReport.resolved(
                installed: false,
                authenticated: false,
                email: diskEmail,
                message: "CLI not detected on PATH.",
                checkedAt: checkedAt
            ).withConnectedAccounts(OpenCodeAccountReader.accounts(for: account))
        }

        let versionResult = run(account, executable: binary, arguments: ["--version"], timeout: 4)
        let versionOutput = versionResult?.output ?? ""
        let version = ConnectionProbe.parseVersion(versionOutput)
        let report: ConnectionReport

        if let versionResult, versionResult.exitCode != 0 {
            report = ConnectionReport.resolved(
                installed: true,
                binaryPath: binary,
                version: version,
                authenticated: diskSignedIn,
                email: diskEmail,
                message: "\(account.provider.displayName) CLI is installed but failed to run.",
                kind: .error,
                checkedAt: checkedAt
            )
        } else if versionResult == nil {
            report = ConnectionReport.resolved(
                installed: true,
                binaryPath: binary,
                version: version,
                authenticated: diskSignedIn,
                email: diskEmail,
                message: "\(account.provider.displayName) CLI is installed but timed out while running `--version`.",
                kind: diskSignedIn ? .warning : .error,
                checkedAt: checkedAt
            )
        } else {
            switch account.provider {
            case .claude:
                report = probeClaude(
                    account: account,
                    binary: binary,
                    version: version,
                    diskEmail: diskEmail,
                    diskSignedIn: diskSignedIn,
                    checkedAt: checkedAt
                )
            case .codex, .opencode:
                report = ConnectionReport.resolved(
                    installed: true,
                    binaryPath: binary,
                    version: version,
                    authenticated: diskSignedIn,
                    email: diskEmail,
                    authLabel: metadata.planLabel(for: account),
                    message: Self.unauthenticatedMessage(for: account.provider, signedIn: diskSignedIn, installed: true),
                    checkedAt: checkedAt
                )
            case .cursor:
                report = probeCursor(
                    account: account,
                    binary: binary,
                    version: version,
                    diskEmail: diskEmail,
                    diskSignedIn: diskSignedIn,
                    checkedAt: checkedAt
                )
            }
        }
        return annotate(report, account: account, binary: binary)
    }

    private func annotate(_ report: ConnectionReport, account: Account, binary: String) -> ConnectionReport {
        let advisory = BinaryUpdater(runner: runner).advisory(
            provider: account.provider,
            binaryPath: binary,
            currentVersion: report.version,
            environment: isolation.spawnEnvironment(for: account)
        )
        return report.withAdvisory(advisory).withConnectedAccounts(OpenCodeAccountReader.accounts(for: account))
    }

    private func probeClaude(
        account: Account,
        binary: String,
        version: String?,
        diskEmail: String?,
        diskSignedIn: Bool,
        checkedAt: Date
    ) -> ConnectionReport {
        guard let result = run(account, executable: binary, arguments: ["auth", "status"], timeout: 8) else {
            return ConnectionReport.resolved(
                installed: true,
                binaryPath: binary,
                version: version,
                authenticated: diskSignedIn,
                email: diskEmail,
                message: diskSignedIn
                    ? "Could not verify Claude authentication status."
                    : "Claude Agent CLI is installed but timed out while running `auth status`.",
                kind: diskSignedIn ? .warning : .error,
                checkedAt: checkedAt
            )
        }
        let parsed = ConnectionProbe.parseClaudeAuth(result.output)
        let authenticated = parsed?.authenticated ?? diskSignedIn
        let email = parsed?.email ?? diskEmail
        let label = parsed?.label ?? metadata.planLabel(for: account)
        var message = Self.unauthenticatedMessage(for: .claude, signedIn: authenticated, installed: true)
        if parsed == nil, diskSignedIn {
            message = "Could not verify Claude authentication status."
        }
        return ConnectionReport.resolved(
            installed: true,
            binaryPath: binary,
            version: version,
            authenticated: authenticated,
            email: email,
            authLabel: label,
            message: message,
            kind: parsed == nil && diskSignedIn ? .warning : nil,
            checkedAt: checkedAt
        )
    }

    private func probeCursor(
        account: Account,
        binary: String,
        version: String?,
        diskEmail: String?,
        diskSignedIn: Bool,
        checkedAt: Date
    ) -> ConnectionReport {
        guard let result = run(account, executable: binary, arguments: ["about"], timeout: 12) else {
            return ConnectionReport.resolved(
                installed: true,
                binaryPath: binary,
                version: version,
                authenticated: diskSignedIn,
                email: diskEmail,
                message: diskSignedIn
                    ? "Could not verify Cursor Agent authentication status."
                    : "Cursor Agent CLI is installed but timed out while running `agent about`.",
                kind: diskSignedIn ? .warning : .error,
                checkedAt: checkedAt
            )
        }
        let parsed = ConnectionProbe.parseCursorAbout(result.output)
        if parsed.unknownCommand {
            return ConnectionReport.resolved(
                installed: true,
                binaryPath: binary,
                version: version ?? parsed.version,
                authenticated: diskSignedIn,
                email: diskEmail,
                message: "The `agent about` command is unavailable in this version of the Cursor Agent CLI.",
                kind: .warning,
                checkedAt: checkedAt
            )
        }
        let authenticated = parsed.authenticated ?? diskSignedIn
        let email = parsed.email ?? diskEmail
        return ConnectionReport.resolved(
            installed: true,
            binaryPath: binary,
            version: parsed.version ?? version,
            authenticated: authenticated,
            email: email,
            authLabel: SubscriptionLabel.cursor(tier: parsed.subscriptionTier),
            message: Self.unauthenticatedMessage(for: .cursor, signedIn: authenticated, installed: true),
            checkedAt: checkedAt
        )
    }

    private func run(
        _ account: Account,
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ProcessResult? {
        let env = isolation.spawnEnvironment(for: account)
        do {
            return try runner.run(
                executable: executable,
                arguments: arguments,
                environment: env,
                timeout: timeout
            )
        } catch {
            return nil
        }
    }

    public static func parseVersion(_ output: String) -> String? {
        let ns = output as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = try? NSRegularExpression(pattern: #"\b(\d{4}\.\d{2}\.\d{2}[-\w.]*)"#)
            .firstMatch(in: output, range: range)
        {
            return ns.substring(with: match.range(at: 1))
        }
        if let match = try? NSRegularExpression(pattern: #"\b(\d+\.\d+\.\d+)\b"#)
            .firstMatch(in: output, range: range)
        {
            return ns.substring(with: match.range(at: 1))
        }
        return nil
    }

    public static func parseClaudeAuth(_ output: String) -> (authenticated: Bool, email: String?, label: String?)? {
        if let json = firstJSONObject(in: output) {
            let loggedIn = bool(json["loggedIn"]) ?? bool(json["authenticated"])
            if let loggedIn {
                let email = string(json["email"]) ?? string(json["emailAddress"])
                let label = SubscriptionLabel.claude(
                    subscriptionType: string(json["subscriptionType"]),
                    authMethod: string(json["authMethod"])
                )
                return (loggedIn, email, label)
            }
        }
        let lower = output.lowercased()
        if lower.contains("not logged in") || lower.contains("not authenticated") {
            return (false, nil, nil)
        }
        if lower.contains("logged in") {
            let email = output.split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .first(where: { $0.contains("@") })
            return (true, email, nil)
        }
        return nil
    }

    public struct CursorAboutParse: Sendable, Equatable {
        public var version: String? = nil
        public var email: String? = nil
        public var authenticated: Bool? = nil
        public var subscriptionTier: String? = nil
        public var unknownCommand: Bool = false
    }

    public static func parseCursorAbout(_ output: String) -> CursorAboutParse {
        let lower = output.lowercased()
        if lower.contains("unknown command")
            || lower.contains("unrecognized command")
            || lower.contains("unexpected argument")
        {
            return CursorAboutParse(unknownCommand: true)
        }
        if let json = firstJSONObject(in: output) {
            let version = string(json["cliVersion"]) ?? string(json["version"])
            let tier = string(json["subscriptionTier"])
            if json.keys.contains("userEmail"), json["userEmail"] is NSNull {
                return CursorAboutParse(version: version, authenticated: false, subscriptionTier: tier)
            }
            if let email = string(json["userEmail"]) {
                return cursorEmailResult(version: version, email: email, subscriptionTier: tier)
            }
        }
        let version = aboutField(output, name: "CLI Version") ?? parseVersion(output)
        let tier = aboutField(output, name: "Subscription Tier")
        if let email = aboutField(output, name: "User Email") {
            return cursorEmailResult(version: version, email: email, subscriptionTier: tier)
        }
        return CursorAboutParse(version: version, subscriptionTier: tier)
    }

    private static func cursorEmailResult(
        version: String?,
        email: String,
        subscriptionTier: String? = nil
    ) -> CursorAboutParse {
        let lower = email.lowercased()
        if lower == "not logged in"
            || lower.contains("login required")
            || lower.contains("authentication required")
        {
            return CursorAboutParse(version: version, authenticated: false, subscriptionTier: subscriptionTier)
        }
        return CursorAboutParse(
            version: version,
            email: email,
            authenticated: true,
            subscriptionTier: subscriptionTier
        )
    }

    private static func unauthenticatedMessage(
        for provider: ProviderKind,
        signedIn: Bool,
        installed: Bool
    ) -> String? {
        guard installed, !signedIn else { return nil }
        switch provider {
        case .claude:
            return "Claude Agent CLI is not authenticated. Run `claude auth login` and try again."
        case .codex:
            return "Codex CLI is not authenticated. Run `codex login` and try again."
        case .opencode:
            return "Connect a provider with `opencode auth login`."
        case .cursor:
            return "Cursor Agent is not authenticated. Run `agent login` and try again."
        }
    }

    private static func firstJSONObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"),
              let end = text[start...].lastIndex(of: "}")
        else { return nil }
        let slice = String(text[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
    }

    private static func aboutField(_ output: String, name: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix(name.lowercased()) else { continue }
            let value = trimmed.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
