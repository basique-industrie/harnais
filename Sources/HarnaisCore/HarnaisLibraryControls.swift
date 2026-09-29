import Domain
import SwiftUI

/// Menu labels use the same dimensions and palette as Harnais buttons.
struct HarnaisMenu<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var primary = false
    var width: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Menu(content: content) {
            if let systemImage { Label(title, systemImage: systemImage) }
            else { Text(title) }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .font(HarnaisControlSize.sm.font)
        .tint(primary ? HarnaisPalette.accentForeground : HarnaisPalette.text)
        .foregroundStyle(primary ? HarnaisPalette.accentForeground : HarnaisPalette.text)
        .fixedSize(horizontal: width == nil, vertical: true)
        .padding(.horizontal, HarnaisControlSize.sm.horizontalPadding)
        .frame(width: width, height: HarnaisControlSize.sm.height)
        .background(fill, in: RoundedRectangle(cornerRadius: HarnaisControlSize.sm.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HarnaisControlSize.sm.cornerRadius)
                .strokeBorder(primary ? HarnaisPalette.accent.opacity(0.8) : HarnaisPalette.input, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .opacity(enabled ? 1 : 0.64)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }

    private var fill: Color {
        if primary { return hovering ? HarnaisPalette.accent.opacity(0.9) : HarnaisPalette.accent }
        return hovering ? HarnaisPalette.input.opacity(0.64) : HarnaisPalette.fieldFill
    }
}

struct HarnaisLibraryFilters: View {
    let searchTitle: String
    @Binding var search: String
    let accounts: [Account]
    @Binding var accountID: UUID?
    @FocusState private var searchFocused: Bool

    private var selectedAccount: Account? { accounts.first { $0.id == accountID } }
    private var accountTitle: String {
        selectedAccount.map { "\($0.provider.displayName) · \($0.displayLabel())" } ?? "All accounts"
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                searchField.frame(minWidth: 160, maxWidth: 300)
                Spacer(minLength: 12)
                accountControls
            }
            VStack(alignment: .trailing, spacing: 10) {
                searchField
                accountControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .focusedSceneValue(\.harnaisFind, { searchFocused = true })
        .onChange(of: accounts.map(\.id)) { _, ids in
            if let accountID, !ids.contains(accountID) { self.accountID = nil }
        }
    }

    private var accountControls: some View {
        HStack(spacing: 8) {
            if accountID != nil || !search.isEmpty {
                HarnaisButton(title: "Clear filters", prominence: .ghostMuted) {
                    search = ""
                    accountID = nil
                }
            }
            accountMenu
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(HarnaisPalette.label).accessibilityHidden(true)
            TextField(searchTitle, text: $search)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel(searchTitle)
        }
        .font(HarnaisControlSize.sm.font)
        .foregroundStyle(HarnaisPalette.text)
        .padding(.horizontal, HarnaisControlSize.sm.horizontalPadding)
        .frame(height: HarnaisControlSize.sm.height)
        .background(HarnaisPalette.fieldFill, in: RoundedRectangle(cornerRadius: HarnaisControlSize.sm.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HarnaisControlSize.sm.cornerRadius)
                .strokeBorder(searchFocused ? HarnaisPalette.accent : HarnaisPalette.input, lineWidth: 1)
        }
    }

    private var accountMenu: some View {
        HarnaisMenu(title: accountTitle, systemImage: "line.3.horizontal.decrease", width: 230) {
            Button { accountID = nil } label: {
                if accountID == nil { Label("All accounts", systemImage: "checkmark") }
                else { Text("All accounts") }
            }
            Divider()
            ForEach(ProviderKind.allCases) { provider in
                let members = accounts.filter { $0.provider == provider }
                if !members.isEmpty {
                    Section(provider.displayName) {
                        ForEach(members) { account in
                            Button { accountID = account.id } label: {
                                if accountID == account.id { Label(account.displayLabel(), systemImage: "checkmark") }
                                else { Text(account.displayLabel()) }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Filter by account")
        .accessibilityValue(accountTitle)
        .help(accountTitle)
    }
}
