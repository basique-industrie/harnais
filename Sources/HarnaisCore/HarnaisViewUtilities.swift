import AppKit
import Domain
import SwiftUI

enum HarnaisPasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

struct BoundedScrollView<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                content()
                    .frame(width: max(proxy.size.width, 1), alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(.zero)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }
}

struct SettingsCheck: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HarnaisPalette.success)
            Text(title)
                .font(HarnaisType.control)
                .foregroundStyle(HarnaisPalette.label)
                .lineLimit(1)
        }
        .frame(minHeight: 24)
        .accessibilityLabel(title)
    }
}

extension View {
    func harnaisChrome(
        title: String = "Harnais",
        kind: HarnaisChromeKind = .window,
        titlebarLeading: Binding<CGFloat>? = nil,
        titlebarHeight: Binding<CGFloat>? = nil
    ) -> some View {
        tint(HarnaisPalette.accent)
            .background(HarnaisPalette.sidebar.ignoresSafeArea())
            .background(
                WindowConfigurator(
                    title: title,
                    kind: kind,
                    titlebarLeading: titlebarLeading,
                    titlebarHeight: titlebarHeight
                )
            )
    }
}
