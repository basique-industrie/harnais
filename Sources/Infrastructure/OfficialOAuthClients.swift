import Domain
import Foundation

/// Product registrations only. Never falls back to imported or user-supplied clients.
/// Google's installed-app client_secret is public native-client material, not a
/// confidential web secret. Slack native PKCE clients must have no secret here.
public enum OfficialOAuthClients {
    public static func record(for kind: IntegrationKind, applicationBundle: Bundle = .main) throws -> OAuthClientRecord? {
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
        case .slack: "The Harnais Slack app is internal to its owner workspace. Other workspaces require Marketplace approval; use an approved custom app until then."
        default: nil
        }
    }
}
