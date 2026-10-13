import Foundation

public enum OAuthAuthorizationIssue: String, Codable, Sendable {
    case expired
    case missingPermissions

    public var title: String {
        switch self {
        case .expired: "Access expired"
        case .missingPermissions: "Permissions missing"
        }
    }

    public func message(for kind: IntegrationKind) -> String {
        switch self {
        case .expired:
            "The authorization has expired or been revoked. Open Harnais → Connections → \(kind.displayName) and choose Renew access."
        case .missingPermissions:
            "\(kind.displayName) access was not fully granted. Open Harnais → Connections → \(kind.displayName), choose Renew access, and allow the requested permissions."
        }
    }
}
