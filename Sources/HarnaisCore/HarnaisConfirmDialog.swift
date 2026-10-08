import AppKit
import Domain
import SwiftUI

struct HarnaisConfirmDialog: View {
    let title: String
    let message: String
    var confirmTitle = "Delete"
    var cancelTitle = "Cancel"
    var confirmRole: ButtonRole? = .destructive
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(HarnaisPalette.text)
                    Text(message)
                        .font(HarnaisType.status)
                        .foregroundStyle(HarnaisPalette.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    HarnaisButton(title: cancelTitle, action: onCancel)
                    HarnaisButton(
                        title: confirmTitle,
                        role: confirmRole,
                        prominence: .primary,
                        action: onConfirm
                    )
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(width: 420)
            .background(HarnaisPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: HarnaisSheetMetrics.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HarnaisSheetMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(HarnaisPalette.hairline, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.16), radius: 24, y: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .accessibilityAddTraits(.isModal)
    }
}
