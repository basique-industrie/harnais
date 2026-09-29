import Foundation

/// Paths and environment Harnais applies for one account without exposing them in the UI.
public struct IsolationPlan: Sendable, Equatable {
    public var homePath: String
    public var shadowHomePath: String?
    public var env: [String: String]
    public var importedDefault: Bool
    public var codexMode: CodexIsolationMode?

    public init(
        homePath: String,
        shadowHomePath: String? = nil,
        env: [String: String],
        importedDefault: Bool = false,
        codexMode: CodexIsolationMode? = nil
    ) {
        self.homePath = homePath
        self.shadowHomePath = shadowHomePath
        self.env = env
        self.importedDefault = importedDefault
        self.codexMode = codexMode
    }
}
