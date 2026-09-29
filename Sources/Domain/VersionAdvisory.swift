import Foundation

public enum VersionAdvisoryStatus: String, Sendable, Equatable {
    case unknown
    case current
    case behindLatest
}

/// Copyable installer command, matching T3's `versionAdvisory.updateCommand`.
public struct BinaryUpdatePlan: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var command: String

    public init(executable: String, arguments: [String], command: String) {
        self.executable = executable
        self.arguments = arguments
        self.command = command
    }
}

/// T3-style version advisory: behind/current plus a runnable update command.
public struct VersionAdvisory: Sendable, Equatable {
    public var status: VersionAdvisoryStatus
    public var currentVersion: String?
    public var latestVersion: String?
    public var plan: BinaryUpdatePlan?
    public var message: String?

    public init(
        status: VersionAdvisoryStatus,
        currentVersion: String? = nil,
        latestVersion: String? = nil,
        plan: BinaryUpdatePlan? = nil,
        message: String? = nil
    ) {
        self.status = status
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.plan = plan
        self.message = message
    }

    public var canUpdate: Bool { plan != nil }

    public var showsUpdateAffordance: Bool {
        status == .behindLatest && plan != nil
    }

    public var detail: String? {
        guard status == .behindLatest else { return nil }
        if let latestVersion, !latestVersion.isEmpty {
            let label = latestVersion.first?.isNumber == true ? "v\(latestVersion)" : latestVersion
            return "Update available: install \(label)."
        }
        return "Update available: install the latest provider version."
    }
}
