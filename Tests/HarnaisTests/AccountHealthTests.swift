import Domain
import Foundation
import Infrastructure

enum AccountHealthTests {
    static func run(expect: (Bool, String) -> Void) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = Account(provider: .cursor, label: "private-label@example.test", slug: "health", homePath: "/private-home", accountEmail: "expected@example.test")
        let ready = ConnectionReport.resolved(installed: true, binaryPath: "/private-cli", authenticated: true,
                                              email: "expected@example.test", message: "TOKEN-do-not-copy", checkedAt: now)
        let quota = AccountQuotaSnapshot(id: account.id.uuidString, provider: "cursor", label: "private", email: "expected@example.test",
                                         quotas: [FeedQuota(type: "weekly", percentRemaining: 40)])
        let signedIn = T3ProviderStatus(instanceID: account.t3InstanceID, driver: "cursor", auth: .authenticated,
                                        email: "expected@example.test", checkedAt: now)
        func evaluate(report: ConnectionReport? = ready, usage: AccountQuotaSnapshot? = quota, date: Date? = now,
                      t3: T3ProviderStatus? = signedIn, wrapper: Bool = true, path: Bool = true, drift: Bool? = false) -> AccountHealth {
            AccountHealth.evaluate(account: account, report: report, quota: usage, quotaDate: date,
                                   placement: .merged, t3: t3, wrapperReady: wrapper, pathReady: path, syncDrift: drift,
                                   inventoryWarnings: 0, inventoryDate: now, now: now)
        }
        expect(evaluate().state == .ready, "fresh complete health is ready")
        expect(evaluate(report: nil).checks.first?.state == .unknown, "unchecked account is unknown instead of signed out")
        var stale = ready
        stale.checkedAt = now.addingTimeInterval(-901)
        expect(evaluate(report: stale).checks.first?.state == .unknown, "old login reports are unverified")
        let quotaUnavailable = evaluate(usage: nil)
        expect(quotaUnavailable.checks.first { $0.id == "login" }?.state == .ready, "missing usage does not invalidate sign-in")
        expect(quotaUnavailable.checks.first { $0.id == "usage" }?.state == .unknown, "missing usage is explicitly unknown")
        expect(evaluate(date: now.addingTimeInterval(-901)).checks.first { $0.id == "usage" }?.state == .unknown, "stale quota is not presented as current")
        expect(evaluate(wrapper: false).checks.first { $0.id == "command" }?.state == .attention, "wrong command routing needs attention")
        expect(evaluate(path: false).state == .attention, "missing PATH configuration needs attention")
        expect(evaluate(drift: true).checks.first { $0.id == "t3-sync" }?.state == .attention, "T3 drift is surfaced")
        expect(evaluate(drift: nil).checks.first { $0.id == "t3-sync" }?.state == .unknown, "unreadable T3 settings are not shown synced")
        expect(evaluate(t3: nil).checks.first { $0.id == "t3-login" }?.state == .unknown, "missing T3 status is not signed out")
        var other = signedIn
        other.email = "different@example.test"
        expect(evaluate(t3: other).checks.first { $0.id == "t3-login" }?.state == .attention, "different T3 identity is detected")
        other = signedIn
        other.checkedAt = now.addingTimeInterval(-901)
        expect(evaluate(t3: other).checks.first { $0.id == "t3-login" }?.state == .unknown, "stale T3 identity is unverified")
        let unreadable = AccountHealth.evaluate(account: account, report: ready, quota: quota, quotaDate: now,
            placement: .notMerged, t3: nil, hasT3Settings: true, wrapperReady: true, pathReady: true,
            syncDrift: nil, inventoryWarnings: nil, inventoryDate: nil, now: now)
        expect(unreadable.checks.first { $0.id == "t3-sync" }?.state == .unknown, "unreadable T3 settings do not imply a profile was never added")
        expect(unreadable.checks.first { $0.id == "connections" }?.state == .unknown, "failed inventory remains unverified")
        let diagnostic = String(decoding: try JSONEncoder().encode(evaluate()), as: UTF8.self)
        expect(!diagnostic.contains("@") && !diagnostic.contains("/private") && !diagnostic.contains("TOKEN"),
               "diagnostic output excludes emails, paths, labels and provider output")
    }
}
