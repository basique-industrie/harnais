import Domain
import SwiftUI

/// Label/value facts shown in the banked-reset confirmation.
struct ResetPlanRows: View {
    let rows: [ResetPlan.Row]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().overlay(HarnaisPalette.hairline) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.label)
                        .font(.system(size: 12))
                        .foregroundStyle(HarnaisPalette.label)
                        .frame(width: 64, alignment: .leading)
                    Text(row.value)
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(HarnaisPalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(HarnaisPalette.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(HarnaisPalette.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
