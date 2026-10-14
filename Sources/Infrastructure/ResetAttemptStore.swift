import Domain
import Foundation

/// Remembers the idempotency key of a redemption whose outcome is not known yet.
///
/// A banked reset is spent by one request. If the app quits or the network drops
/// before the answer arrives, retrying with a new key could spend a second credit.
/// Reusing the stored key makes the provider answer "already redeemed" instead.
public struct ResetAttemptStore: Sendable {
    private struct Attempt: Codable {
        var key: String
        var createdAt: Date
    }

    static let lifetime: TimeInterval = 24 * 3600

    public var file: AtomicJSONFile

    public init(identity: AppIdentity = .current) {
        file = AtomicJSONFile(fileURL: identity.dataDirectory.appendingPathComponent("reset-attempts.json"))
    }

    public static func scope(provider: ProviderKind, accountID: UUID, creditID: String?) -> String {
        "\(provider.rawValue):\(accountID.uuidString):\(creditID ?? "next")"
    }

    /// The key for this logical attempt. Throws if it cannot be stored, so nothing is sent without one.
    public func key(for scope: String, now: Date = Date()) throws -> String {
        try file.withLock {
            var attempts = (try? file.readUnlocked([String: Attempt].self)) ?? [:]
            attempts = attempts.filter { now.timeIntervalSince($0.value.createdAt) < Self.lifetime }
            if let existing = attempts[scope] {
                try file.writeUnlocked(attempts)
                return existing.key
            }
            let key = UUID().uuidString.lowercased()
            attempts[scope] = Attempt(key: key, createdAt: now)
            try file.writeUnlocked(attempts)
            return key
        }
    }

    public func pendingKey(for scope: String, now: Date = Date()) -> String? {
        guard let attempts = try? file.read([String: Attempt].self),
              let attempt = attempts[scope], now.timeIntervalSince(attempt.createdAt) < Self.lifetime
        else { return nil }
        return attempt.key
    }

    public func finish(_ scope: String) {
        try? file.withLock {
            guard var attempts = try? file.readUnlocked([String: Attempt].self), attempts[scope] != nil else { return }
            attempts[scope] = nil
            try file.writeUnlocked(attempts)
        }
    }
}
