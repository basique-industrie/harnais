import AppKit
import Domain
import SwiftUI

enum HarnaisButtonProminence {
    case primary
    case outline
    case ghostMuted
}

enum HarnaisControlSize {
    case xs
    case sm
    case iconXs

    var height: CGFloat {
        switch self {
        case .xs, .iconXs: 24
        case .sm: 28
        }
    }

    var font: Font {
        switch self {
        case .xs, .iconXs: HarnaisType.control
        case .sm: Font.system(size: 13, weight: .medium)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .xs: 8
        case .sm: 10
        case .iconXs: 0
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .iconXs: 6
        case .xs, .sm: 8
        }
    }
}

struct HarnaisButton: View {
    let title: String
    var role: ButtonRole? = nil
    var prominence: HarnaisButtonProminence = .outline
    var size: HarnaisControlSize = .xs
    var enabled = true
    var expands = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(size.font)
                .foregroundStyle(foreground)
                .padding(.horizontal, size.horizontalPadding)
                .frame(maxWidth: expands ? .infinity : nil, minHeight: size.height)
                .background(background, in: RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                        .strokeBorder(border, lineWidth: prominence == .ghostMuted ? 0 : 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovering = $0 }
        .opacity(enabled ? 1 : 0.64)
        .accessibilityLabel(title)
    }

    private var foreground: Color {
        if role == .destructive {
            if prominence == .primary { return HarnaisPalette.accentForeground }
            return isHovering ? HarnaisPalette.error : HarnaisPalette.error.opacity(0.88)
        }
        switch prominence {
        case .primary:
            return HarnaisPalette.accentForeground
        case .outline:
            return isHovering ? HarnaisPalette.text : HarnaisPalette.text.opacity(0.92)
        case .ghostMuted:
            return isHovering ? HarnaisPalette.text : HarnaisPalette.label
        }
    }

    private var background: Color {
        if role == .destructive {
            if prominence == .primary {
                return isHovering ? HarnaisPalette.error.opacity(0.90) : HarnaisPalette.error
            }
            return isHovering ? HarnaisPalette.error.opacity(0.12) : Color.clear
        }
        switch prominence {
        case .primary:
            return isHovering ? HarnaisPalette.accent.opacity(0.90) : HarnaisPalette.accent
        case .outline:
            return isHovering ? HarnaisPalette.input.opacity(0.64) : HarnaisPalette.fieldFill
        case .ghostMuted:
            return isHovering ? HarnaisPalette.accentHover.opacity(0.55) : Color.clear
        }
    }

    private var border: Color {
        if role == .destructive {
            return prominence == .primary
                ? HarnaisPalette.error.opacity(0.80)
                : HarnaisPalette.error.opacity(isHovering ? 0.45 : 0.28)
        }
        switch prominence {
        case .primary:
            return HarnaisPalette.accent.opacity(0.80)
        case .outline:
            return HarnaisPalette.input
        case .ghostMuted:
            return Color.clear
        }
    }
}

struct HarnaisIconButton: View {
    let systemName: String
    var accessibilityLabel: String
    var spinning = false
    var selected = false
    var tint: Color = HarnaisPalette.label
    var prominence: HarnaisButtonProminence = .ghostMuted
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if spinning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(selected || isHovering ? HarnaisPalette.text : tint)
                }
            }
            .frame(width: 24, height: 24)
            .background(
                selected || isHovering ? HarnaisPalette.rowSelected : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(spinning)
        .help(accessibilityLabel)
    }
}
