import Foundation

/// Plan copy matching T3 Settings → Providers (`Authenticated · …`).
public enum SubscriptionLabel {
    public static func claude(subscriptionType: String?, authMethod: String?) -> String? {
        if isClaudeAPIKey(authMethod) { return "Claude API Key" }
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        let short = claudeShort(subscriptionType)
        let compact = compact(short)
        if compact.hasPrefix("claude"), compact.hasSuffix("subscription") { return short }
        if compact.hasPrefix("claude") { return short }
        return "Claude \(short)"
    }

    public static func codex(planType: String?) -> String? {
        guard let planType, !planType.isEmpty else { return nil }
        switch planType.lowercased() {
        case "free": return "ChatGPT Free"
        case "go": return "ChatGPT Go"
        case "plus": return "ChatGPT Plus"
        case "pro": return "ChatGPT Pro 20x"
        case "prolite": return "ChatGPT Pro 5x"
        case "team": return "ChatGPT Team"
        case "self_serve_business_prolite", "self_serve_business_usage_based", "business":
            return "ChatGPT Business"
        case "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "enterprise":
            return "ChatGPT Enterprise"
        case "edu", "edu_plus", "edu_pro": return "ChatGPT Edu"
        case "unknown": return "ChatGPT"
        default: return nil
        }
    }

    public static func cursor(tier: String?) -> String? {
        guard let tier, !tier.isEmpty else { return nil }
        return "Cursor \(cursorShort(tier) ?? titleCase(tier))"
    }

    /// Sidebar trailing plan. Group header already names the vendor.
    public static func sidebarPlan(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Claude ", "ChatGPT ", "Cursor "] {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        return trimmed
    }

    public static func compact(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: #"[\s_-]+"#, with: "", options: .regularExpression)
    }

    private static func isClaudeAPIKey(_ authMethod: String?) -> Bool {
        switch compact(authMethod ?? "") {
        case "apikey", "anthropicapikey", "anthropicauthtoken": true
        default: false
        }
    }

    private static func claudeShort(_ subscriptionType: String) -> String {
        switch compact(subscriptionType) {
        case "claudemaxsubscription", "max", "maxplan": return "Max"
        case "claudemax5xsubscription", "max5": return "Max 5x"
        case "claudemax20xsubscription", "max20": return "Max 20x"
        case "claudeenterprisesubscription", "enterprise": return "Enterprise"
        case "claudeteamsubscription", "team": return "Team"
        case "claudeprosubscription", "pro": return "Pro"
        case "claudefreesubscription", "free": return "Free"
        default: return titleCase(subscriptionType)
        }
    }

    private static func cursorShort(_ tier: String) -> String? {
        switch compact(tier) {
        case "team": return "Team"
        case "pro": return "Pro"
        case "free": return "Free"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "ultra": return "Ultra"
        default: return titleCase(tier)
        }
    }

    private static func titleCase(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            .filter { !$0.isEmpty }
            .map { part in
                let word = String(part)
                guard let first = word.first else { return word }
                return String(first).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }
}
