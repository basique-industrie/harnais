import SwiftUI

enum HarnaisPageMetrics {
    static let horizontal: CGFloat = 24
    static let top: CGFloat = 16
    static let bottom: CGFloat = 32
    static let maxWidth: CGFloat = 960
    static let sectionSpacing: CGFloat = 24
}

enum HarnaisSheetMetrics {
    static let padding: CGFloat = 24
    static let spacing: CGFloat = 12
    static let cornerRadius: CGFloat = 12
    static let titleFont = Font.system(size: 16, weight: .semibold)
    static let subtitleFont = Font.system(size: 12, weight: .medium)
}

struct HarnaisSegmentedControl<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    var title: (Item) -> String
    var accessibilityTitle: String? = nil
    var quiet = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let selected = selection == item
                Button {
                    selection = item
                } label: {
                    Text(title(item))
                        .font(HarnaisType.control)
                        .foregroundStyle(selected ? HarnaisPalette.text : HarnaisPalette.label)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(
                            selected ? HarnaisPalette.surface : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            quiet ? HarnaisPalette.muted : HarnaisPalette.rowSelected,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle ?? "Options")
    }
}

struct HarnaisCapsuleBadge: View {
    let text: String
    var tint: Color = HarnaisPalette.warning

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(HarnaisPalette.surface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(HarnaisPalette.hairline, lineWidth: 1)
            }
    }
}

struct HarnaisStatusBanner: View {
    var errorMessage: String?
    var successMessage: String?

    var body: some View {
        if let errorMessage, !errorMessage.isEmpty {
            Text(errorMessage)
                .font(HarnaisType.status)
                .foregroundStyle(HarnaisPalette.warning)
        } else if let successMessage, !successMessage.isEmpty {
            Text(successMessage)
                .font(HarnaisType.status)
                .foregroundStyle(HarnaisPalette.success)
        }
    }
}

/// Shared content column: title, optional toolbar, status, sections.
struct HarnaisCanvas<Toolbar: View, Content: View>: View {
    var title: String?
    var subtitle: String?
    var titleOverride: AnyView? = nil
    var titleAccessory: AnyView? = nil
    var errorMessage: String?
    var successMessage: String?
    var toolbar: Toolbar
    var content: Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        titleOverride: AnyView? = nil,
        titleAccessory: AnyView? = nil,
        errorMessage: String? = nil,
        successMessage: String? = nil,
        @ViewBuilder toolbar: () -> Toolbar,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleOverride = titleOverride
        self.titleAccessory = titleAccessory
        self.errorMessage = errorMessage
        self.successMessage = successMessage
        self.toolbar = toolbar()
        self.content = content()
    }

    var body: some View {
        BoundedScrollView {
            VStack(alignment: .leading, spacing: HarnaisPageMetrics.sectionSpacing) {
                header
                if let errorMessage, !errorMessage.isEmpty {
                    HarnaisStatusBanner(errorMessage: errorMessage, successMessage: nil)
                } else if let successMessage, !successMessage.isEmpty {
                    HarnaisStatusBanner(errorMessage: nil, successMessage: successMessage)
                }
                content
            }
            .padding(.horizontal, HarnaisPageMetrics.horizontal)
            .padding(.top, HarnaisPageMetrics.top)
            .padding(.bottom, HarnaisPageMetrics.bottom)
            .frame(maxWidth: HarnaisPageMetrics.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var header: some View {
        if titleOverride != nil || title != nil {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    heading
                    Spacer(minLength: 8)
                    toolbar.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 12) {
                    heading
                    toolbar.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                if let titleOverride {
                    titleOverride
                } else if let title {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(HarnaisPalette.text)
                        .fixedSize(horizontal: true, vertical: false)
                    if let titleAccessory { titleAccessory }
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(HarnaisType.status)
                    .foregroundStyle(HarnaisPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}

extension HarnaisCanvas where Toolbar == EmptyView {
    init(
        title: String? = nil,
        subtitle: String? = nil,
        errorMessage: String? = nil,
        successMessage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            titleOverride: nil,
            titleAccessory: nil,
            errorMessage: errorMessage,
            successMessage: successMessage,
            toolbar: { EmptyView() },
            content: content
        )
    }
}
