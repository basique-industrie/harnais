import AppKit
import Domain
import Foundation
import Infrastructure

enum AccountAuthenticationTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        func expectEqual<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            expect(got == want, "\(message) (got \(got), want \(want))")
        }

        let pending = ConnectionReport.pending()
        expectEqual(pending.headline, "Checking provider status", "pending headline")
        let missing = ConnectionReport.resolved(installed: false, authenticated: false)
        expectEqual(missing.headline, "Not found", "missing CLI headline")
        expectEqual(missing.kind, .error, "missing CLI is an error")
        let signedIn = ConnectionReport.resolved(
            installed: true,
            version: "1.2.3",
            authenticated: true,
            email: "ada@example.com"
        )
        expectEqual(signedIn.headline, "Authenticated · ada@example.com", "auth headline uses email")
        let uuidHeadline = ConnectionReport.resolved(
            installed: true,
            authenticated: true,
            email: "fe5b4ecc-2703-4499-b536-5ac6ae0b1111"
        )
        expectEqual(uuidHeadline.headline, "Authenticated", "UUID account ids are not shown as emails")
        expectEqual(uuidHeadline.email, nil, "UUID account ids are stripped from the mailbox field")

        func unsignedJWT(_ claims: [String: Any]) -> String {
            let payload = try! JSONSerialization.data(withJSONObject: claims)
            var base64 = payload.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
            while base64.last == "=" { base64.removeLast() }
            return "eyJhbGciOiJub25lIn0.\(base64).sig"
        }
        let idToken = unsignedJWT([
            "email": "ada@example.com",
            "sub": "fe5b4ecc-2703-4499-b536-5ac6ae0b1111",
        ])
        expectEqual(JWTPayload.email(idToken), "ada@example.com", "Codex id_token email claim")
        expectEqual(
            JWTPayload.email(unsignedJWT(["sub": "fe5b4ecc-2703-4499-b536-5ac6ae0b1111"])),
            nil,
            "ChatGPT sub is not treated as an email"
        )

        let codexHome = root.appendingPathComponent("codex-mail")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let authJSON: [String: Any] = [
            "tokens": [
                "id_token": idToken,
                "account_id": "acct_123",
            ],
        ]
        try JSONSerialization.data(withJSONObject: authJSON).write(
            to: codexHome.appendingPathComponent("auth.json")
        )
        let codexMailAccount = Account(
            provider: .codex,
            label: "Default",
            slug: "default",
            homePath: codexHome.path,
            env: ["CODEX_HOME": codexHome.path],
            accountEmail: "fe5b4ecc-2703-4499-b536-5ac6ae0b1111"
        )
        expectEqual(
            AccountMetadata().email(for: codexMailAccount),
            "ada@example.com",
            "Codex mailbox is read from id_token, not the stored UUID"
        )
        let storedUUIDOnly = Account(
            provider: .codex,
            label: "Default",
            slug: "missing-token",
            homePath: root.appendingPathComponent("codex-empty").path,
            accountEmail: "fe5b4ecc-2703-4499-b536-5ac6ae0b1111"
        )
        expectEqual(
            AccountMetadata().email(for: storedUUIDOnly),
            nil,
            "Codex does not invent an email from a stored account id"
        )
        expectEqual(
            ConnectionProbe().snapshot(codexMailAccount).email,
            "ada@example.com",
            "Codex connection status surfaces the ChatGPT mailbox"
        )

        let loginHome = root.appendingPathComponent("codex-login")
        try FileManager.default.createDirectory(at: loginHome, withIntermediateDirectories: true)
        let loginAccount = Account(
            provider: .codex,
            label: "Personal",
            slug: "personal",
            homePath: loginHome.path,
            env: ["CODEX_HOME": loginHome.path]
        )
        let metadata = AccountMetadata()
        let beforeLogin = metadata.credentialSnapshot(for: loginAccount)
        expect(
            metadata.loginCompleted(loginAccount, since: beforeLogin) == false,
            "empty Codex home is not a completed login"
        )
        try Data("{\"tokens\":{}}".utf8).write(to: loginHome.appendingPathComponent("auth.json"))
        expect(
            metadata.loginCompleted(loginAccount, since: beforeLogin),
            "auth.json appearing completes Codex login"
        )
        let afterLogin = metadata.credentialSnapshot(for: loginAccount)
        expect(
            metadata.loginCompleted(loginAccount, since: afterLogin) == false,
            "unchanged credentials are not a new login"
        )
        expectEqual(signedIn.versionLabel, "v1.2.3", "semver gets a v prefix")
        expectEqual(ConnectionReport.lastCheckedLabel(from: nil), "Check connection", "no last check")

        expectEqual(ConnectionProbe.parseVersion("claude 2.1.0 (built)"), "2.1.0", "claude version")
        expectEqual(ConnectionProbe.parseVersion("CLI Version 2026.03.20-44cb435"), "2026.03.20-44cb435", "cursor version")
        let claudeAuth = ConnectionProbe.parseClaudeAuth("{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}\n")
        expect(claudeAuth?.authenticated == true, "claude JSON logged in")
        expect(claudeAuth?.label == nil, "claude.ai auth method is not the plan")
        let claudeMax = ConnectionProbe.parseClaudeAuth(
            "{\"loggedIn\":true,\"email\":\"ada@example.com\",\"subscriptionType\":\"max\"}\n"
        )
        expectEqual(claudeMax?.label, "Claude Max", "claude max plan")
        expectEqual(
            SubscriptionLabel.codex(planType: "pro"),
            "ChatGPT Pro 20x",
            "codex pro plan"
        )
        expectEqual(
            SubscriptionLabel.cursor(tier: "Ultra"),
            "Cursor Ultra",
            "cursor ultra plan"
        )
        expectEqual(SubscriptionLabel.sidebarPlan("ChatGPT Pro 20x"), "Pro 20x", "sidebar drops ChatGPT prefix")
        expectEqual(SubscriptionLabel.sidebarPlan("Claude Max"), "Max", "sidebar drops Claude prefix")
        expectEqual(SubscriptionLabel.sidebarPlan("Cursor Ultra"), "Ultra", "sidebar drops Cursor prefix")
        let signedInPlan = ConnectionReport.resolved(
            installed: true,
            authenticated: true,
            email: "ada@example.com",
            authLabel: "Claude Max"
        )
        expectEqual(signedInPlan.headline, "Authenticated · Claude Max", "plan beats email in headline")
        let claudeOut = ConnectionProbe.parseClaudeAuth("not logged in")
        expect(claudeOut?.authenticated == false, "claude text logged out")
        let cursorAbout = ConnectionProbe.parseCursorAbout("""
        About Cursor CLI

        CLI Version         2026.03.20-44cb435
        User Email          user@example.com
        """)
        expectEqual(cursorAbout.email, "user@example.com", "cursor about email")
        expect(cursorAbout.authenticated == true, "cursor about authenticated")
        expectEqual(cursorAbout.subscriptionTier, nil, "no subscription line in this fixture")
        let cursorAboutPlan = ConnectionProbe.parseCursorAbout("""
        About Cursor CLI
        CLI Version         2026.09.10-fd3934a
        Subscription Tier   Ultra
        User Email          user@example.com
        """)
        expectEqual(cursorAboutPlan.subscriptionTier, "Ultra", "cursor about subscription")
        expectEqual(
            SubscriptionLabel.cursor(tier: cursorAboutPlan.subscriptionTier),
            "Cursor Ultra",
            "cursor about becomes T3 plan label"
        )
        let cursorJSONAbout = ConnectionProbe.parseCursorAbout(
            "{\"cliVersion\":\"2026.09.10-fd3934a\",\"subscriptionTier\":\"Ultra\",\"userEmail\":\"user@example.com\"}"
        )
        expectEqual(cursorJSONAbout.subscriptionTier, "Ultra", "cursor about JSON subscription")
        let cursorEvent = CursorQuotaProbe.parseEvent(
            [
                "timestamp": "1775418973898",
                "model": "composer-2",
                "conversationId": "conv-1",
                "chargedCents": 124.73,
                "tokenUsage": [
                    "inputTokens": 3,
                    "outputTokens": 205,
                    "cacheWriteTokens": 10,
                    "cacheReadTokens": 50,
                    "totalCents": 121.41,
                ],
            ],
            account: Account(provider: .cursor, label: "Default", slug: "default", homePath: "/tmp")
        )
        expect(cursorEvent?.provider == .cursor, "cursor dashboard event provider")
        expect(cursorEvent?.cachedInput == 50, "cursor cache read")
        expect(cursorEvent?.reportedCost != nil, "cursor uses dashboard cents")
        expect(abs((cursorEvent?.reportedCost ?? 0) - 1.2473) < 0.0001, "cursor cents become USD")
        let pricedCursor = ModelRates.standard.price(cursorEvent!)
        expect(abs(pricedCursor.cost - 1.2473) < 0.0001, "cursor reported cost skips model table")
        let cursorOut = ConnectionProbe.parseCursorAbout("User Email          Not logged in")
        expect(cursorOut.authenticated == false, "cursor about logged out")
    }
}
