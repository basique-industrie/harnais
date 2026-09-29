import AppKit
import Domain
import SwiftUI

struct IntegrationMark: View {
    let kind: IntegrationKind
    var size: CGFloat = 20

    var body: some View {
        // Full-color brand assets.
        // Never templated: tinting would destroy brand colors.
        if kind == .custom {
            Image(systemName: "network").font(.system(size: size * 0.8)).frame(width: size, height: size)
                .foregroundStyle(HarnaisPalette.accent)
        } else {
        VectorTemplateMark(
            resource: kind.iconResource,
            tint: kind.iconTint,
            isTemplate: kind == .aikido
        )
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        }
    }
}

extension IntegrationKind {
    var iconResource: (name: String, ext: String) {
        switch self {
        case .googleDrive: ("GoogleDriveIcon", "svg")
        case .gmail: ("GmailIcon", "svg")
        case .whatsapp: ("WhatsAppIcon", "svg")
        case .aikido: ("AikidoIcon", "svg")
        case .excalidraw: ("ExcalidrawIcon", "svg")
        case .outlook: ("OutlookIcon", "svg")
        case .slack: ("SlackIcon", "svg")
        case .grafana: ("GrafanaIcon", "svg")
        case .atlassian: ("AtlassianIcon", "svg")
        case .custom: ("LucideUnplug", "svg")
        }
    }

    var iconTint: NSColor {
        switch self {
        case .aikido, .excalidraw: .labelColor
        case .gmail: .systemRed
        case .whatsapp: .systemGreen
        case .outlook: .systemBlue
        case .googleDrive:
            NSColor(srgbRed: 26 / 255, green: 115 / 255, blue: 232 / 255, alpha: 1)
        case .slack:
            NSColor(srgbRed: 224 / 255, green: 30 / 255, blue: 90 / 255, alpha: 1)
        case .grafana:
            NSColor(srgbRed: 244 / 255, green: 104 / 255, blue: 0 / 255, alpha: 1)
        case .custom: .labelColor
        case .atlassian:
            NSColor(srgbRed: 38 / 255, green: 132 / 255, blue: 255 / 255, alpha: 1)
        }
    }
}
