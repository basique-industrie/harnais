import AppKit
import Domain
import Infrastructure
import SwiftUI

struct SettingsPageView: View {
    @Bindable var runtime: HarnaisRuntime

    var body: some View {
        HarnaisCanvas(
            title: "Settings",
            errorMessage: runtime.errorMessage,
            successMessage: runtime.successMessage
        ) {
            integrations
            usageWindows
            terminal
            path
            data
        }
        .onAppear { runtime.refreshTerminals() }
    }

    private var usageWindows: some View {
        SettingsSection(title: "Codex weekly window") {
            SettingsRow(
                title: "Automatically start new Codex weeks",
                description: "While Harnais is open, send one small request when an unused week is detected. Uses a little allowance. Never spends banked resets."
            ) {
                Toggle("Automatically start new Codex weeks", isOn: Binding(
                    get: { runtime.settings.autoStartCodexWeeks == true },
                    set: { runtime.setAutoStartCodexWeeks($0) }
                )).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var integrations: some View {
        SettingsSection(
            title: "External apps",
            icon: AnyView(LucideIcon(glyph: .blocks, size: 16, tint: sectionTint))
        ) {
            SettingsRow(
                title: "T3 Code",
                description: "Add or update extra profiles. Keeps T3 settings and saves a backup."
            ) {
                if runtime.didUpdateT3 {
                    SettingsCheck(title: HarnaisRuntime.t3UpdatedMessage)
                } else {
                    HarnaisButton(title: "Sync extra profiles") { runtime.applyT3() }
                }
            }
            SettingsDivider()
            SettingsRow(
                title: "Iles",
                description: ilesDescription
            ) {
                if runtime.ilesState == .extensionFallback {
                    HStack(spacing: 8) {
                        SettingsCheck(title: "Extension installed")
                        HarnaisButton(title: "Reinstall", prominence: .ghostMuted) {
                            runtime.installIlesExtension()
                        }
                    }
                } else {
                    HarnaisButton(title: "Install extension") {
                        runtime.installIlesExtension()
                    }
                }
            }
        }
    }

    private var ilesDescription: String? {
        switch runtime.ilesState {
        case .extensionFallback:
            return "Extension installed. It refreshes quotas on its own when they go stale. Ring toggles live in Usage → Islands."
        case .missing:
            return "Adds Harnais as a source in Iles. Ring toggles live in Usage → Islands."
        }
    }

    private var terminal: some View {
        SettingsSection(title: "Terminal") {
            ForEach(Array(runtime.installedTerminals.enumerated()), id: \.element.id) { index, app in
                if index > 0 { SettingsDivider() }
                TerminalAppRow(
                    app: app,
                    selected: runtime.resolvedTerminal?.kind == app.kind
                ) {
                    runtime.selectTerminal(app.kind)
                }
            }
        }
    }

    private var path: some View {
        SettingsSection(title: "Account commands") {
            SettingsRow(
                title: "Run accounts from your terminal",
                description: runtime.pathConfigured
                    ? nil
                    : "Add account commands such as `claude-work` to new terminal sessions."
            ) {
                if runtime.pathConfigured {
                    SettingsCheck(title: "Ready")
                } else {
                    HarnaisButton(title: "Add to PATH") { runtime.installPath() }
                }
            }
        }
    }

    private var data: some View {
        SettingsSection(title: "Data") {
            SettingsRow(
                title: "Folder",
                description: runtime.identity.dataDirectory.path
            ) {
                HStack(spacing: 6) {
                    HarnaisIconButton(
                        systemName: "square.on.square",
                        accessibilityLabel: "Copy data folder"
                    ) {
                        HarnaisPasteboard.copy(runtime.identity.dataDirectory.path)
                    }
                    HarnaisButton(title: "Show in Finder") { runtime.revealDataDirectory() }
                }
            }
        }
    }

    private var sectionTint: NSColor {
        NSColor.labelColor.withAlphaComponent(0.70)
    }
}

private struct TerminalAppRow: View {
    let app: InstalledTerminal
    let selected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                WorkspaceAppIcon(url: app.appURL, size: 20)
                Text(app.kind.displayName)
                    .font(HarnaisType.rowTitle)
                    .foregroundStyle(HarnaisPalette.text)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HarnaisPalette.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(fill)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(app.kind.displayName)
    }

    private var fill: Color {
        if selected { return HarnaisPalette.rowSelected }
        if isHovering { return HarnaisPalette.rowHover }
        return Color.clear
    }
}

private struct WorkspaceAppIcon: View {
    let url: URL
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            .accessibilityHidden(true)
    }

    private var icon: NSImage {
        let original = NSWorkspace.shared.icon(forFile: url.path)
        let image = original.copy() as? NSImage ?? original
        image.size = NSSize(width: size, height: size)
        return image
    }
}
