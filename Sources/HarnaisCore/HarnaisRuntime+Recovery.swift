import Domain
import Foundation
import Infrastructure

extension HarnaisRuntime {
    func previewT3(accounts: [Account], changes: T3InstanceChanges = T3InstanceChanges()) {
        do {
            t3Preview = try T3Exporter().preview(accounts: accounts, changes: changes)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    public func previewUndo(_ record: T3SyncRecord) {
        do {
            t3Preview = try T3Exporter().previewUndo(record.id)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    public func applyT3Preview(_ preview: T3SyncPreview) {
        guard !isSyncingT3 else { return }
        if case .sync(let accounts, let changes) = preview.action {
            syncT3(accounts: accounts, changes: changes, announce: true, preview: preview)
            return
        }
        let previous = t3SyncTask
        pendingT3Syncs += 1
        t3SyncTask = Task {
            await previous?.value
            defer { pendingT3Syncs -= 1 }
            do {
                _ = try await Task.detached(priority: .userInitiated) { try await T3Exporter().apply(preview) }.value
                t3Preview = nil
                errorMessage = nil
                presentSuccess("T3 sync undone")
            } catch { errorMessage = error.localizedDescription }
            refreshT3State()
            refreshSyncHistory()
        }
    }

    public func refreshSyncHistory() {
        do {
            syncHistory = try T3SyncJournal(identity: identity).records()
            syncHistoryError = nil
        } catch { syncHistoryError = "Could not read sync history. \(error.localizedDescription)" }
    }

    public func health(for account: Account, now: Date = Date()) -> AccountHealth {
        let placement = t3Placement(for: account)
        let exporter = T3Exporter()
        let drift = try? exporter.preview(accounts: [account]).hasChanges
        let inventory = connectionInventory.first { $0.accountID == account.id }
        let warnings = inventory.map { $0.warnings.count + $0.entries.reduce(0) { $0 + $1.warnings.count } }
        return AccountHealth.evaluate(account: account, report: reports[account.id],
            quota: feed.accounts.first { $0.id == account.id.uuidString }, quotaDate: lastQuotaCapturedAt,
            placement: placement, t3: t3Status(for: account), hasT3Settings: !exporter.settingsURLs.isEmpty,
            wrapperReady: AccountHealth.wrapperReady(account, identity: identity), pathReady: pathConfigured,
            syncDrift: drift, inventoryWarnings: warnings, inventoryDate: inventoryCheckedAt, now: now)
    }

    public func refreshHealth() {
        pathConfigured = PathHelper().isConfigured()
        checkConnections()
        refreshQuotas()
        refreshConnectionInventory()
        refreshT3State()
    }

    public func repairAccountCommand(_ account: Account) {
        do {
            guard let binary = BinaryLocator.resolve(account.provider, override: account.binaryPath) else {
                throw HarnaisError.binaryNotFound(account.provider.defaultBinaryName)
            }
            _ = try service.wrappers.write(for: account, binaryPath: binary)
            presentSuccess("Account command repaired")
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    public func copyHealthReport() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            HarnaisPasteboard.copy(String(decoding: try encoder.encode(accounts.map { health(for: $0) }), as: UTF8.self))
            presentSuccess("Diagnostic report copied without emails, paths or credentials")
        } catch { errorMessage = error.localizedDescription }
    }
}
