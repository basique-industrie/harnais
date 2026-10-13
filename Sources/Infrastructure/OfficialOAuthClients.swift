import Domain
import Foundation

/// Product registrations only. Never falls back to imported or user-supplied clients.
/// Google's installed-app client_secret is public native-client material, not a
/// confidential web secret. Slack native PKCE clients must have no secret here.
public enum OfficialOAuthClients {
    /// CLEYROP's internal Harnais Work app (`A0C4SFFJURZ`, workspace `T01MCHX99C0`). Its native PKCE
    /// client ID is public and it has no secret. Slack only accepts it in the CLEYROP workspace.
    public static let slackHarnaisWork = OAuthClientRecord(
        clientId: "1726609315408.12162525640883",
        isPublicClient: true,
        scopes: ["search:read.public", "search:read.private", "search:read.im", "search:read.mpim",
                 "search:read.files", "search:read.users", "files:read", "channels:history", "groups:history",
                 "im:history", "mpim:history", "users:read", "users:read.email", "emoji:read",
                 "chat:write", "channels:write", "groups:write", "im:write", "mpim:write",
                 "reactions:read", "reactions:write", "canvases:read", "canvases:write",
                 "channels:read", "groups:read", "im:read", "mpim:read", "lists:read", "lists:write", "files:write"]
    )

    public static func record(for kind: IntegrationKind, applicationBundle: Bundle = .main) throws -> OAuthClientRecord? {
        if kind == .slack { return slackHarnaisWork }
        let executable = applicationBundle.executableURL?.deletingLastPathComponent()
        let roots = [applicationBundle.resourceURL, applicationBundle.bundleURL,
                     executable, executable?.appendingPathComponent("../Resources").standardizedFileURL].compactMap { $0 }
        for root in roots {
            let file = root.appendingPathComponent("Harnais_Infrastructure.bundle/official-oauth-clients.json")
            if FileManager.default.fileExists(atPath: file.path) {
                return try decode(Data(contentsOf: file))[kind == .gmail ? IntegrationKind.googleDrive.rawValue : kind.rawValue]
            }
        }
        return nil
    }

    public static func decode(_ data: Data) throws -> [String: OAuthClientRecord] {
        let records = try JSONDecoder().decode([String: OAuthClientRecord].self, from: data)
        for (key, record) in records {
            guard let kind = IntegrationKind(rawValue: key), kind.authKind == .oauth,
                  record.isPublicClient == true, !record.clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  kind == .googleDrive || (record.clientSecret ?? "").isEmpty else {
                throw HarnaisError.oauthFailed("Invalid Harnais public OAuth registration. Reinstall Harnais.")
            }
        }
        return records
    }

    public static func availabilityNote(for kind: IntegrationKind) -> String? {
        switch kind {
        case .outlook: "Supports personal and work Microsoft accounts. Your organization may require administrator approval."
        case .gmail: "Gmail uses the Harnais Google app with read-only mail access. While Google verification is pending, sign-in is limited to approved test users."
        case .googleDrive: "Google currently limits Harnais sign-in to approved test users. Drive uses the stable API; no Developer Preview is required."
        case .slack: "Uses CLEYROP's internal Harnais Work app, available only in the CLEYROP workspace. Other workspaces need their own internal app under Advanced."
        default: nil
        }
    }
}
