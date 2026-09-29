import Domain
import SwiftUI

struct SkillMark: View {
    let icon: String
    var size: CGFloat = 32
    var body: some View {
        Group {
            if let kind = IntegrationKind(rawValue: icon), kind != .custom {
                IntegrationMark(kind: kind, size: size * 0.8)
            } else {
                Image(systemName: icon).font(.system(size: size * 0.62, weight: .medium))
                    .foregroundStyle(HarnaisPalette.accent)
            }
        }.frame(width: size + 8, height: size + 8)
            .background(HarnaisPalette.muted, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
    }
}
