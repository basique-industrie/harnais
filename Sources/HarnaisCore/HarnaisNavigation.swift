import Domain
import Foundation
import Observation

enum HarnaisPage: Equatable {
    case overview
    case health
    case syncHistory
    case account
    case connections
    case skills
    case settings
    case about
    case binaries
    case usage

    func windowTitle(account: Account?) -> String {
        switch self {
        case .health:
            return "Account health — Harnais"
        case .syncHistory:
            return "Sync history — Harnais"
        case .about:
            return "About Harnais"
        case .settings:
            return "Settings — Harnais"
        case .skills:
            return "Skills — Harnais"
        case .connections:
            return "Connections — Harnais"
        case .binaries:
            return "Binaries — Harnais"
        case .usage:
            return "Usage — Harnais"
        case .overview:
            return "Harnais"
        case .account:
            if let account {
                return "\(account.displayLabel()) · \(account.provider.displayName) — Harnais"
            }
            return "Harnais"
        }
    }
}

/// Window-owned context survives switching between the conditionally rendered pages.
@Observable
final class HarnaisNavigation {
    var page: HarnaisPage = .overview
    let connections = ConnectionsNavigation()
    let skills = SkillsNavigation()
    let usage = UsageNavigation()

    func showLimits() {
        usage.tab = .limits
        usage.windowFilter = .all
        page = .usage
    }

    func showConnections(for accountID: UUID) {
        connections.accountID = accountID
        connections.search = ""
        page = .connections
    }

    func showSkills(for accountID: UUID) {
        skills.accountID = accountID
        skills.search = ""
        skills.section = "Skills"
        page = .skills
    }

    func reconcileAccounts(_ ids: Set<UUID>) {
        if let id = connections.accountID, !ids.contains(id) { connections.accountID = nil }
        if let id = skills.accountID, !ids.contains(id) { skills.accountID = nil }
    }
}

@Observable
final class ConnectionsNavigation {
    var search = ""
    var accountID: UUID?
    var showBuiltIn = false
}

@Observable
final class SkillsNavigation {
    var search = ""
    var accountID: UUID?
    var section = "Skills"
}

@Observable
final class UsageNavigation {
    var tab: UsageTab = .limits
    var metric: UsageMetric = .cost
    var range: UsageRange = .days30
    var breakdown: BreakdownMode = .model
    var windowFilter: LimitWindowFilter = .weekly
}
