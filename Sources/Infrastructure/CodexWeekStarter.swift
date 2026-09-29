import Domain
import Foundation

public struct CodexWeekStarter: Sendable {
    public var file: AtomicJSONFile

    public init(identity: AppIdentity = .current) {
        file = AtomicJSONFile(fileURL: identity.dataDirectory.appendingPathComponent("codex-weeks.json"))
    }

    public func states() -> [String: CodexWindowState] {
        (try? file.read([String: CodexWindowState].self)) ?? [:]
    }

    public static func key(for account: Account) -> String {
        URL(fileURLWithPath: account.shadowHomePath ?? account.env["CODEX_HOME"] ?? account.homePath)
            .standardizedFileURL.path
    }

    @discardableResult
    public func observe(account: Account, result: ProbeResult, now: Date = Date()) throws -> CodexWindowState? {
        guard account.provider == .codex, result.error == nil,
              let weekly = result.quotas.first(where: { $0.window == "7d" }) else { return nil }
        return try update(account: account) { state in
            state.observe(remaining: weekly.percentRemaining, reset: weekly.resetsAt, now: now)
            if !state.awaitingFirstUse, state.lastAttemptAt != nil, !state.attempted {
                state.message = "Weekly window active."
            }
        }
    }

    /// Reserving before launching prevents duplicate requests across refreshes and processes.
    @discardableResult
    public func start(account: Account, manual: Bool = false, now: Date = Date(),
                      sendRequest: @Sendable (Account) throws -> Void = Self.sendRequest) throws -> Bool {
        guard account.provider == .codex else { return false }
        var reserved = false
        _ = try update(account: account) { state in
            reserved = state.reserveAttempt(manual: manual, now: now)
        }
        guard reserved else { return false }
        do {
            try sendRequest(account)
            _ = try update(account: account) {
                $0.message = "Request sent. Checking the weekly window…"
                $0.awaitingFirstUse = false
                $0.observedAt = nil
            }
            return true
        } catch {
            _ = try? update(account: account) { $0.message = "Could not start the week. You can retry with Start week." }
            throw error
        }
    }

    private func update(account: Account, change: (inout CodexWindowState) -> Void) throws -> CodexWindowState {
        try file.withLock {
            var states: [String: CodexWindowState]
            if FileManager.default.fileExists(atPath: file.fileURL.path) {
                states = try file.readUnlocked([String: CodexWindowState].self)
            } else { states = [:] }
            let key = Self.key(for: account)
            var state = states[key] ?? CodexWindowState()
            change(&state)
            states[key] = state
            try file.writeUnlocked(states)
            return state
        }
    }

    public static func arguments(directory: URL) -> [String] {
        ["-a", "never", "exec", "--ignore-user-config", "--ignore-rules", "--ephemeral",
         "--skip-git-repo-check", "--sandbox", "read-only", "--cd", directory.path,
         "--model", "gpt-6-luna", "-c", "model_provider=\"openai\"",
         "-c", "forced_login_method=\"chatgpt\"", "-c", "model_reasoning_effort=\"low\"",
         "-c", "project_doc_max_bytes=0", "-c", "features.shell_tool=false", "-c", "web_search=\"disabled\"",
         "-c", "features.hooks=false", "-c", "features.apps=false",
         "Reply with exactly OK. Do not use tools, read files, or perform any other task."]
    }

    public static func sendRequest(account: Account) throws {
        guard account.provider == .codex, AccountMetadata().codexPlanType(for: account) != nil else {
            throw HarnaisError.processFailed("Start week requires a Codex account signed in with ChatGPT.")
        }
        guard let binary = BinaryLocator.resolve(.codex, override: account.binaryPath) else {
            throw HarnaisError.binaryNotFound("codex")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harnais-start-week-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = IsolationEngine().spawnEnvironment(for: account)
        environment["CODEX_HOME"] = key(for: account)
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        environment.removeValue(forKey: "OPENAI_BASE_URL")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments(directory: directory)
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(45)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            throw HarnaisError.processFailed("Starting the Codex week timed out. Refresh limits before retrying.")
        }
        guard process.terminationStatus == 0 else {
            throw HarnaisError.processFailed("Codex could not start the week. Check its login and CLI version, then retry.")
        }
    }
}
