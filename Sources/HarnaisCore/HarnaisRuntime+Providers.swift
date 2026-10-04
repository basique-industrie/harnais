import AppKit
import Domain
import Foundation
import Infrastructure

extension HarnaisRuntime {
    public func checkConnections(force: Bool = true) {
        guard !isCheckingConnection else { return }
        // Navigation can reuse recent results. Explicit refresh always checks again.
        if !force, let lastFullConnectionCheck,
           Date().timeIntervalSince(lastFullConnectionCheck) < 60 { return }
        refreshTerminalsCLI()
        isCheckingConnection = true
        errorMessage = nil
        let accounts = self.accounts
        // Keep the last report visible while checking. A pending report has
        // installed=false and would briefly replace installed CLIs with install instructions.
        let unowned = ProviderKind.allCases.filter { provider in !accounts.contains { $0.provider == provider } }.map(probeAccount)
        let connectionProbe = probe
        Task {
            await withTaskGroup(of: (Account, ConnectionReport).self) { group in
                for account in accounts + unowned {
                    group.addTask {
                        let report = await Task.detached {
                            connectionProbe.probe(account)
                        }.value
                        return (account, report)
                    }
                }
                for await (account, report) in group {
                    if unowned.contains(where: { $0.id == account.id }) {
                        self.standaloneReports[account.provider] = report
                    } else if self.accounts.contains(where: { $0.id == account.id }) {
                        self.reports[account.id] = report
                    }
                }
            }
            self.lastCheckedAt = Date()
            self.lastFullConnectionCheck = self.lastCheckedAt
            self.isCheckingConnection = false
        }
    }

    public func checkConnection(_ account: Account) {
        guard !checkingAccounts.contains(account.id) else { return }
        checkingAccounts.insert(account.id)
        let connectionProbe = probe
        Task {
            let report = await Task.detached {
                connectionProbe.probe(account)
            }.value
            if self.accounts.contains(where: { $0.id == account.id }) {
                self.reports[account.id] = report
            }
            self.checkingAccounts.remove(account.id)
            self.lastCheckedAt = Date()
        }
    }

    public func updateBinary(_ account: Account) {
        updateBinary(account.provider)
    }

    public func updateBinary(_ provider: ProviderKind) {
        guard !isUpdating(provider), let plan = binary(for: provider).advisory?.plan else { return }
        let account = accounts.first(where: { $0.provider == provider }) ?? probeAccount(provider)
        updatingProviders.insert(provider)
        let peers = accounts.filter { $0.provider == provider }
        for peer in peers { updatingIDs.insert(peer.id) }
        errorMessage = nil
        let environment = IsolationEngine().spawnEnvironment(for: account)
        let wrappers = service.wrappers
        Task {
            do {
                try await Task.detached {
                    _ = try BinaryUpdater().run(plan, environment: environment)
                    // Wrappers exec a resolved path, which a versioned install (mise) moves.
                    try? wrappers.refreshAll(accounts: peers)
                }.value
                for peer in peers { updatingIDs.remove(peer.id) }
                for peer in peers { checkConnection(peer) }
                if peers.isEmpty {
                    let connectionProbe = probe
                    standaloneReports[provider] = await Task.detached { connectionProbe.probe(account) }.value
                }
                updatingProviders.remove(provider)
                refreshTerminalsCLI(provider)
            } catch {
                updatingProviders.remove(provider)
                for peer in peers { updatingIDs.remove(peer.id) }
                errorMessage = error.localizedDescription
            }
        }
    }

    public func revealBinary(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func probeAccount(_ provider: ProviderKind) -> Account {
        let plan = IsolationEngine().plan(provider: provider, slug: "default", importDefault: true)
        return Account(provider: provider, label: "Default", slug: "default", homePath: plan.homePath,
                       binaryPath: BinaryLocator.resolve(provider, override: nil), env: plan.env, importedDefault: true)
    }

    public func refreshTerminalsCLI(_ provider: ProviderKind? = nil) {
        for kind in provider.map({ [$0] }) ?? ProviderKind.allCases {
            guard !checkingTerminals.contains(kind), !changingTerminals.contains(kind) else { continue }
            checkingTerminals.insert(kind)
            let path = binary(for: kind).path
            Task {
                terminalStatuses[kind] = await Task.detached {
                    TerminalCLIManager().inspect(provider: kind, managedPath: path)
                }.value
                checkingTerminals.remove(kind)
            }
        }
    }

    public func useCLIInTerminal(_ provider: ProviderKind, reset: Bool = false) {
        guard !checkingTerminals.contains(provider), !changingTerminals.contains(provider) else { return }
        let path = binary(for: provider).path
        guard reset || path != nil else { return }
        changingTerminals.insert(provider)
        errorMessage = nil
        Task {
            do {
                terminalStatuses[provider] = try await Task.detached {
                    let manager = TerminalCLIManager()
                    if reset {
                        try manager.reset(provider: provider)
                        return manager.inspect(provider: provider, managedPath: path)
                    }
                    guard let path else { throw HarnaisError.binaryNotFound(provider.defaultBinaryName) }
                    return try manager.useHarnais(provider: provider, binaryPath: path)
                }.value
                BinaryLocator.resetCachedPath()
                terminalRestartRequired.insert(provider)
                presentSuccess(reset
                    ? "Your shell will choose \(provider.defaultBinaryName) again. Open a new terminal window to apply the change."
                    : "\(provider.displayName) updates now apply to your command line too. Open a new terminal window to use them.")
            } catch {
                errorMessage = error.localizedDescription
            }
            changingTerminals.remove(provider)
        }
    }
}
