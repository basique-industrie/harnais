import Foundation

public enum HarnaisError: Error, LocalizedError, Equatable, Sendable {
    case binaryNotFound(String)
    case invalidLabel
    case duplicateSlug(String)
    case missingAccount
    case t3SettingsMissing
    case t3SettingsInvalid
    case processFailed(String)
    case notLoggedIn
    case updateFailed(String)
    case oauthClientRequired(String)
    case oauthFailed(String)
    case mcpServeUnknown(String)
    case grafanaBinaryMissing
    case callbackPortBusy
    case duplicateIntegration(String)
    case mcpApplyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            "Could not find \(name) on your PATH. Install the CLI, then try again."
        case .invalidLabel:
            "Give the account a short name such as Work or Personal."
        case .duplicateSlug(let slug):
            "An account named \(slug) already exists for this provider."
        case .missingAccount:
            "That account is no longer in the registry."
        case .t3SettingsMissing:
            "T3 Code settings were not found. Open T3 Code once, then try again."
        case .t3SettingsInvalid:
            "T3 Code settings have an unsupported format. Sync was cancelled."
        case .processFailed(let message):
            message
        case .notLoggedIn:
            "Sign-in did not finish. Complete the login in the terminal, then continue."
        case .updateFailed(let message):
            message
        case .oauthClientRequired(let name):
            "\(name) needs an OAuth client in Harnais. Add the Client ID once, then sign in."
        case .oauthFailed(let message):
            message
        case .mcpServeUnknown(let name):
            "No Harnais connection named \(name). Open Connections and sign in."
        case .grafanaBinaryMissing:
            "Could not find mcp-grafana on PATH. Install it, then try again."
        case .callbackPortBusy:
            "Harnais could not listen on port 8788. Close the other sign-in window and try again."
        case .duplicateIntegration(let name):
            "A connection named \(name) already exists."
        case .mcpApplyFailed(let message):
            message
        }
    }
}
