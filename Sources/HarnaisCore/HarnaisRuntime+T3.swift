import AppKit
import Domain
import Foundation
import Infrastructure

/// The T3 server Harnais last saw running, for Settings.
public struct T3RunningServer: Equatable, Sendable {
    public var appURL: URL?
    public var version: String?
}

extension HarnaisRuntime {
    public func applyT3() {
        syncT3(accounts: accounts, announce: true)
    }

    /// Adds or updates one profile from its Settings tab. Adding switches back on an entry T3 kept
    /// turned off, e.g. from a removed profile with the same name.
    public func applyT3(_ account: Account) {
        let adding = t3Placement(for: account) == .notMerged
        syncT3(accounts: accounts,
               changes: T3InstanceChanges(enable: adding ? [account.t3InstanceID] : []),
               announce: true)
    }

    /// Applies in the background: the running T3 server makes the change when it can, otherwise
    /// Harnais edits the settings file. Syncs run one after another.
    func syncT3(accounts: [Account], changes: T3InstanceChanges = T3InstanceChanges(), announce: Bool) {
        let previous = t3SyncTask
        pendingT3Syncs += 1
        t3SyncTask = Task {
            await previous?.value
            defer { pendingT3Syncs -= 1 }
            let addedCursorIDs = accounts.filter {
                t3SignsInSeparately(for: $0) && t3Placement(for: $0) == .notMerged
            }.map(\.id)
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try await T3Exporter().sync(accounts: accounts, changes: changes)
                }.value
                if announce {
                    errorMessage = nil
                    presentSuccess(Self.t3UpdatedMessage)
                }
                refreshT3State()
                for id in addedCursorIDs where !pendingT3SignInPrompts.contains(id) {
                    if let account = self.accounts.first(where: { $0.id == id }),
                       t3Placement(for: account) == .merged,
                       t3Status(for: account)?.auth != .authenticated {
                        pendingT3SignInPrompts.append(id)
                    }
                }
            } catch {
                if announce { successMessage = nil }
                errorMessage = announce
                    ? error.localizedDescription
                    : "Could not update T3 Code: \(error.localizedDescription)"
            }
            refreshT3State()
        }
    }

    /// Keeps T3 in step after a profile changes: re-applies profiles T3 already lists, and adds a new
    /// extra profile when another profile of the same provider is already in T3.
    func syncT3IfListed(_ account: Account, isNew: Bool = false) {
        let listed = isNew
            ? accounts.contains { $0.provider == account.provider && $0.id != account.id && t3Placement(for: $0) == .merged }
            : t3Placement(for: account) == .merged
        guard listed, t3Placement(for: account) != .nativeDefault else { return }
        syncT3(accounts: [account],
               changes: T3InstanceChanges(enable: isNew ? [account.t3InstanceID] : []),
               announce: false)
    }

    public func t3Placement(for account: Account) -> T3AccountPlacement {
        t3Placements[account.id] ?? T3Exporter().placement(of: account)
    }

    /// True when T3 signs in to this account's provider itself instead of using the Harnais profile.
    public func t3SignsInSeparately(for account: Account) -> Bool {
        account.provider == .cursor && t3SignsInToCursorSeparately
    }

    /// The T3 provider this account maps to: T3's built-in slot for the default login, the
    /// Harnais entry for extra profiles, nothing before the profile is added.
    public func t3InstanceID(for account: Account) -> String? {
        switch t3Placement(for: account) {
        case .nativeDefault: account.provider.t3Driver
        case .merged: account.t3InstanceID
        case .notMerged: nil
        }
    }

    public func t3Status(for account: Account) -> T3ProviderStatus? {
        t3InstanceID(for: account).flatMap { t3Statuses[$0] }
    }

    public func t3SignIn(for account: Account) -> T3AuthState? {
        t3SignIns[account.id]
    }

    /// Offer one SDK sign-in at a time, including profiles added by automatic sync.
    public var t3SignInPrompt: Account? {
        guard t3SignIns.isEmpty else { return nil }
        return pendingT3SignInPrompts.lazy.compactMap { id in
            self.accounts.first { $0.id == id }
        }.first {
            t3SignsInSeparately(for: $0) && t3Placement(for: $0) == .merged
                && t3Status(for: $0)?.auth != .authenticated
        }
    }

    public func dismissT3SignInPrompt(_ account: Account) {
        pendingT3SignInPrompts.removeAll { $0 == account.id }
    }

    public func t3Snippet(for account: Account) -> String {
        (try? T3Exporter().snippetJSON(for: account)) ?? "{}"
    }

    /// Runs T3's own sign-in for this account's provider and opens the sign-in page in the browser.
    /// Opens T3 first when it is closed.
    public func signInToT3(_ account: Account) {
        guard t3SignInTasks[account.id] == nil, let instanceID = t3InstanceID(for: account) else { return }
        errorMessage = nil
        t3SignIns[account.id] = T3AuthState(phase: .starting, message: "Starting sign-in in T3 Code…")
        let settingsURLs = T3Exporter().settingsURLs
        let build = t3Builds.first(where: \.usesCursorSDK) ?? t3Builds.first
        let id = account.id
        t3SignInTasks[id] = Task {
            defer {
                t3SignIns[id] = nil
                t3SignInTasks[id] = nil
                t3OpenedSignInURLs[id] = nil
            }
            do {
                guard let server = await Self.runningT3Server(settingsURLs: settingsURLs, launching: build) else {
                    throw T3ServerError.unavailable("Open T3 Code, then try again.")
                }
                let status = try await server.signIn(instanceID: instanceID) { [weak self] state in
                    await self?.showT3SignIn(state, for: id)
                }
                if let status { t3Statuses[instanceID] = status }
                presentSuccess(status?.email.map { "Signed in to T3 as \($0)" } ?? "Signed in to T3 Code")
            } catch {
                // Cancelling closes the connection, which surfaces as a connection error.
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            refreshT3State()
        }
    }

    public func cancelT3SignIn(_ account: Account) {
        t3SignInTasks[account.id]?.cancel()
    }

    private func showT3SignIn(_ state: T3AuthState, for id: UUID) {
        guard t3SignInTasks[id] != nil else { return }
        t3SignIns[id] = state
        if let url = state.authorizationURL, t3OpenedSignInURLs[id] != url {
            t3OpenedSignInURLs[id] = url
            NSWorkspace.shared.open(url)
        }
    }

    /// The server for the first settings file that has one, launching T3 if none is running.
    nonisolated private static func runningT3Server(settingsURLs: [URL], launching build: T3Build?) async -> T3Server? {
        func find() -> T3Server? { settingsURLs.lazy.compactMap(T3Server.running(settingsURL:)).first }
        if let server = find() { return server }
        guard let build else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: build.appURL, configuration: configuration)
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return nil }
            if let server = find() { return server }
        }
        return nil
    }

    /// Placements, provider statuses and managed accounts, all read from T3's files.
    func refreshT3State() {
        let exporter = T3Exporter()
        t3Placements = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, exporter.placement(of: $0)) })
        let candidates = T3Exporter.candidateSettingsURLs()
        let reader = T3ProviderStatusReader(settingsURLs: candidates)
        t3ManagedAccounts = T3ManagedAccount.read(settingsURLs: exporter.settingsURLs, statuses: reader)
        var instanceIDs = Set(accounts.compactMap(t3InstanceID(for:)))
        instanceIDs.formUnion(t3ManagedAccounts.map(\.instanceID))
        var statuses: [String: T3ProviderStatus] = [:]
        for id in instanceIDs {
            // A status read from the server after sign-in can be newer than T3's cache file.
            statuses[id] = [reader.status(instanceID: id), t3Statuses[id]].compactMap { $0 }
                .max { ($0.checkedAt ?? .distantPast) < ($1.checkedAt ?? .distantPast) }
        }
        t3Statuses = statuses
        pendingT3SignInPrompts.removeAll { id in
            guard let account = accounts.first(where: { $0.id == id }) else { return true }
            return t3Placement(for: account) != .merged || t3Status(for: account)?.auth == .authenticated
        }
        watchT3(settingsURLs: candidates, cacheDirectories: reader.cacheDirectories, instanceIDs: instanceIDs)
    }

    /// Installed builds and the running server's version, for Settings and the Cursor rules.
    func refreshT3Installation() {
        t3Builds = T3Installation.installed().builds
        t3SignsInToCursorSeparately = T3Installation(builds: t3Builds).signsInToCursorSeparately
        refreshT3RunningServer()
    }

    func refreshT3RunningServer() {
        let settingsURLs = T3Exporter.candidateSettingsURLs()
        t3RunningServerGeneration += 1
        let generation = t3RunningServerGeneration
        Task {
            let server = await Task.detached(priority: .utility) { () -> T3RunningServer? in
                guard let runtime = settingsURLs.lazy.compactMap(T3ServerRuntime.running(settingsURL:)).first
                else { return nil }
                let executable = runtime.executableURL
                let app = executable.map {
                    $0.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                }
                return T3RunningServer(appURL: app, version: await runtime.serverVersion())
            }.value
            // A slow check that started earlier must not overwrite a newer answer.
            if generation == t3RunningServerGeneration, t3RunningServer != server { t3RunningServer = server }
        }
    }

    /// Follows T3's settings, server and status files so changes made in T3 show up here.
    private func watchT3(settingsURLs: [URL], cacheDirectories: [URL], instanceIDs: Set<String>) {
        var urls = settingsURLs
        for settings in settingsURLs {
            urls.append(settings.deletingLastPathComponent().appendingPathComponent("server-runtime.json"))
        }
        for directory in cacheDirectories {
            for id in instanceIDs.sorted() where !id.contains("/") && !id.hasPrefix(".") {
                urls.append(directory.appendingPathComponent("\(id).json"))
            }
        }
        let watched = urls.filter {
            FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path)
        }
        guard watched != t3WatchedURLs else { return }
        t3Watcher?.stop()
        t3WatchedURLs = watched
        t3Watcher = watched.isEmpty ? nil : T3SettingsWatcher(urls: watched) { [weak self] in
            self?.refreshT3State()
            self?.refreshT3RunningServer()
        }
    }
}
