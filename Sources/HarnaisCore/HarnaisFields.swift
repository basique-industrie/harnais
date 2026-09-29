import AppKit
import Domain
import SwiftUI

struct HarnaisField: View {
    @Binding var text: String
    var placeholder: String
    var width: CGFloat? = 224
    var secure = false
    var onCommit: () -> Void = {}

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(HarnaisPalette.text)
            .onSubmit(onCommit)
            .padding(.horizontal, 10)
            .frame(width: width, height: 28)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(HarnaisPalette.fieldFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(HarnaisPalette.input, lineWidth: 1)
            }
    }
}
