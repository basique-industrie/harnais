import Domain
import Foundation
#if DEBUG
@testable import Infrastructure
#else
import Infrastructure
#endif

enum OAuthRecoveryTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let base = root.appendingPathComponent("oauth-recovery")
        let identity = AppIdentity(dataDirectory: base.appendingPathComponent("data"))
        let service = IntegrationService(identity: identity, homeDirectory: base)
        let gmail = IntegrationConnection(kind: .gmail, label: "Personal", slug: "personal", mcpName: "gmail", lastLoginAt: Date())
        let store = service.credentials
        let partial = OAuthTokenSet(clientId: "same-client", accessToken: "partial", refreshToken: "refresh", scope: "openid https://www.googleapis.com/auth/userinfo.email")
        try store.save(.oauth(partial), for: gmail)
        let requested = try service.reconnectClient(for: gmail)
        expect(requested?.clientId == "same-client", "permission renewal keeps the original Google app identity")
        expect(requested?.scopes == IntegrationKind.gmail.defaultScopes, "partial consent does not shrink the next Gmail request")
        expect(!requested!.scopes!.contains { $0.contains("drive") || $0.contains("gmail.modify") }, "renewal requests read-only Gmail without Drive or mail writes")
        do { try OAuthPermissions.validate(partial, for: .gmail); expect(false, "partial consent must not finish sign-in") }
        catch HarnaisError.oauthPermissionsMissing(let name) { expect(name == "Gmail", "partial consent gives a service-specific recovery message") }
        expect(OAuthPermissions.issue(for: .gmail, tokens: partial) == .missingPermissions, "existing incomplete consent is visible before an API call")
        do { _ = try store.authorizedTokens(for: gmail) { _ in fatalError("partial consent cannot be repaired by refreshing") }; expect(false, "incomplete consent cannot read mail") }
        catch HarnaisError.oauthPermissionsMissing { expect(true, "adapter asks for interactive permission renewal") }

        var complete = partial
        complete.accessToken = "valid"
        complete.scope = IntegrationKind.gmail.defaultScopes.joined(separator: " ")
        try OAuthPermissions.validate(complete, for: .gmail)
        try store.save(.oauth(complete), for: gmail)
        expect(OAuthPermissions.issue(for: .gmail, tokens: try store.load(for: gmail).oauth!) == nil, "complete new consent clears the recorded permission failure")

        var expired = complete
        expired.expiresAt = Date(timeIntervalSince1970: 0)
        try store.save(.oauth(expired), for: gmail)
        var attempts = 0
        for _ in 0..<2 {
            do {
                _ = try store.authorizedTokens(for: gmail) { _ in attempts += 1; throw HarnaisError.oauthAccessExpired }
                expect(false, "rejected refresh should fail")
            } catch HarnaisError.oauthAccessExpired { expect(true, "expired authorization requests renewal") }
        }
        expect(attempts == 1, "invalid grant is not retried on every subsequent tool call")
        expect(try store.load(for: gmail).oauth?.authorizationIssue == .expired, "expired refresh authorization persists for the UI across processes")

        try store.save(.oauth(expired), for: gmail)
        do {
            _ = try store.authorizedTokens(for: gmail) { _ in throw HarnaisError.processFailed("Temporary network error") }
            expect(false, "network failure should fail the current request")
        } catch HarnaisError.processFailed { expect(true, "temporary transport failure is preserved") }
        expect(try store.load(for: gmail).oauth?.authorizationIssue == nil, "network failures do not require a new browser authorization")
        do {
            _ = try store.authorizedTokens(for: gmail) { _ in partial }
            expect(false, "refresh with reduced permissions should fail before API access")
        } catch HarnaisError.oauthPermissionsMissing { expect(true, "permission loss after refresh is detected immediately") }
        expect(try store.load(for: gmail).oauth?.authorizationIssue == .missingPermissions, "reduced refresh permissions remain visible across processes")

        try store.save(.oauth(complete), for: gmail)
        try store.recordAuthorizationIssue(.expired, for: gmail, rejectedAccessToken: "old-request")
        expect(try store.load(for: gmail).oauth?.authorizationIssue == nil, "stale API failures cannot invalidate a newer sign-in")
        try store.recordAuthorizationIssue(.missingPermissions, for: gmail, rejectedAccessToken: "valid")
        expect(try store.load(for: gmail).oauth?.authorizationIssue == .missingPermissions, "current scope denial is visible to the UI")

        let cursor = Account(provider: .cursor, label: "Test", slug: "test", homePath: base.appendingPathComponent("cursor").path)
        let inventory = ConnectionInventoryReader(homeDirectory: base, identity: identity).scan(accounts: [cursor], connections: [gmail])
        expect(inventory[0].entries.contains { $0.name == "gmail" && $0.warnings.contains { $0.contains("Renew access") } }, "connection inventory exposes permission recovery in Manage")
        expect(!String(describing: inventory).contains("same-client") && !String(describing: inventory).contains("refresh"), "recovery inventory contains no OAuth credentials")

        try service.clients.upsert(kind: .gmail, record: OAuthClientRecord(clientId: "same-client", isPublicClient: true, scopes: IntegrationKind.gmail.defaultScopes + ["custom-scope"]))
        expect(try service.reconnectClient(for: gmail)?.scopes?.contains("custom-scope") == true, "renewal retains deliberately configured custom scopes")
        let drive = IntegrationConnection(kind: .googleDrive, label: "Drive", slug: "drive", mcpName: "drive")
        try store.save(.oauth(partial), for: drive)
        expect(try service.reconnectClient(for: drive)?.scopes == IntegrationKind.googleDrive.defaultScopes, "Drive also restores the intended scope request after partial consent")
        expect(OAuthPermissions.missing(for: .outlook, scope: "https://graph.microsoft.com/Mail.Read openid").isEmpty, "Graph-qualified mail scopes satisfy Outlook read access")
        expect(OAuthPermissions.missing(for: .gmail, scope: nil).isEmpty, "legacy tokens with unspecified permissions are checked by the API")
        expect(OAuthPermissions.missing(for: .googleDrive, scope: "https://www.googleapis.com/auth/drive").isEmpty, "existing broader Drive consent is recognized without requesting it")

        #if DEBUG
        let oauth = MCPOAuthClient()
        for code in ["invalid_grant", "invalid_client", "unknown_error"] {
            let data = try JSONSerialization.data(withJSONObject: ["error": code, "error_description": "SECRET-response-body"])
            do {
                _ = try oauth.parseTokens(HTTPResponse(data: data, status: 400, headers: [:]), fallbackClientId: nil, fallbackSecret: nil)
                expect(false, "OAuth errors fail token parsing")
            } catch {
                expect(!error.localizedDescription.contains("SECRET-response-body"), "OAuth error responses never echo sensitive provider text")
                expect((error as? HarnaisError) == .oauthAccessExpired || code != "invalid_grant", "invalid grant is classified before the generic HTTP error")
                expect((error as? HarnaisError) != .oauthAccessExpired || code == "invalid_grant", "client configuration errors do not invalidate user authorization")
            }
        }
        let insufficient = Data(#"{"error":{"code":403,"details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#.utf8)
        expect(OAuthPermissions.isInsufficientScope(insufficient), "Google scope denial is recognized from structured details")
        expect(!OAuthPermissions.isInsufficientScope(Data(#"{"error":{"code":403,"errors":[{"reason":"accessNotConfigured"}]}}"#.utf8)), "disabled APIs are not misdiagnosed as missing consent")
        #endif
    }
}
