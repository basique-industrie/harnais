import AppKit
import Domain
import Infrastructure
import SwiftUI

struct AddAccountSheet: View {
    @Bindable var runtime: HarnaisRuntime
    var initialProvider: ProviderKind = .claude
    var initialLabel: String = "Personal"
    var onCreated: (Account) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var provider: ProviderKind
    @State private var label: String
    @State private var shareCodexHistory = false
    @State private var errorMessage: String?

    init(
        runtime: HarnaisRuntime,
        initialProvider: ProviderKind = .claude,
        initialLabel: String = "Personal",
        onCreated: @escaping (Account) -> Void
    ) {
        self.runtime = runtime
        self.initialProvider = initialProvider
        self.initialLabel = initialLabel
        self.onCreated = onCreated
        _provider = State(initialValue: initialProvider)
        _label = State(initialValue: initialLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HarnaisSheetMetrics.spacing) {
            Text("Add account")
                .font(HarnaisSheetMetrics.titleFont)
                .foregroundStyle(HarnaisPalette.text)
            Text("Keep a separate login for work or personal use.")
                .font(HarnaisSheetMetrics.subtitleFont)
                .foregroundStyle(HarnaisPalette.label)
                .lineSpacing(6)
            HStack(spacing: 8) {
                ForEach(ProviderKind.allCases) { kind in
                    providerCard(kind)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Display name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HarnaisPalette.label)
                HarnaisField(text: $label, placeholder: "Name", width: nil)
                if !AccountNaming.isReadable(label) {
                    Text("Use a name like Work or Personal.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HarnaisPalette.warning)
                }
            }
            if provider == .codex {
                Toggle("Share Codex history with T3", isOn: $shareCodexHistory)
                    .foregroundStyle(HarnaisPalette.text)
                    .toggleStyle(.switch)
                    .tint(HarnaisPalette.accent)
                    .help("Keeps sessions in ~/.codex and stores this login in a shadow home. Leave off unless you need T3 to continue the same threads.")
                Text("This account keeps its own sign-in, even when history is shared.")
                    .font(.system(size: 12))
                    .foregroundStyle(HarnaisPalette.label)
            }
            if BinaryLocator.resolve(provider, override: nil) == nil {
                HStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(HarnaisPalette.error)
                        .frame(width: 6, height: 6)
                    Text("Not found · CLI not detected on PATH.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HarnaisPalette.warning)
                    Spacer()
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HarnaisPalette.warning)
            }
            HStack {
                Spacer(minLength: 0)
                HarnaisButton(title: "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if BinaryLocator.resolve(provider, override: nil) == nil {
                    HarnaisButton(title: "Open install docs", prominence: .primary) {
                        NSWorkspace.shared.open(provider.installURL)
                    }
                    .keyboardShortcut(.defaultAction)
                    HarnaisButton(
                        title: "Create and sign in",
                        enabled: false
                    ) {}
                } else {
                    HarnaisButton(
                        title: "Create and sign in",
                        prominence: .primary,
                        enabled: canCreate
                    ) {
                        do {
                            let account = try runtime.addAccount(
                                provider: provider,
                                label: label,
                                importDefault: false,
                                shareCodexHistory: shareCodexHistory
                            )
                            dismiss()
                            onCreated(account)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(HarnaisSheetMetrics.padding)
        .frame(width: 520)
        .background(HarnaisPalette.background)
        .harnaisChrome(title: "Add account", kind: .sheet)
        .toolbar(removing: .title)
        .tint(HarnaisPalette.accent)
    }

    private var canCreate: Bool {
        let named = AccountNaming.isReadable(label)
        return named && BinaryLocator.resolve(provider, override: nil) != nil
    }

    private func providerCard(_ kind: ProviderKind) -> some View {
        let selected = provider == kind
        return Button {
            selectProvider(kind)
        } label: {
            ProviderPickerCard(kind: kind, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(kind.displayName)
    }

    private func selectProvider(_ kind: ProviderKind) {
        let previousSuggestion = AccountNaming.suggestedLabel(for: provider, existing: runtime.accounts)
        provider = kind
        if label.trimmingCharacters(in: .whitespacesAndNewlines) == previousSuggestion {
            label = AccountNaming.suggestedLabel(for: kind, existing: runtime.accounts)
        }
        if kind != .codex {
            shareCodexHistory = false
        }
    }
}

private struct ProviderPickerCard: View {
    let kind: ProviderKind
    let selected: Bool
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 8) {
            ProviderMark(provider: kind, size: 26)
                .allowsHitTesting(false)
            Text(kind.displayName)
                .font(.system(size: 14, weight: selected ? .semibold : .medium))
                .foregroundStyle(HarnaisPalette.text)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(fill, in: RoundedRectangle(cornerRadius: HarnaisSheetMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HarnaisSheetMetrics.cornerRadius, style: .continuous)
                .strokeBorder(border, lineWidth: selected ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: HarnaisSheetMetrics.cornerRadius, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private var fill: Color {
        if selected { return HarnaisPalette.rowSelected }
        if isHovering { return HarnaisPalette.rowHover }
        return HarnaisPalette.fieldFill
    }

    private var border: Color {
        HarnaisPalette.input
    }
}
