import Domain
import Foundation

/// Bridges cancellation from the UI to the blocking loopback listener.
public final class OAuthCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (@Sendable () -> Void)?
    public init() {}
    public func cancel() {
        let callback = lock.withLock { cancelled = true; return handler }
        callback?()
    }
    public func check() throws {
        if lock.withLock({ cancelled }) { throw HarnaisError.oauthFailed("Sign-in cancelled.") }
    }
    public func install(_ callback: @escaping @Sendable () -> Void) {
        let alreadyCancelled = lock.withLock { handler = callback; return cancelled }
        if alreadyCancelled { callback() }
    }
    public func clear() { lock.withLock { handler = nil } }
}
