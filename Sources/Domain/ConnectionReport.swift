import Foundation

/// Visual treatment matching T3's provider status dots and headlines.
public enum ConnectionKind: String, Sendable, Equatable {
    case checking
    case ready
    case warning
    case error
}

/// One account's CLI + auth check, worded like T3 Settings → Providers.
public struct ConnectionReport: Sendable, Equatable {
    public var kind: ConnectionKind
    public var installed: Bool
    public var authenticated: Bool
    public var binaryPath: String?
    public var version: String?
    public var email: String?
    public var authLabel: String?
    public var headline: String
    public var detail: String?
    public var checkedAt: Date
    public var connectedAccounts: [ConnectedAccount] = []
    public var advisory: VersionAdvisory?

    public init(
        kind: ConnectionKind,
        installed: Bool,
        authenticated: Bool,
        binaryPath: String? = nil,
        version: String? = nil,
        email: String? = nil,
        authLabel: String? = nil,
        headline: String,
        detail: String? = nil,
        checkedAt: Date = Date(),
        advisory: VersionAdvisory? = nil
    ) {
        self.kind = kind
        self.installed = installed
        self.authenticated = authenticated
        self.binaryPath = binaryPath
        self.version = version
        self.email = email
        self.authLabel = authLabel
        self.headline = headline
        self.detail = detail
        self.checkedAt = checkedAt
        self.advisory = advisory
    }

    public var showsStatusDot: Bool {
        kind == .warning || kind == .error
    }

    /// T3 prefixes a `v` when the driver reported a version that starts with a digit.
    public var versionLabel: String? {
        guard let version, !version.isEmpty else { return nil }
        if let first = version.first, first.isNumber {
            return "v\(version)"
        }
        return version
    }

    public static func pending(checkedAt: Date = Date()) -> ConnectionReport {
        ConnectionReport(
            kind: .checking,
            installed: false,
            authenticated: false,
            headline: "Checking provider status",
            detail: "Waiting for installation and authentication details.",
            checkedAt: checkedAt
        )
    }

    public static func resolved(
        installed: Bool,
        binaryPath: String? = nil,
        version: String? = nil,
        authenticated: Bool,
        email: String? = nil,
        authLabel: String? = nil,
        message: String? = nil,
        kind: ConnectionKind? = nil,
        checkedAt: Date = Date()
    ) -> ConnectionReport {
        let resolvedKind: ConnectionKind
        if let kind {
            resolvedKind = kind
        } else if !installed || !authenticated {
            resolvedKind = .error
        } else {
            resolvedKind = .ready
        }

        let headline: String
        let detail: String?
        if !installed {
            headline = "Not found"
            detail = message ?? "CLI not detected on PATH."
        } else if !authenticated {
            headline = "Not authenticated"
            detail = message
        } else if resolvedKind == .warning {
            headline = "Needs attention"
            detail = message ?? "The provider is installed, but Harnais could not fully verify it."
        } else if resolvedKind == .error {
            headline = "Unavailable"
            detail = message ?? "The provider failed its startup checks."
        } else {
            let label = [authLabel, email].compactMap(Self.displayAuthLabel).first
            headline = label.map { "Authenticated · \($0)" } ?? "Authenticated"
            detail = message
        }

        return ConnectionReport(
            kind: resolvedKind,
            installed: installed,
            authenticated: authenticated,
            binaryPath: binaryPath,
            version: version,
            email: email?.contains("@") == true ? email : nil,
            authLabel: authLabel,
            headline: headline,
            detail: detail,
            checkedAt: checkedAt,
            advisory: nil
        )
    }

    public func withConnectedAccounts(_ accounts: [ConnectedAccount]) -> ConnectionReport {
        var copy = self
        copy.connectedAccounts = accounts
        return copy
    }

    public func withAdvisory(_ advisory: VersionAdvisory?) -> ConnectionReport {
        var copy = self
        copy.advisory = advisory
        return copy
    }

    public static func lastCheckedLabel(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Check connection" }
        let parts = lastCheckedParts(from: date, now: now)
        if let suffix = parts.suffix {
            return "Checked \(parts.value) \(suffix)"
        }
        return "Checked \(parts.value)"
    }

    public static func updatedAgoLabel(from date: Date?, now: Date = Date()) -> String? {
        guard date != nil else { return nil }
        let parts = lastCheckedParts(from: date, now: now)
        if let suffix = parts.suffix {
            return "Updated \(parts.value) \(suffix)"
        }
        return "Updated \(parts.value)"
    }

    public static func lastCheckedParts(from date: Date?, now: Date = Date()) -> (value: String, suffix: String?) {
        guard let date else { return ("connection", nil) }
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return ("just now", nil) }
        if seconds < 3600 { return ("\(Int(seconds / 60))m", "ago") }
        if seconds < 86_400 { return ("\(Int(seconds / 3600))h", "ago") }
        return ("\(Int(seconds / 86_400))d", "ago")
    }

    private static func displayAuthLabel(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.contains("@") { return value }
        let hyphenCount = value.filter { $0 == "-" }.count
        if hyphenCount >= 4 { return nil }
        if value.count > 40 { return nil }
        return value
    }
}
