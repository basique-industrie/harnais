import Domain
import Foundation

/// Local diagnostics only: no sign-in flow, quota request or settings mutation.
public enum AccountDoctor {
    public static func collect(service: AccountService = AccountService()) throws -> [AccountHealth] {
        let accounts = try service.registry.accounts()
        let identity = service.registry.identity
        let exporter = T3Exporter()
        let statuses = T3ProviderStatusReader(settingsURLs: exporter.settingsURLs)
        let quota = try? AtomicJSONFile(fileURL: identity.quotasFileURL).read(QuotaFeed.self)
        let connections = try? IntegrationService().connections()
        let inventory = connections.map { ConnectionInventoryReader().scan(accounts: accounts, connections: $0) } ?? []
        let pathReady = PathHelper().isConfigured()
        let now = Date()
        return accounts.map { account in
            let placement = exporter.placement(of: account)
            let instanceID = placement == .nativeDefault ? account.provider.t3Driver : account.t3InstanceID
            let group = inventory.first { $0.accountID == account.id }
            let warnings = group.map { $0.warnings.count + $0.entries.reduce(0) { $0 + $1.warnings.count } }
            return AccountHealth.evaluate(account: account, report: ConnectionProbe().snapshot(account),
                quota: quota?.accounts.first { $0.id == account.id.uuidString }, quotaDate: quota?.capturedAt,
                placement: placement, t3: statuses.status(instanceID: instanceID), hasT3Settings: !exporter.settingsURLs.isEmpty,
                wrapperReady: AccountHealth.wrapperReady(account, identity: identity), pathReady: pathReady,
                syncDrift: try? exporter.preview(accounts: [account]).hasChanges,
                inventoryWarnings: warnings, inventoryDate: now, now: now)
        }
    }
}
