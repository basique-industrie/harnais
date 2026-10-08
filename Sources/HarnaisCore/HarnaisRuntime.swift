import AppKit
import Domain
import Foundation
import Infrastructure
import Observation

@MainActor
@Observable
public final class HarnaisRuntime {
    public internal(set) var accounts: [Account] = []
    public internal(set) var feed: QuotaFeed = QuotaFeed()
    public internal(set) var reports: [UUID: ConnectionReport] = [:]
    public var selectedAccountID: UUID?
    public var lastCheckedAt: Date?
    public var errorMessage: String?
    public var successMessage: String?
    public var pathConfigured: Bool
    public var isRefreshingQuotas = false
    public internal(set) var startingCodexWeeks: Set<UUID> = []
    public internal(set) var codexWeekStates: [String: CodexWindowState] = [:]
    public var isRefreshingUsage = false
    public var isCheckingConnection = false
    public internal(set) var checkingAccounts: Set<UUID> = []
    public internal(set) var terminalStatuses: [ProviderKind: TerminalCLIStatus] = [:]
    public internal(set) var checkingTerminals: Set<ProviderKind> = []
    public internal(set) var terminalRestartRequired: Set<ProviderKind> = []
    public internal(set) var changingTerminals: Set<ProviderKind> = []
    public internal(set) var standaloneReports: [ProviderKind: ConnectionReport] = [:]
    public internal(set) var updatingProviders: Set<ProviderKind> = []
    public var updatingIDs: Set<UUID> = []
    public var usage = UsagePresentation()
    public internal(set) var settings = HarnaisSettingsDocument()
    public internal(set) var installedTerminals: [InstalledTerminal] = []
    public internal(set) var t3Placements: [UUID: T3AccountPlacement] = [:]
    public internal(set) var t3SignsInToCursorSeparately = false
    /// What T3 last reported per provider instance, keyed by instance ID.
    public internal(set) var t3Statuses: [String: T3ProviderStatus] = [:]
    public internal(set) var t3ManagedAccounts: [T3ManagedAccount] = []
    public internal(set) var t3Builds: [T3Build] = []
    public internal(set) var t3RunningServer: T3RunningServer?
    public internal(set) var t3SignIns: [UUID: T3AuthState] = [:]
    var pendingT3SignInPrompts: [UUID] = []
    var pendingT3Syncs = 0
    @ObservationIgnored var t3SyncTask: Task<Void, Never>?
    @ObservationIgnored var t3SignInTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var t3OpenedSignInURLs: [UUID: URL] = [:]
    @ObservationIgnored var t3Watcher: T3SettingsWatcher?
    @ObservationIgnored var t3WatchedURLs: [URL] = []
    @ObservationIgnored var t3RunningServerGeneration = 0
    public internal(set) var connections: [IntegrationConnection] = []
    public internal(set) var grafanaBinaryInstalled = false
    public internal(set) var islandConfig = IslandPublishConfig()
    public internal(set) var ilesState: IlesState = .missing
    public internal(set) var lastMCPApplyFiles: [String] = []
    public internal(set) var lastMCPApplyAt: Date?
    public internal(set) var lastMCPNames: [String] = []
    public internal(set) var skillInventory = SkillInventorySnapshot()
    public internal(set) var sharedSkills: [SharedSkill] = []
    public internal(set) var connectionInventory: [AccountConnectionInventory] = []
    public internal(set) var isReadingInventory = false
    public internal(set) var inventoryCheckedAt: Date?
    @ObservationIgnored private var inventoryGeneration = 0

    public let service: AccountService
    public let integrations: IntegrationService
    public let aggregator: QuotaAggregator
    public let identity: AppIdentity
    public let probe: ConnectionProbe
    public let settingsStore: SettingsStore
    public let islandStore: IslandStore
    public let terminalLauncher: TerminalLauncher
    var successGeneration = 0
    var lastFullConnectionCheck: Date?

    public init(service: AccountService = AccountService()) {
        self.service = service
        self.integrations = IntegrationService()
        self.aggregator = QuotaAggregator()
        self.identity = .current
        self.probe = ConnectionProbe(isolation: IsolationEngine())
        self.settingsStore = SettingsStore(identity: .current)
        self.islandStore = IslandStore(identity: .current)
        self.terminalLauncher = .workspace
        self.pathConfigured = PathHelper().isConfigured()
        reload()
    }

    public static let t3UpdatedMessage = "Updated in T3 Code"

    public var didUpdateT3: Bool {
        successMessage == Self.t3UpdatedMessage
    }

    public var isSyncingT3: Bool {
        pendingT3Syncs > 0
    }

    public func ownedAccounts(provider: ProviderKind) -> [Account] {
        self.accounts.filter { $0.provider == provider }
    }

    public var selectedAccount: Account? {
        accounts.first { $0.id == selectedAccountID } ?? accounts.first
    }

    public var binaries: [ProviderBinary] {
        ProviderKind.allCases.map(binary(for:))
    }

    public var hasBinaryUpdates: Bool {
        binaries.contains { $0.advisory?.showsUpdateAffordance == true }
    }

    public func binary(for provider: ProviderKind) -> ProviderBinary {
        let owned = accounts.filter { $0.provider == provider }
        if let account = owned.first {
            let report = connection(for: account)
            let latest = report.advisory?.latestVersion.map { version -> String in
                if let first = version.first, first.isNumber { return "v\(version)" }
                return version
            }
            return ProviderBinary(
                provider: provider,
                installed: report.installed,
                path: report.binaryPath ?? account.binaryPath,
                versionLabel: report.versionLabel,
                latestLabel: latest,
                advisory: report.advisory,
                accountLabels: owned.map(\.label)
            )
        }
        let report = standaloneReports[provider]
        let path = report?.binaryPath ?? BinaryLocator.resolve(provider, override: nil)
        return ProviderBinary(
            provider: provider,
            installed: path != nil,
            path: path,
            versionLabel: report?.versionLabel,
            latestLabel: report?.advisory?.latestVersion,
            advisory: report?.advisory,
            accountLabels: []
        )
    }

    public func isUpdating(_ provider: ProviderKind) -> Bool {
        updatingProviders.contains(provider)
    }

    public func connection(for account: Account) -> ConnectionReport {
        reports[account.id] ?? ConnectionReport.pending()
    }

    public func reload() {
        do {
            accounts = try service.registry.accounts()
            connections = (try? integrations.connections()) ?? []
            grafanaBinaryInstalled = GrafanaMCPProcess.binaryPath() != nil
            feed = aggregator.load()
            pathConfigured = PathHelper().isConfigured()
            ilesState = IlesExtensionInstaller().isInstalled() ? .extensionFallback : .missing
            islandConfig = (try? islandStore.load()) ?? IslandPublishConfig()
            if let applyState = try? integrations.applyStore.load() {
                lastMCPApplyFiles = applyState.files ?? []
                lastMCPApplyAt = applyState.appliedAt
                lastMCPNames = applyState.mcpNames
            }
            settings = (try? settingsStore.load()) ?? HarnaisSettingsDocument()
            codexWeekStates = CodexWeekStarter().states()
            installedTerminals = terminalLauncher.installedApplications()
            refreshT3Installation()
            refreshT3State()
            errorMessage = nil
            if selectedAccountID == nil || !accounts.contains(where: { $0.id == selectedAccountID }) {
                selectedAccountID = accounts.first?.id
            }
            for account in accounts where reports[account.id] == nil {
                reports[account.id] = probe.snapshot(account)
            }
            refreshConnectionInventory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func select(_ account: Account) {
        selectedAccountID = account.id
    }

    public func refreshConnectionInventory() {
        inventoryGeneration += 1
        guard !isReadingInventory else { return }
        isReadingInventory = true
        Task {
            while true {
                let generation = inventoryGeneration
                let accounts = accounts
                let connections = connections
                let reader = ConnectionInventoryReader(identity: identity)
                let library = SkillLibrary(identity: identity)
                let inventory = await Task.detached(priority: .utility) {
                    autoreleasepool {
                        let connections = reader.scan(accounts: accounts, connections: connections)
                        let skills = SkillInventoryReader(library: library).scan(accounts: accounts, connections: connections)
                        return (connections, skills, (try? library.load()) ?? [])
                    }
                }.value
                guard generation == inventoryGeneration else { continue }
                connectionInventory = inventory.0
                skillInventory = inventory.1
                sharedSkills = inventory.2
                inventoryCheckedAt = Date()
                isReadingInventory = false
                return
            }
        }
    }

    public func importDefaults() {
        do {
            _ = try service.importDefaults()
            reload()
            checkConnections()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addAccount(
        provider: ProviderKind,
        label: String,
        importDefault: Bool,
        shareCodexHistory: Bool
    ) throws -> Account {
        let account = try service.create(
            provider: provider,
            label: label,
            importDefault: importDefault,
            codexMode: shareCodexHistory ? .t3Shadow : .isolated
        )
        reload()
        selectedAccountID = account.id
        checkConnection(account)
        syncT3IfListed(account, isNew: true)
        return account
    }

    public func finishLogin(_ account: Account) {
        do {
            let updated = try service.refreshMetadata(account)
            reload()
            checkConnection(account)
            syncT3IfListed(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func rename(_ account: Account, label: String) {
        do {
            let updated = try service.rename(account, label: label)
            errorMessage = nil
            reload()
            selectedAccountID = updated.id
            syncT3IfListed(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setColor(_ color: AccountColor?, managesT3: Bool, for account: Account) {
        do {
            guard var updated = try service.registry.accounts().first(where: { $0.id == account.id }) else {
                throw HarnaisError.missingAccount
            }
            updated.accentColor = color?.rawValue
            updated.managesT3Color = managesT3
            try service.registry.update(updated)
            reload()
            syncT3IfListed(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func remove(_ account: Account) {
        let wasInT3 = t3Placement(for: account) == .merged
        do {
            try service.remove(account)
            if wasInT3 {
                // T3 keeps the entry, turned off, so chats that used it still open.
                syncT3(accounts: [], changes: T3InstanceChanges(disable: [account.t3InstanceID]), announce: false)
            }
            reports[account.id] = nil
            if selectedAccountID == account.id {
                selectedAccountID = nil
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
