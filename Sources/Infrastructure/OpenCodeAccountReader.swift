import Domain
import Foundation

public enum OpenCodeAccountReader {
    public static func accounts(for account: Account) -> [ConnectedAccount] {
        guard account.provider == .opencode,
              let data = try? Data(contentsOf: AccountMetadata.openCodeAuthURL(for: account)) else { return [] }
        return parse(data)
    }

    public static func parse(_ data: Data) -> [ConnectedAccount] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return root.keys.sorted().compactMap { id in
            guard let credential = root[id] as? [String: Any] else { return nil }
            let method: String
            switch credential["type"] as? String {
            case "api":
                guard nonempty(credential["key"]) != nil else { return nil }
                method = "API key"
            case "oauth":
                guard nonempty(credential["refresh"]) != nil || nonempty(credential["access"]) != nil else { return nil }
                method = "OAuth"
            default: return nil
            }
            // OAuth claims label the login; they do not validate it. Never decode API keys.
            let claims = method == "OAuth"
                ? ["id_token", "access", "access_token"].compactMap { key in
                    (credential[key] as? String).flatMap(JWTPayload.dictionary)
                } : []
            let email = JWTPayload.mailbox(nonempty(credential["email"])) ?? claims.compactMap { claim in
                JWTPayload.mailbox(claim["email"] as? String)
                    ?? JWTPayload.mailbox((claim["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String)
            }.first
            let rawPlan = nonempty(credential["plan_type"]) ?? claims.compactMap { claim in
                nonempty((claim["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"])
            }.first
            let plan = id == "openai" ? SubscriptionLabel.codex(planType: rawPlan) : nil
            return ConnectedAccount(id: id, providerName: providerName(id), loginMethod: method, email: email, plan: plan)
        }
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func providerName(_ id: String) -> String {
        switch id {
        case "opencode": "OpenCode Zen"
        case "opencode-go": "OpenCode Go"
        case "openai": "OpenAI"
        case "anthropic": "Anthropic"
        case "google": "Google"
        case "github-copilot", "github-copilot-enterprise": "GitHub Copilot"
        case "openrouter": "OpenRouter"
        case "azure": "Azure OpenAI"
        case "amazon-bedrock": "Amazon Bedrock"
        default: id
        }
    }
}
