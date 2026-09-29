import Foundation

/// Which island rings Harnais publishes. `quotas.json` always stays complete
/// (Iles reads it through the installed extension); the hidden set filters
/// only the probe output (`probe.sh`) and the in-app Islands preview.
public struct IslandPublishConfig: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    /// Quota `type` keys hidden from islands (e.g. "time:Claude · work 5h").
    public var hiddenTypes: [String]

    public init(schemaVersion: Int = 1, hiddenTypes: [String] = []) {
        self.schemaVersion = schemaVersion
        self.hiddenTypes = hiddenTypes
    }

    public func isHidden(type: String) -> Bool {
        hiddenTypes.contains(type)
    }

    public func settingHidden(type: String, hidden: Bool) -> IslandPublishConfig {
        var next = self
        if hidden {
            if !next.hiddenTypes.contains(type) { next.hiddenTypes.append(type) }
        } else {
            next.hiddenTypes.removeAll { $0 == type }
        }
        return next
    }
}

/// Iles integration state. Iles reads `quotas.json` through the local
/// extension in `~/.iles/extensions/harnais`, which also triggers refreshes
/// when the feed goes stale (see `probe.sh`).
public enum IlesState: String, Sendable, Equatable {
    case extensionFallback
    case missing

    public var displayName: String {
        switch self {
        case .extensionFallback: "Extension installed"
        case .missing: "Not installed"
        }
    }
}

public enum IslandFeed {
    /// Probe interval seconds from the bundled `manifest.json`. Rings can lag
    /// a manual refresh by up to this long; stale = 2x interval.
    public static let probeInterval: TimeInterval = 120
    public static let staleAfter: TimeInterval = 240

    public static func isStale(capturedAt: Date?, now: Date = Date()) -> Bool {
        guard let capturedAt else { return true }
        return now.timeIntervalSince(capturedAt) > staleAfter
    }
}
