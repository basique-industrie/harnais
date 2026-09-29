import AppKit
import Domain
import SwiftUI

/// T3 Code default theme (zinc light / neutral-950 dark), not T3 Chat mauve.
enum HarnaisPalette {
    static let sidebar = adaptive(light: rgb(250, 250, 250), dark: rgb(17, 17, 17))
    static let sidebarBorder = adaptive(light: rgb(228, 228, 231), dark: rgb(255, 255, 255, alpha: 0.06))
    static let background = adaptive(light: rgb(252, 252, 252), dark: rgb(10, 10, 10))
    static let surface = adaptive(light: rgb(255, 255, 255), dark: rgb(17, 17, 17))
    static let surfaceRaised = adaptive(light: rgb(255, 255, 255), dark: rgb(17, 17, 17))
    static let cardFill = adaptive(light: rgb(255, 255, 255, alpha: 0.40), dark: rgb(17, 17, 17, alpha: 0.40))
    static let muted = adaptive(light: rgb(250, 250, 250), dark: rgb(255, 255, 255, alpha: 0.03))
    static var listPane: Color { muted.opacity(0.10) }
    static var rowHover: Color { muted.opacity(0.25) }
    static var rowSelected: Color { accentHover }
    static var divider: Color { border.opacity(0.50) }
    static let track = adaptive(light: rgb(228, 228, 231), dark: rgb(255, 255, 255, alpha: 0.12))
    static let text = adaptive(light: rgb(39, 39, 42), dark: rgb(245, 245, 245))
    static let mutedForeground = adaptive(light: rgb(113, 113, 122), dark: rgb(129, 129, 129))
    static let label = mutedForeground
    static let tertiary = mutedForeground
    static let code = adaptive(light: rgb(82, 82, 91), dark: rgb(212, 212, 216))
    static let border = adaptive(light: rgb(228, 228, 231), dark: rgb(255, 255, 255, alpha: 0.06))
    static var hairline: Color { border.opacity(0.60) }
    static let input = adaptive(light: rgb(212, 212, 216), dark: rgb(255, 255, 255, alpha: 0.08))
    static let fieldFill = adaptive(light: rgb(255, 255, 255), dark: rgb(255, 255, 255, alpha: 0.08))
    static let accent = adaptive(light: rgb(27, 78, 216), dark: rgb(52, 107, 241))
    static let accentForeground = Color.white
    static let accentHover = adaptive(light: rgb(244, 244, 245), dark: rgb(255, 255, 255, alpha: 0.04))
    static let success = adaptive(light: rgb(16, 185, 129), dark: rgb(52, 211, 153))
    static let warning = Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
    static let error = adaptive(light: rgb(239, 68, 68), dark: rgb(248, 113, 113))
    static let claude = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let claudeFill = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255).opacity(0.45)
    static let codex = Color(red: 46 / 255, green: 229 / 255, blue: 118 / 255)
    static let codexFill = adaptive(light: rgb(161, 161, 170), dark: rgb(113, 113, 122))
    static let cursor = Color(red: 212 / 255, green: 1, blue: 0)
    static let cursorFill = Color(red: 212 / 255, green: 1, blue: 0).opacity(0.55)

    static var backgroundNSColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? rgb(10, 10, 10)
                : rgb(252, 252, 252)
        }
    }

    static var sidebarNSColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? rgb(17, 17, 17)
                : rgb(250, 250, 250)
        }
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static func accent(for provider: ProviderKind) -> Color {
        switch provider {
        case .claude: claude
        case .codex, .opencode: codex
        case .cursor: cursor
        }
    }

    static func chartStroke(for provider: ProviderKind) -> Color {
        switch provider {
        case .claude: claude
        case .codex, .opencode: text
        case .cursor: cursor
        }
    }

    static func chartFill(for provider: ProviderKind) -> Color {
        chartStroke(for: provider).opacity(0.12)
    }

    static func quotaFill(for provider: ProviderKind) -> Color {
        switch provider {
        case .claude: claudeFill
        case .codex, .opencode: codexFill
        case .cursor: cursorFill
        }
    }

    static func quotaFill(for provider: ProviderKind, remaining: Double) -> Color {
        switch QuotaSeverity.of(percentRemaining: remaining) {
        case .critical, .depleted:
            warning.opacity(0.50)
        default:
            quotaFill(for: provider)
        }
    }

    static func statusDot(_ kind: ConnectionKind) -> Color {
        switch kind {
        case .checking: tertiary
        case .ready: success
        case .warning: warning
        case .error: error
        }
    }
}

enum HarnaisType {
    static let section = Font.system(size: 14, weight: .regular)
    static let rowTitle = Font.system(size: 14, weight: .medium)
    static let status = Font.system(size: 13, weight: .regular)
    static let control = Font.system(size: 12, weight: .medium)
    static let code = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let version = Font.system(size: 12, weight: .regular, design: .monospaced)
}
