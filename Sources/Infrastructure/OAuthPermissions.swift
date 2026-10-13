import Domain
import Foundation

/// Granted permissions describe what a token can do, not what the next consent should request.
public enum OAuthPermissions {
    public static func missing(for kind: IntegrationKind, scope: String?) -> [String] {
        guard let scope else { return [] } // Legacy servers can omit the scope field.
        let granted = Set(scope.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init))
        switch kind {
        case .gmail:
            if !granted.isDisjoint(with: ["https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.modify", "https://mail.google.com/"]) { return [] }
            return ["https://www.googleapis.com/auth/gmail.readonly"]
        case .googleDrive:
            if granted.contains("https://www.googleapis.com/auth/drive") { return [] }
            return kind.defaultScopes.filter { $0.contains("/auth/drive.") && !granted.contains($0) }
        case .outlook:
            let normalized = Set(granted.map { $0.replacingOccurrences(of: "https://graph.microsoft.com/", with: "").lowercased() })
            return normalized.isDisjoint(with: ["mail.read", "mail.readwrite"]) ? ["Mail.Read"] : []
        default: return []
        }
    }

    public static func validate(_ tokens: OAuthTokenSet, for kind: IntegrationKind) throws {
        if !missing(for: kind, scope: tokens.scope).isEmpty { throw HarnaisError.oauthPermissionsMissing(kind.displayName) }
    }

    public static func issue(for kind: IntegrationKind, tokens: OAuthTokenSet) -> OAuthAuthorizationIssue? {
        if let issue = tokens.authorizationIssue { return issue }
        if tokens.accessToken.isEmpty || (tokens.isExpired && (tokens.refreshToken ?? "").isEmpty) { return .expired }
        return missing(for: kind, scope: tokens.scope).isEmpty ? nil : .missingPermissions
    }

    static func isInsufficientScope(_ data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return false }
        let reasons = (error["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String } ?? []
        let details = (error["details"] as? [[String: Any]])?.compactMap { $0["reason"] as? String } ?? []
        return reasons.contains("insufficientPermissions") || details.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT")
    }
}
