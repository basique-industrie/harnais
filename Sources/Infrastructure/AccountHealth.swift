import Domain
import Foundation

public enum HealthState: String, Codable, Sendable {
    case ready, attention, unknown, notUsed
    public var title: String {
        switch self {
        case .ready: "Ready"
        case .attention: "Needs attention"
        case .unknown: "Not verified"
        case .notUsed: "Not used"
        }
    }
}

public struct AccountHealthCheck: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var state: HealthState
    public var detail: String
    public var checkedAt: Date?
    public var nextStep: String?
}

public struct AccountHealth: Codable, Sendable, Identifiable {
    public var id: UUID
    public var provider: String
    public var checks: [AccountHealthCheck]
    public var state: HealthState {
        if checks.contains(where: { $0.state == .attention }) { return .attention }
        if checks.contains(where: { $0.state == .unknown }) { return .unknown }
        return .ready
    }

    /// All descriptions are curated, never provider error strings, credential
    /// values, local paths, emails or command output. Safe to copy for support.
    public static func evaluate(account: Account, report: ConnectionReport?,
                                quota: AccountQuotaSnapshot?, quotaDate: Date?,
                                placement: T3AccountPlacement, t3: T3ProviderStatus?,
                                wrapperReady: Bool, pathReady: Bool, syncDrift: Bool?,
                                inventoryWarnings: Int?, inventoryDate: Date?, now: Date = Date()) -> AccountHealth {
        var checks: [AccountHealthCheck] = []
        func add(_ id: String, _ title: String, _ state: HealthState, _ detail: String,
                 _ date: Date? = nil, _ next: String? = nil) {
            checks.append(AccountHealthCheck(id: id, title: title, state: state, detail: detail, checkedAt: date, nextStep: next))
        }
        let current = report.map { $0.kind != .checking && fresh($0.checkedAt, now: now) } ?? false
        if !current {
            add("cli", "CLI and local sign-in", .unknown, "No recent account check.", report?.checkedAt, "Run Check accounts.")
        } else if let report {
            add("cli", "CLI", report.installed ? .ready : .attention,
                report.installed ? "Provider command found." : "Provider command is missing.", report.checkedAt,
                report.installed ? nil : "Open Binaries to install or select the provider command.")
            let mismatch = emailsDiffer(account.accountEmail, report.email)
            let warning = !report.authenticated || mismatch || report.kind == .warning || report.kind == .error
            add("login", "Local sign-in", warning ? .attention : .ready,
                mismatch ? "The detected login differs from this account’s saved identity."
                    : report.authenticated ? "Sign-in data detected." : "No local sign-in was detected.", report.checkedAt,
                warning ? "Open the account and check its sign-in." : nil)
        }
        add("command", "Account command", wrapperReady && pathReady ? .ready : .attention,
            !wrapperReady ? "The isolated account command is missing or out of date."
                : !pathReady ? "Account commands are not configured on PATH." : "Command routing and PATH are configured.", now,
            !wrapperReady ? "Repair this account command." : !pathReady ? "Open Settings and add account commands to PATH." : nil)

        switch placement {
        case .notMerged:
            add("t3-sync", "T3 profile", .notUsed, "This account has not been added to T3.")
        case .nativeDefault:
            add("t3-sync", "T3 profile", .ready, "Uses T3’s built-in provider slot.", now)
        case .merged:
            add("t3-sync", "T3 profile", syncDrift == nil ? .unknown : syncDrift == true ? .attention : .ready,
                syncDrift == nil ? "Could not compare T3 settings." : syncDrift == true ? "T3 settings differ from the Harnais profile." : "Managed settings match.", now,
                syncDrift == true ? "Preview a sync in Sync history." : nil)
        }
        if placement != .notMerged {
            if let t3, fresh(t3.checkedAt, now: now) {
                let mismatch = emailsDiffer(report?.email ?? account.accountEmail, t3.email)
                let state: HealthState = mismatch || t3.auth == .unauthenticated ? .attention : t3.auth == .authenticated ? .ready : .unknown
                add("t3-login", "T3 sign-in", state,
                    mismatch ? "T3 reports a different account identity." : t3.auth == .authenticated ? "T3 reports a signed-in provider." : "T3 sign-in is unavailable or not verified.", t3.checkedAt,
                    state == .ready ? nil : "Open the account’s T3 section and check sign-in.")
            } else {
                add("t3-login", "T3 sign-in", .unknown, "T3’s sign-in status is missing or stale.", t3?.checkedAt, "Open T3 and check the provider.")
            }
        }
        if let quota, quota.error == nil, !quota.quotas.isEmpty, fresh(quotaDate, now: now) {
            let exhausted = quota.quotas.contains { $0.percentRemaining <= 0 }
            let mismatch = emailsDiffer(report?.email ?? account.accountEmail, quota.email)
            add("usage", "Usage", exhausted || mismatch ? .attention : .ready,
                mismatch ? "Usage belongs to a different sign-in." : exhausted ? "At least one usage window is exhausted." : "Recent usage is available.", quotaDate,
                mismatch ? "Check account sign-in, then refresh Usage." : exhausted ? "Open Usage to see the reset time." : nil)
        } else {
            add("usage", "Usage", .unknown, "Usage is missing, stale or unavailable.", quotaDate, "Refresh Usage; sign-in may still be valid.")
        }
        if let warnings = inventoryWarnings, fresh(inventoryDate, now: now) {
            add("connections", "Connection configuration", warnings == 0 ? .ready : .attention,
                warnings == 0 ? "No local configuration warnings. Remote services were not contacted." : "Local connection configuration has warnings.", inventoryDate,
                warnings == 0 ? nil : "Open Connections to review warnings.")
        } else {
            add("connections", "Connection configuration", .unknown, "No recent configuration inventory.", inventoryDate, "Refresh the connection inventory.")
        }
        return AccountHealth(id: account.id, provider: account.provider.rawValue, checks: checks)
    }

    public static func wrapperReady(_ account: Account, identity: AppIdentity = .current) -> Bool {
        guard let binary = BinaryLocator.resolve(account.provider, override: account.binaryPath) else { return false }
        let url = identity.binDirectory.appendingPathComponent(account.wrapperName)
        return FileManager.default.isExecutableFile(atPath: url.path)
            && (try? String(contentsOf: url, encoding: .utf8)) == WrapperGenerator.script(for: account, binaryPath: binary)
    }

    private static func fresh(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        return (-60...900).contains(now.timeIntervalSince(date))
    }
    private static func emailsDiffer(_ expected: String?, _ actual: String?) -> Bool {
        guard let expected, let actual, expected.contains("@"), actual.contains("@") else { return false }
        return expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            != actual.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
