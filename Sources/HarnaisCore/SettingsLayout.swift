import AppKit
import Domain
import SwiftUI

struct SettingsSection<Content: View>: View {
    let title: String
    var icon: AnyView? = nil
    var headerAction: AnyView? = nil
    var grouped = true
    var collapsible = false
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        icon: AnyView? = nil,
        headerAction: AnyView? = nil,
        grouped: Bool = true,
        collapsible: Bool = false,
        isExpanded: Binding<Bool> = .constant(true),
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.headerAction = headerAction
        self.grouped = grouped
        self.collapsible = collapsible
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !collapsible || isExpanded {
                VStack(spacing: 0) {
                    content()
                }
                .background(grouped ? HarnaisPalette.cardFill : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    if grouped {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(HarnaisPalette.hairline, lineWidth: 1)
                    }
                }
                .shadow(color: Color.black.opacity(0.05), radius: 1, y: 1)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        let label = HStack(alignment: .center, spacing: 8) {
            if let icon { icon }
            Text(title)
                .font(HarnaisType.section)
                .tracking(-0.07)
                .foregroundStyle(HarnaisPalette.text.opacity(0.70))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let headerAction { headerAction }
            if collapsible {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HarnaisPalette.label)
            }
        }
        .frame(minHeight: 28, alignment: .center)
        .contentShape(Rectangle())

        if collapsible {
            Button {
                isExpanded.toggle()
            } label: {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var description: String? = nil
    var status: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(HarnaisType.rowTitle)
                    .tracking(-0.07)
                    .foregroundStyle(HarnaisPalette.text)
                if let description {
                    CommandText(description)
                        .font(HarnaisType.status)
                        .foregroundStyle(HarnaisPalette.label)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let status {
                    CommandText(status)
                        .font(.system(size: 12))
                        .foregroundStyle(HarnaisPalette.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(HarnaisPalette.divider)
            .frame(height: 1)
    }
}
