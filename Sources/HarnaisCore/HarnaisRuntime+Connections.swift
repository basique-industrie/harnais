import AppKit
import Domain
import Foundation
import Infrastructure

extension HarnaisRuntime {
    public func applyMCP() {
        do {
            let report = try integrations.apply(accounts: accounts)
            errorMessage = nil
            reload()
            lastMCPApplyFiles = report.files
            lastMCPApplyAt = Date()
            lastMCPNames = report.mcpNames
            presentSuccess(report.summary)
        } catch {
            successMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    public func disconnectConnection(_ connection: IntegrationConnection) {
        do {
            try integrations.disconnect(connection, accounts: accounts)
            errorMessage = nil
            reload()
            presentSuccess("Disconnected \(connection.kind.displayName).")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func finishConnection(_ connection: IntegrationConnection) {
        reload()
        presentSuccess("Connected \(connection.kind.displayName).")
    }

    public func hasProductClient(_ kind: IntegrationKind) -> Bool {
        (try? integrations.hasProductClient(kind)) ?? false
    }

    // MARK: - Islands (Iles ring publish toggles)

    public var feedIsStale: Bool {
        IslandFeed.isStale(capturedAt: lastQuotaCapturedAt)
    }

    /// Quota `type` keys hidden from islands via `islands.json`.
    public func isIslandHidden(type: String) -> Bool {
        islandConfig.isHidden(type: type)
    }

    public func setIslandHidden(type: String, hidden: Bool) {
        do {
            islandConfig = islandConfig.settingHidden(type: type, hidden: hidden)
            try islandStore.save(islandConfig)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
