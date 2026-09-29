import AppKit
import SwiftUI

/// Lucide glyphs for sidebar navigation and section headers.
/// Glossary: overview = all-subscriptions dashboard, limits = live quotas,
/// spend = local cost/token scan, islands = Iles rings, connections = logins,
/// harnesses = target apps receiving MCP entries.
enum LucideGlyph: String {
    case settings
    case info
    case blocks
    case chartNoAxesColumn
    case plus
    case package
    case bookOpen
    case unplug
    case layoutDashboard
    case gauge
    case lifeBuoy
    case ticket

    var resourceName: String {
        switch self {
        case .info: "LucideInfo"
        case .settings: "LucideSettings"
        case .blocks: "LucideBlocks"
        case .chartNoAxesColumn: "LucideChartNoAxesColumn"
        case .plus: "LucidePlus"
        case .package: "LucidePackage"
        case .bookOpen: "LucideBookOpen"
        case .unplug: "LucideUnplug"
        case .layoutDashboard: "LucideLayoutDashboard"
        case .gauge: "LucideGauge"
        case .lifeBuoy: "LucideLifeBuoy"
        case .ticket: "LucideTicket"
        }
    }
}

/// Canonical icon sizes. Do not use ad-hoc sizes in views.
enum HarnaisIconSize {
    static let appMark: CGFloat = 24
    static let sidebarMark: CGFloat = 12
    static let navGlyph: CGFloat = 15
    static let sectionMark: CGFloat = 16
    static let sheetMark: CGFloat = 22
    static let pickerMark: CGFloat = 26
}

struct LucideIcon: View {
    var glyph: LucideGlyph
    var size: CGFloat = 16
    var tint: NSColor = .secondaryLabelColor

    var body: some View {
        VectorTemplateMark(
            resource: (glyph.resourceName, "svg"),
            tint: tint
        )
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
