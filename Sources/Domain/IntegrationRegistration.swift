import Foundation

public enum OAuthRegistrationScope: String, CaseIterable, Identifiable, Sendable {
    case personal
    case work
    public var id: String { rawValue }
    public var label: String { self == .personal ? "Personal" : "Work" }
    public var appName: String { "Harnais \(label)" }
}

public extension IntegrationKind {
    var registrationTitle: String {
        switch self {
        case .googleDrive, .gmail: "Google Cloud OAuth app"
        case .outlook: "Microsoft Entra OAuth app"
        case .slack: "Slack workspace app"
        case .atlassian: "Atlassian MCP client"
        case .grafana: "Grafana service account"
        case .whatsapp: "WhatsApp linked device"
        case .aikido: "Aikido sign-in"
        case .excalidraw: "Excalidraw server"
        case .custom: "MCP OAuth client"
        }
    }

    var registrationSteps: [String] {
        switch self {
        case .aikido, .excalidraw, .whatsapp: [oauthSetupHint]
        case .gmail:
            ["Reuse the Harnais Google desktop client; Gmail and Drive do not need separate OAuth apps.",
             "Enable Gmail API in the same Google project. Harnais uses a local read-only adapter, so Gmail MCP preview access is not required.",
             "Add gmail.readonly to the consent screen and complete restricted-scope verification for public release."]
        case .outlook:
            ["Register a public desktop app in Microsoft Entra supporting organizational and personal Microsoft accounts.",
             "Register the exact Harnais loopback callback in publicClient.redirectUris. Use the manifest editor for an HTTP 127.0.0.1 callback.",
             "Request delegated Mail.Read, openid, profile, email, and offline_access. Do not create a client secret or application-wide mail permissions.",
             "Complete publisher verification and any tenant-required administrator consent."]
        case .googleDrive:
            ["Use the Harnais Google desktop client, or create a project you own. Gmail and Drive can use the same OAuth app.",
             "Enable Google Drive, Sheets, Docs and Slides APIs. Harnais uses the stable APIs, with no MCP preview requirement.",
             "In Google Auth Platform, name the app Harnais. Set its audience and support contact. For External testing, add the Google accounts that will sign in.",
             "In Data Access, add the scopes listed below. Create a Desktop application client named Harnais for the local loopback callback.",
             "Save its client ID and secret here. Each Google user then authorizes a Shared connection once."]
        case .slack:
            ["Open Slack apps and create an app From a manifest in the intended workspace. Name it Harnais.",
             "Paste the manifest below. It requests search and read access, including private conversations the signed-in user can access. It grants no message-sending or other write scopes.",
             "Keep this an internal workspace app. Slack MCP permits internal or Marketplace-published apps, not unlisted distributed apps.",
             "Verify the redirect URI in OAuth & Permissions. Copy the client ID and secret from Basic Information into Harnais.",
             "Save the registration here, then sign in to a Shared connection. Workspace admin approval may be required."]
        case .atlassian:
            ["Harnais discovers Atlassian's MCP registration endpoint and registers a native client named Harnais with its local callback.",
             "Registering the client does not authorize Jira or Confluence access. Sign in afterwards and select the sites to authorize.",
             "Your Atlassian administrator may need to allow Harnais's callback under the organization's Rovo MCP policy."]
        case .grafana:
            ["In the intended Grafana organization, create a service account named Harnais and grant only the permissions its tools need.",
             "Create a token and enter it in Add connection > Grafana. This integration does not need an OAuth app.",
             "Install mcp-grafana locally. The same service account is used by each provider that receives the shared connection."]
        case .custom:
            ["Use the service's own app console if it requires a registered client. Register the Harnais redirect URI below.",
             "If the server advertises dynamic registration, Harnais can register a native client during sign-in. Otherwise enter its client ID and any required secret in the connection form."]
        }
    }

    var registrationConsoleURL: URL? {
        switch self {
        case .slack: URL(string: "https://api.slack.com/apps")
        case .googleDrive, .gmail: URL(string: "https://console.cloud.google.com/auth/clients")
        case .outlook: URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")
        default: nil
        }
    }

    var registrationDocumentationURL: URL {
        switch self {
        case .whatsapp: URL(string: "https://github.com/tulir/whatsmeow")!
        case .aikido: URL(string: "https://github.com/AikidoSec/aikido-cursor-plugin")!
        case .excalidraw: URL(string: "https://github.com/excalidraw/excalidraw-mcp")!
        case .slack: URL(string: "https://docs.slack.dev/ai/slack-mcp-server/")!
        case .gmail: URL(string: "https://developers.google.com/workspace/gmail/api/auth/scopes")!
        case .outlook: URL(string: "https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app")!
        case .googleDrive: URL(string: "https://developers.google.com/workspace/drive/api/guides/api-specific-auth")!
        case .atlassian: URL(string: "https://github.com/atlassian/atlassian-mcp-server")!
        case .grafana: URL(string: "https://grafana.com/docs/grafana/latest/administration/service-accounts/")!
        case .custom: URL(string: "https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization")!
        }
    }

    var slackAppManifest: String? { slackAppManifest(scope: .personal) }

    func slackAppManifest(scope: OAuthRegistrationScope) -> String? {
        guard self == .slack else { return nil }
        let manifest: [String: Any] = [
            "display_information": ["name": scope.appName, "description": "Shared Slack access for your local coding accounts"],
            "oauth_config": ["redirect_urls": [IntegrationOAuth.redirectURI], "scopes": ["user": defaultScopes]],
            "settings": ["org_deploy_enabled": false, "socket_mode_enabled": false]
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }
}
