import Darwin
import Domain
import Foundation

/// A T3 server that is running now, from `<state dir>/server-runtime.json`. T3 writes that file
/// atomically at startup and deletes it on shutdown; a crash can leave it behind, so the PID is checked.
public struct T3ServerRuntime: Sendable, Equatable {
    public var pid: Int32
    public var origin: URL
    /// `~/.t3/userdata`: holds settings.json, secrets and the session database.
    public var stateDirectory: URL

    public init(pid: Int32, origin: URL, stateDirectory: URL) {
        self.pid = pid
        self.origin = origin
        self.stateDirectory = stateDirectory
    }

    public static func parse(_ data: Data, stateDirectory: URL) -> T3ServerRuntime? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1,
              let pid = object["pid"] as? Int, pid > 0, pid <= Int(Int32.max),
              let raw = object["origin"] as? String,
              let origin = URL(string: raw), origin.scheme == "http", origin.host != nil
        else { return nil }
        return T3ServerRuntime(pid: Int32(pid), origin: origin, stateDirectory: stateDirectory)
    }

    /// The server for the T3 settings file at `settingsURL`, if one is running under this user.
    public static func running(settingsURL: URL) -> T3ServerRuntime? {
        let directory = settingsURL.deletingLastPathComponent()
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("server-runtime.json")),
              let runtime = parse(data, stateDirectory: directory),
              kill(runtime.pid, 0) == 0
        else { return nil }
        return runtime
    }

    /// Effect RPC over WebSocket; without the protocol version the server answers 426.
    public var webSocketURL: URL? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "ws"
        components.path = "/ws"
        components.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: "2")]
        return components.url
    }

    /// The executable running the server: the T3 app binary in Node mode.
    public var executableURL: URL? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path)
    }

    /// Version reported by the unauthenticated discovery endpoint.
    public func serverVersion() async -> String? {
        guard let url = URL(string: "/.well-known/t3/environment", relativeTo: origin) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["serverVersion"] as? String
    }
}

public enum T3ServerError: Error, LocalizedError, Equatable {
    /// Nothing was changed; the caller can fall back to editing the settings file.
    case unavailable(String)
    case rejected(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .rejected(let message): message
        case .timedOut: "T3 Code did not answer in time."
        }
    }
}

/// A short-lived T3 session issued by the T3 CLI. The token stays in memory and is never logged.
public struct T3ServerSession: Sendable, CustomStringConvertible {
    public let id: String
    let token: String
    let webSocketURL: URL

    public var description: String { "T3ServerSession(\(id))" }

    public func connect() -> T3ServerConnection {
        T3ServerConnection(url: webSocketURL, token: token)
    }
}

/// The running T3 server plus the CLI of the build that runs it. The CLI shares that build's
/// database migrations, so Harnais never issues sessions with another installed build.
public struct T3Server: Sendable {
    public static let scopes = ["orchestration:read", "providers:manage"]

    public var runtime: T3ServerRuntime
    public var executableURL: URL

    public init(runtime: T3ServerRuntime, executableURL: URL) {
        self.runtime = runtime
        self.executableURL = executableURL
    }

    public static func running(settingsURL: URL) -> T3Server? {
        guard let runtime = T3ServerRuntime.running(settingsURL: settingsURL),
              let executable = runtime.executableURL,
              executable.path.contains(".app/Contents/MacOS/")
        else { return nil }
        let server = T3Server(runtime: runtime, executableURL: executable)
        // A crash leaves the runtime file behind, and its PID can be reused by another app.
        // The CLI script is inside app.asar, which only Electron can read into.
        guard Bundle(url: server.appURL)?.bundleIdentifier == T3Installation.bundleIdentifier,
              FileManager.default.fileExists(atPath: server.appURL.appendingPathComponent("Contents/Resources/app.asar").path)
        else { return nil }
        return server
    }

    var appURL: URL {
        executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    var cliScript: String {
        appURL.appendingPathComponent("Contents/Resources/app.asar/apps/server/dist/bin.mjs").path
    }

    /// The CLI flag points at the T3 home; the server keeps its state in `<home>/userdata`.
    var baseDirectory: String {
        runtime.stateDirectory.deletingLastPathComponent().path
    }

    /// Issues a session, runs `body`, then revokes the session even when `body` fails.
    public func withSession<T: Sendable>(
        scopes: [String] = T3Server.scopes,
        ttl: String = "10m",
        _ body: @Sendable (T3ServerSession) async throws -> T
    ) async throws -> T {
        let session = try issueSession(scopes: scopes, ttl: ttl)
        do {
            let value = try await body(session)
            revoke(session)
            return value
        } catch {
            revoke(session)
            throw error
        }
    }

    func issueSession(scopes: [String], ttl: String) throws -> T3ServerSession {
        guard runtime.stateDirectory.lastPathComponent == "userdata", let url = runtime.webSocketURL else {
            throw T3ServerError.unavailable("This T3 Code server does not accept Harnais sessions.")
        }
        var arguments = [cliScript, "auth", "session", "issue", "--base-dir", baseDirectory,
                         "--ttl", ttl, "--label", "Harnais", "--json"]
        for scope in scopes { arguments += ["--scope", scope] }
        let result: ProcessResult
        do {
            result = try runCLI(arguments)
        } catch {
            throw T3ServerError.unavailable("Could not start the T3 Code command line.")
        }
        guard result.exitCode == 0,
              let session = Self.parseIssuedSession(result.output, webSocketURL: url)
        else { throw T3ServerError.unavailable("This T3 Code build cannot issue a session for Harnais.") }
        return session
    }

    func revoke(_ session: T3ServerSession) {
        _ = try? runCLI([cliScript, "auth", "session", "revoke", session.id, "--base-dir", baseDirectory])
    }

    static func parseIssuedSession(_ output: String, webSocketURL: URL) -> T3ServerSession? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any],
              let id = object["sessionId"] as? String, !id.isEmpty,
              let token = object["token"] as? String, !token.isEmpty
        else { return nil }
        return T3ServerSession(id: id, token: token, webSocketURL: webSocketURL)
    }

    private func runCLI(_ arguments: [String]) throws -> ProcessResult {
        var environment = ProcessInfo.processInfo.environment
        environment["ELECTRON_RUN_AS_NODE"] = "1"
        environment.removeValue(forKey: "T3CODE_HOME")
        return try ProcessRunner().run(
            executable: executableURL.path,
            arguments: arguments,
            environment: environment,
            timeout: 30,
            maximumOutputBytes: 1024 * 1024,
            mergeStandardError: false
        )
    }
}

/// T3's Effect RPC frames: one JSON message per WebSocket text frame.
public enum T3RPC {
    public enum Frame: Equatable {
        case success(requestID: String, value: Data)
        case failure(requestID: String, message: String)
        case chunk(requestID: String, values: [Data])
        case defect(String)
        case other
    }

    public static func request(id: String, tag: String, payload: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])
        return try encode(["_tag": "Request", "id": id, "tag": tag, "payload": object, "headers": [Any]()])
    }

    /// Streams wait for an Ack after each chunk before sending the next one.
    public static func ack(id: String) -> String {
        (try? encode(["_tag": "Ack", "requestId": id])) ?? ""
    }

    public static func interrupt(id: String) -> String {
        (try? encode(["_tag": "Interrupt", "requestId": id, "interruptors": [Any]()])) ?? ""
    }

    public static func frame(_ data: Data) -> Frame {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["_tag"] as? String
        else { return .other }
        switch tag {
        case "Exit":
            guard let id = object["requestId"] as? String,
                  let exit = object["exit"] as? [String: Any]
            else { return .other }
            if exit["_tag"] as? String == "Success" {
                let value = exit["value"] ?? NSNull()
                let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("null".utf8)
                return .success(requestID: id, value: data)
            }
            return .failure(requestID: id, message: failureMessage(exit["cause"]))
        case "Chunk":
            guard let id = object["requestId"] as? String,
                  let values = object["values"] as? [Any]
            else { return .other }
            return .chunk(requestID: id, values: values.compactMap {
                try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed])
            })
        case "Defect", "ClientProtocolError":
            return .defect("T3 Code could not read the request from Harnais.")
        default:
            return .other
        }
    }

    static func failureMessage(_ cause: Any?) -> String {
        let reasons = cause as? [[String: Any]] ?? []
        for reason in reasons {
            if let error = reason["error"] as? [String: Any] {
                for key in ["detail", "message"] {
                    if let text = error[key] as? String, !text.isEmpty { return text }
                }
                if let tag = error["_tag"] as? String, tag.contains("Authorization") {
                    return "T3 Code did not allow this change."
                }
            }
        }
        if reasons.contains(where: { $0["_tag"] as? String == "Interrupt" }) {
            return "T3 Code stopped the request."
        }
        return "T3 Code rejected the request."
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// One WebSocket to the running server. Requests run one at a time.
public actor T3ServerConnection {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private var nextID = 0

    init(url: URL, token: String) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 32 * 1024 * 1024
        socket.resume()
    }

    public func close() {
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    /// Sends one request and returns the JSON of its success value.
    public func request(_ tag: String, payload: Data = Data("{}".utf8), timeout: Duration = .seconds(20)) async throws -> Data {
        let id = try await send(tag, payload: payload)
        let deadline = ContinuousClock.now + timeout
        while true {
            switch try await receive(deadline: deadline) {
            case .success(let requestID, let value) where requestID == id:
                return value
            case .failure(let requestID, let message) where requestID == id:
                throw T3ServerError.rejected(message)
            case .defect(let message):
                throw T3ServerError.rejected(message)
            default:
                continue
            }
        }
    }

    /// Reads a stream until `isFinished` accepts a value, then interrupts it and returns that value.
    public func stream(
        _ tag: String,
        payload: Data,
        timeout: Duration,
        isFinished: @Sendable (Data) async -> Bool
    ) async throws -> Data? {
        let id = try await send(tag, payload: payload)
        let deadline = ContinuousClock.now + timeout
        while true {
            switch try await receive(deadline: deadline) {
            case .chunk(let requestID, let values) where requestID == id:
                for value in values where await isFinished(value) {
                    try? await socket.send(.string(T3RPC.interrupt(id: id)))
                    return value
                }
                try await socket.send(.string(T3RPC.ack(id: id)))
            case .success(let requestID, _) where requestID == id:
                return nil
            case .failure(let requestID, let message) where requestID == id:
                throw T3ServerError.rejected(message)
            case .defect(let message):
                throw T3ServerError.rejected(message)
            default:
                continue
            }
        }
    }

    private func send(_ tag: String, payload: Data) async throws -> String {
        nextID += 1
        let id = String(nextID)
        let text = try T3RPC.request(id: id, tag: tag, payload: payload)
        do {
            try await socket.send(.string(text))
        } catch {
            try Task.checkCancellation()
            throw T3ServerError.unavailable("Could not connect to T3 Code.")
        }
        return id
    }

    private func receive(deadline: ContinuousClock.Instant) async throws -> T3RPC.Frame {
        let socket = socket
        let watchdog = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
        }
        defer { watchdog.cancel() }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await withTaskCancellationHandler {
                try await socket.receive()
            } onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { throw T3ServerError.timedOut }
            throw T3ServerError.unavailable("Lost the connection to T3 Code.")
        }
        switch message {
        case .string(let text): return T3RPC.frame(Data(text.utf8))
        case .data(let data): return T3RPC.frame(data)
        @unknown default: return .other
        }
    }
}

public extension T3ServerConnection {
    func request(_ tag: String, _ payload: [String: String], timeout: Duration = .seconds(20)) async throws -> Data {
        try await request(tag, payload: JSONSerialization.data(withJSONObject: payload), timeout: timeout)
    }
}

/// One step of T3's own sign-in for a provider instance (`provider.auth.*`).
public struct T3AuthState: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case idle, starting, waiting, verifying, succeeded, failed, cancelled
    }

    public var phase: Phase
    public var flowID: String?
    public var authorizationURL: URL?
    public var message: String?

    public init(phase: Phase, flowID: String? = nil, authorizationURL: URL? = nil, message: String? = nil) {
        self.phase = phase
        self.flowID = flowID
        self.authorizationURL = authorizationURL
        self.message = message
    }

    public var isFinished: Bool {
        switch phase {
        case .idle, .succeeded, .failed, .cancelled: true
        case .starting, .waiting, .verifying: false
        }
    }

    public static func parse(_ data: Data) -> T3AuthState? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phase = (object["phase"] as? String).flatMap(Phase.init(rawValue:))
        else { return nil }
        // Only web sign-in pages are opened from Harnais.
        let url = (object["authorizationUrl"] as? String).flatMap(URL.init(string:))
        return T3AuthState(
            phase: phase,
            flowID: object["flowId"] as? String,
            authorizationURL: url?.scheme == "https" ? url : nil,
            message: object["message"] as? String
        )
    }
}

public extension T3Server {
    /// Runs T3's sign-in for one provider instance and returns T3's status afterwards. The session
    /// owns the flow, so it stays open until the flow ends; a cancelled task also cancels the flow
    /// in T3, which otherwise keeps that provider locked until the flow expires.
    func signIn(
        instanceID: String,
        onChange: @escaping @Sendable (T3AuthState) async -> Void
    ) async throws -> T3ProviderStatus? {
        try await withSession(ttl: "15m") { session in
            let connection = session.connect()
            let payload = ["instanceId": instanceID]
            var flowID: String?
            var flowEnded = false
            do {
                try Task.checkCancellation()
                // Once sent, T3 holds a flow for this session. Wait for its ID even when cancelled,
                // so the flow can be cancelled instead of locking the provider until it expires.
                let startData = try await Task {
                    try await connection.request("provider.auth.start", payload)
                }.value
                guard let started = T3AuthState.parse(startData) else {
                    throw T3ServerError.rejected("T3 Code returned an unknown sign-in state.")
                }
                flowID = started.flowID
                await onChange(started)
                var final = started
                if !started.isFinished,
                   let data = try await connection.stream(
                       "provider.auth.subscribe",
                       payload: JSONSerialization.data(withJSONObject: payload),
                       timeout: .seconds(330),
                       isFinished: { data in
                           guard let state = T3AuthState.parse(data) else { return false }
                           await onChange(state)
                           return state.isFinished
                       }
                   ),
                   let state = T3AuthState.parse(data) {
                    final = state
                }
                flowEnded = final.isFinished
                guard final.phase == .succeeded else {
                    throw T3ServerError.rejected(final.message ?? "Sign-in did not finish.")
                }
                let status = try await signedInStatus(instanceID: instanceID, connection: connection)
                await connection.close()
                return status
            } catch {
                await connection.close()
                if let flowID, !flowEnded {
                    // A cancelled task cancels new requests too, so clean up from a fresh task.
                    await Task {
                        let cleanup = session.connect()
                        _ = try? await cleanup.request("provider.auth.cancel",
                                                       ["instanceId": instanceID, "flowId": flowID],
                                                       timeout: .seconds(5))
                        await cleanup.close()
                    }.value
                }
                throw error
            }
        }
    }

    /// T3 refreshes the provider after sign-in; wait briefly for it to report the account.
    private func signedInStatus(instanceID: String, connection: T3ServerConnection) async throws -> T3ProviderStatus? {
        var latest: T3ProviderStatus?
        for attempt in 0..<6 {
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            let config = try await connection.request("server.getConfig")
            latest = T3ProviderStatus.parseConfig(config).first { $0.instanceID == instanceID }
            if latest?.auth == .authenticated { break }
        }
        return latest
    }
}
