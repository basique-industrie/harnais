import Foundation

/// Display metadata only. Credentials never leave the provider's auth store.
public struct ConnectedAccount: Sendable, Equatable, Identifiable {
    public var id: String
    public var providerName: String
    public var loginMethod: String
    public var email: String?
    public var plan: String?

    public init(id: String, providerName: String, loginMethod: String, email: String? = nil, plan: String? = nil) {
        self.id = id
        self.providerName = providerName
        self.loginMethod = loginMethod
        self.email = email
        self.plan = plan
    }

    public var accountURL: URL? {
        switch id {
        case "opencode", "opencode-go": URL(string: "https://opencode.ai/console/")
        default: nil
        }
    }
}
