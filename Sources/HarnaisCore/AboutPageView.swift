import AppKit
import Infrastructure
import SwiftUI

struct AboutPageView: View {
    @State private var showingLicenses = false
    @State private var licenseDocument = LicenseDocument.harnais
    private let identity = AppIdentity.current
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }

    var body: some View {
        HarnaisCanvas(title: "About Harnais", subtitle: "Accounts, usage and shared tools for your coding apps.") {
            VStack(spacing: 9) {
                if let url = Bundle.main.url(forResource: "Harnais", withExtension: "icns"),
                   let icon = NSImage(contentsOf: url) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 80, height: 80)
                        .accessibilityHidden(true)
                }
                Text(identity.displayName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(HarnaisPalette.text)
                Text(identity.isDevelopment ? "Development build" : "Your coding accounts, together")
                    .font(.system(size: 14))
                    .foregroundStyle(HarnaisPalette.label)
                Text("Version \(version) (\(build))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HarnaisPalette.tertiary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .background(HarnaisPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(HarnaisPalette.border, lineWidth: 1) }

            HarnaisUpdateSection()

            Text("Account settings and credentials stay on this Mac. Connected services receive the requests you authorize. Harnais has no analytics or advertising.")
                .font(.system(size: 13))
                .foregroundStyle(HarnaisPalette.label)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                HarnaisButton(title: "Website", size: .sm) { open("https://jean-humann.github.io/harnais-site/") }
                HarnaisButton(title: "Privacy", size: .sm) { open("https://jean-humann.github.io/harnais-site/privacy.html") }
                HarnaisButton(title: "Licenses", size: .sm) { showingLicenses = true }
                HarnaisButton(title: "Support", size: .sm) { open("https://github.com/basique-industrie/harnais/issues") }
            }
            .frame(maxWidth: .infinity)

            Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "Copyright © 2026 Jean Humann.")
                .font(.system(size: 12))
                .foregroundStyle(HarnaisPalette.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingLicenses) { licensesSheet }
    }

    private var licensesSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Licenses and acknowledgements")
                .font(HarnaisSheetMetrics.titleFont)
            HarnaisSegmentedControl(items: LicenseDocument.allCases, selection: $licenseDocument,
                                    title: { $0.rawValue }, accessibilityTitle: "License document")
            ScrollView {
                Text(licenseText)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                HarnaisButton(title: "Done", size: .sm) { showingLicenses = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(HarnaisSheetMetrics.padding)
        .frame(width: 620, height: 480)
        .foregroundStyle(HarnaisPalette.text)
        .background(HarnaisPalette.background)
        .onExitCommand { showingLicenses = false }
    }

    private var licenseText: String {
        let file = licenseDocument.file
        guard let url = Bundle.main.url(forResource: file.name, withExtension: file.extension),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "This license document is unavailable in this build." }
        return text
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}

private enum LicenseDocument: String, CaseIterable {
    case harnais = "Harnais"
    case dependencies = "Dependencies"
    case whatsapp = "WhatsApp"

    var file: (name: String, extension: String) {
        switch self {
        case .harnais: ("LICENSE", "txt")
        case .dependencies: ("THIRD_PARTY_NOTICES", "md")
        case .whatsapp: ("WhatsApp-licenses", "txt")
        }
    }
}
