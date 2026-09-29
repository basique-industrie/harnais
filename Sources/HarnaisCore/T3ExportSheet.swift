import AppKit
import Domain
import SwiftUI

struct T3ExportSheet: View {
    let account: Account
    let snippet: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: HarnaisSheetMetrics.spacing) {
            HStack(spacing: 8) {
                ProviderMark(provider: account.provider, size: 20)
                Text("T3 Code configuration")
                    .font(HarnaisSheetMetrics.titleFont)
                    .foregroundStyle(HarnaisPalette.text)
            }
            Text("\(account.provider.displayName) · \(account.displayLabel())")
                .font(HarnaisSheetMetrics.subtitleFont)
                .foregroundStyle(HarnaisPalette.label)
            Text("Paste this JSON into T3 Settings → Providers when configuring the account manually.")
                .font(HarnaisType.status)
                .foregroundStyle(HarnaisPalette.label)
            ScrollView {
                Text(snippet)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(HarnaisPalette.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(minHeight: 180)
            .background(HarnaisPalette.fieldFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(HarnaisPalette.hairline, lineWidth: 1)
            }
            HStack(spacing: 8) {
                if copied {
                    SettingsCheck(title: "Copied")
                }
                Spacer(minLength: 0)
                HarnaisButton(title: "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                HarnaisButton(title: "Copy JSON", prominence: .primary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(HarnaisSheetMetrics.padding)
        .frame(width: 580, height: 400)
        .background(HarnaisPalette.background)
        .harnaisChrome(title: "T3 Code configuration", kind: .sheet)
        .toolbar(removing: .title)
    }
}
