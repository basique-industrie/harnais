import Foundation

/// An account accent is independent of provider branding and connection status.
public enum AccountColor: String, CaseIterable, Sendable {
    case blue, violet, pink, red, orange, green, teal

    public var title: String { rawValue.capitalized }

    public var hex: String {
        switch self {
        case .blue: "#3b82f6"
        case .violet: "#8b5cf6"
        case .pink: "#ec4899"
        case .red: "#ef4444"
        case .orange: "#f97316"
        case .green: "#22c55e"
        case .teal: "#14b8a6"
        }
    }
}

public extension Account {
    var color: AccountColor? { accentColor.flatMap(AccountColor.init(rawValue:)) }
    var t3AccentColor: String? { managesT3Color == true ? color?.hex : nil }
}
