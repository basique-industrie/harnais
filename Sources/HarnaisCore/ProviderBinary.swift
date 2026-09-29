import Domain

public struct ProviderBinary: Equatable, Identifiable, Sendable {
    public var provider: ProviderKind
    public var installed: Bool
    public var path: String?
    public var versionLabel: String?
    public var latestLabel: String?
    public var advisory: VersionAdvisory?
    public var accountLabels: [String]

    public var id: ProviderKind { provider }
}
