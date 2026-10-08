import AppKit
import Domain
import Foundation
import Infrastructure

extension HarnaisRuntime {
    public func installPath() {
        do {
            try PathHelper().install()
            pathConfigured = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func installIlesExtension() {
        do {
            _ = try IlesExtensionInstaller().install()
            ilesState = .extensionFallback
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func revealDataDirectory() {
        let directory = identity.dataDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    public var lastQuotaCapturedAt: Date? {
        feed.accounts.isEmpty ? nil : feed.capturedAt
    }

    func presentSuccess(_ message: String) {
        successMessage = message
        successGeneration += 1
        let generation = successGeneration
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if successGeneration == generation {
                successMessage = nil
            }
        }
    }

    public func quotas(for account: Account) -> [FeedQuota] {
        feed.accounts.first { $0.id == account.id.uuidString }?.quotas ?? []
    }

    public func resetCredits(for account: Account) -> ResetCredits? {
        feed.accounts.first { $0.id == account.id.uuidString }?.resetCredits
    }

    public func quotaError(for account: Account) -> String? {
        feed.accounts.first { $0.id == account.id.uuidString }?.error
    }

    public func wrapperPath(for account: Account) -> String {
        identity.binDirectory.appendingPathComponent(account.wrapperName).path
    }

    public var resolvedTerminal: InstalledTerminal? {
        terminalLauncher.resolve(preference: settings.terminalAppID, installed: installedTerminals)
    }

    public func selectTerminal(_ kind: TerminalAppKind) {
        do {
            settings.terminalAppID = kind.rawValue
            try settingsStore.save(settings)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func refreshTerminals() {
        installedTerminals = terminalLauncher.installedApplications()
    }

    public func openInstallPage(_ provider: ProviderKind) {
        NSWorkspace.shared.open(provider.installURL)
    }

    public func openTerminal(for account: Account) {
        let wrapper = identity.binDirectory.appendingPathComponent(account.wrapperName)
        do {
            if !FileManager.default.isExecutableFile(atPath: wrapper.path) {
                guard let binary = BinaryLocator.resolve(account.provider, override: account.binaryPath) else {
                    errorMessage = HarnaisError.binaryNotFound(account.provider.defaultBinaryName).localizedDescription
                    return
                }
                _ = try service.wrappers.write(for: account, binaryPath: binary)
            }
            try terminalLauncher.open(command: wrapper.path, preference: settings.terminalAppID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
