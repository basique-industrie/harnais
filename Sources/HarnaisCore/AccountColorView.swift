import Domain
import SwiftUI

extension AccountColor {
    var tint: Color {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }
}

struct AccountColorMark: View {
    let account: Account

    var body: some View {
        if let color = account.color {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.tint)
                .frame(width: 4, height: 14)
                .accessibilityLabel("\(color.title) account color")
        }
    }
}

struct AccountColorSection: View {
    let account: Account
    let isNativeT3Account: Bool
    let onChange: (AccountColor?, Bool) -> Void

    var body: some View {
        SettingsSection(title: "Appearance") {
            SettingsRow(title: "Account color", description: "Identify this account across Harnais.") {
                Picker("Account color", selection: Binding(
                    get: { account.color?.rawValue ?? "" },
                    set: { onChange(AccountColor(rawValue: $0), account.managesT3Color == true) }
                )) {
                    Text("Default").tag("")
                    ForEach(AccountColor.allCases, id: \.rawValue) { color in
                        Label(color.title, systemImage: "circle.fill").foregroundStyle(color.tint).tag(color.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            if !isNativeT3Account {
                SettingsDivider()
                SettingsRow(title: "Use this color in T3 Code",
                            description: "Updates this profile’s T3 color when synced. Turn off to manage it in T3.") {
                    Toggle("Use this color in T3 Code", isOn: Binding(
                        get: { account.managesT3Color == true },
                        set: { onChange(account.color, $0) }
                    )).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}
