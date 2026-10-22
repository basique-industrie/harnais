import CryptoKit
import Foundation

/// Coordinates the GUI and short-lived CLI processes (including Iles' helper calls).
/// Credentials never leave memory. Provider responses and retry deadlines are owner-only,
/// keyed by a credential digest, and guarded by the same file lock across processes.
public final class ClaudeUsageClient: @unchecked Sendable {
    public typealias Transport = @Sendable (URLRequest) throws -> (data: Data, status: Int, retryAfter: String?)
    public static let shared = ClaudeUsageClient(cacheDirectory: AppIdentity.current.dataDirectory.appendingPathComponent("claude-usage"))
    public static let rateLimitMessage = "Claude is temporarily limiting usage checks (429). Wait before retrying."
    public static let refreshMaxAge: TimeInterval = 300
    public static let resetMaxAge: TimeInterval = 60

    private struct Cached: Codable {
        var data: Data
        var fetchedAt: Date
    }

    private struct State: Codable {
        var responses: [String: Cached] = [:]
        var retryAt: Date?
        var consecutiveLimits = 0
    }

    private let lock = NSLock()
    private let transport: Transport
    private let cacheDirectory: URL?
    private var states: [String: State] = [:]

    /// A nil directory keeps tests entirely in memory.
    public init(cacheDirectory: URL? = nil, transport: @escaping Transport = ClaudeUsageClient.liveTransport) {
        self.cacheDirectory = cacheDirectory
        self.transport = transport
    }

    public func send(_ request: URLRequest, now: Date? = nil,
                     maximumAge: TimeInterval = ClaudeUsageClient.refreshMaxAge) throws -> (Data, Int) {
        try withState(request) { state in
            // Read the wall clock after acquiring the cross-process lock.
            let checkedAt = now ?? Date()
            let key = request.url?.absoluteString ?? ""
            if let until = state.retryAt, until > checkedAt { return (Data(), 429) }
            if let cached = state.responses[key], cached.fetchedAt <= checkedAt,
               checkedAt.timeIntervalSince(cached.fetchedAt) < maximumAge {
                return (cached.data, 200)
            }
            let response = try transport(request)
            // Retry-After starts when the response arrives, not before a slow request.
            let receivedAt = now ?? Date()
            if response.status == 200,
               (try? JSONSerialization.jsonObject(with: response.data)) is [String: Any] {
                state.responses[key] = Cached(data: response.data, fetchedAt: receivedAt)
                state.retryAt = nil
                state.consecutiveLimits = 0
            } else if response.status == 429 {
                state.responses.removeAll()
                state.consecutiveLimits = min(state.consecutiveLimits + 1, 4)
                let fallback = min(1_800, 300 * pow(2, Double(state.consecutiveLimits - 1)))
                state.retryAt = Self.retryDate(response.retryAfter, now: receivedAt, fallback: fallback)
            }
            return (response.data, response.status)
        }
    }

    /// Holds the same lock as usage reads during redemption, including on transport failure.
    /// Another process cannot repopulate the cache with a pre-reset response mid-redemption.
    public func withInvalidatedUsage<T>(_ request: URLRequest, operation: () throws -> T) throws -> T {
        let outcome: Result<T, Error> = try withState(request) { state in
            state.responses.removeAll()
            return Result(catching: operation)
        }
        return try outcome.get()
    }

    private func withState<T>(_ request: URLRequest, _ operation: (inout State) throws -> T) throws -> T {
        try lock.withLock {
            let account = Self.accountKey(request)
            guard let cacheDirectory else {
                var state = states[account] ?? State()
                defer { states[account] = state }
                return try operation(&state)
            }
            let file = AtomicJSONFile(fileURL: cacheDirectory.appendingPathComponent(account + ".json"))
            return try file.withLock(timeout: 30) {
                var state = FileManager.default.fileExists(atPath: file.fileURL.path)
                    ? try file.readUnlocked(State.self) : State()
                let result = try operation(&state)
                try file.writeUnlocked(state)
                return result
            }
        }
    }

    private static func accountKey(_ request: URLRequest) -> String {
        SHA256.hash(data: Data((request.value(forHTTPHeaderField: "Authorization") ?? "").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func retryDate(_ value: String?, now: Date, fallback: TimeInterval) -> Date {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
           let seconds = TimeInterval(value), seconds.isFinite, seconds > 0,
           seconds <= Date.distantFuture.timeIntervalSince(now) {
            return now.addingTimeInterval(seconds)
        }
        if let value {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = formatter.date(from: value), date > now { return date }
        }
        // Missing, zero and invalid Retry-After values must not cause a retry loop.
        return now.addingTimeInterval(fallback)
    }

    public static let liveTransport: Transport = { request in
        let response = try HTTPClient.send(request)
        return (response.data, response.status, response.headers["retry-after"])
    }
}
