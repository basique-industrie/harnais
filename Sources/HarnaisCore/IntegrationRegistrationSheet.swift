import AppKit
import Domain
import Infrastructure
import SwiftUI

struct IntegrationRegistrationSheet: View {
    let kind: IntegrationKind
    @Bindable var runtime: HarnaisRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var scope: OAuthRegistrationScope = .personal
    @State private var clientID = ""
    @State private var secret = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IntegrationMark(kind: kind, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up Harnais · \(kind.displayName)").font(HarnaisSheetMetrics.titleFont)
                    Text(kind.registrationTitle).font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("App owner", selection: $scope) {
                        ForEach(OAuthRegistrationScope.allCases) { value in Text(value.label).tag(value) }
                    }.pickerStyle(.segmented)
                    Text("App name: \(scope.appName)").font(HarnaisType.rowTitle)
                    Text("Use the \(scope.label.lowercased()) workspace or project. This registration is saved separately from the other owner.")
                        .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                    Text("Register the service app once. Each Shared connection keeps its own service login and can be used by multiple coding accounts.")
                        .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                    ForEach(Array(kind.registrationSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1).").foregroundStyle(HarnaisPalette.accent)
                            Text(step).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(HarnaisType.control)
                    }
                    HStack {
                        if let url = kind.registrationConsoleURL {
                            HarnaisButton(title: "Open \(kind == .slack ? "Slack apps" : "Google Cloud")…") { NSWorkspace.shared.open(url) }
                        }
                        HarnaisButton(title: "Service documentation…", prominence: .ghostMuted) { NSWorkspace.shared.open(kind.registrationDocumentationURL) }
                        if let manifest = kind.slackAppManifest(scope: scope) {
                            HarnaisButton(title: "Copy app manifest") { HarnaisPasteboard.copy(manifest); message = "Manifest copied. Paste it into Slack's Create app form." }
                        }
                    }
                    if kind.authKind == .oauth {
                        LabeledContent("Redirect URI") {
                            Text(IntegrationOAuth.redirectURI).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            HarnaisIconButton(systemName: "square.on.square", accessibilityLabel: "Copy redirect URI") { HarnaisPasteboard.copy(IntegrationOAuth.redirectURI) }
                        }
                    }
                    if !kind.defaultScopes.isEmpty {
                        DisclosureGroup("Requested permissions · \(kind.defaultScopes.count)") {
                            Text(kind.defaultScopes.joined(separator: "\n")).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        }.font(HarnaisType.control)
                    }
                    if kind.needsRegisteredOAuthClient {
                        Divider()
                        Text("Save the app you created").font(HarnaisType.rowTitle)
                        TextField("Harnais client ID", text: $clientID).textFieldStyle(.roundedBorder)
                        SecureField("Client secret, leave blank to keep the saved secret", text: $secret).textFieldStyle(.roundedBorder)
                        Text("Use credentials issued to your Harnais app. Saving here does not create an app in the service console or verify its owner. Secrets stay on this Mac.")
                            .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                    } else if kind == .atlassian {
                        HarnaisButton(title: busy ? "Registering…" : "Register \(scope.appName) client", prominence: .primary, enabled: !busy) { register() }
                    }
                    if let message { Text(message).font(HarnaisType.control).textSelection(.enabled) }
                }.padding(.trailing, 8)
            }.frame(maxHeight: 490)
            HStack {
                Spacer()
                HarnaisButton(title: "Done", enabled: !busy) { dismiss() }.keyboardShortcut(.cancelAction)
                if kind.needsRegisteredOAuthClient {
                    HarnaisButton(title: "Save app credentials", prominence: .primary, enabled: !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { save() }
                }
            }
        }.padding(24).frame(width: 640).background(HarnaisPalette.background)
        .harnaisChrome(title: "Service app registration", kind: .sheet).toolbar(removing: .title)
        .onAppear(perform: loadRegistration)
        .onChange(of: scope) { _, _ in loadRegistration() }
    }

    private func loadRegistration() {
        clientID = (try? runtime.integrations.clients.record(for: kind, scope: scope))?.clientId ?? ""
        secret = ""
        message = clientID.isEmpty ? nil : "A client ID is saved for \(scope.label). Check the service console to verify the app and its owner."
    }

    private func save() {
        do {
            try runtime.integrations.saveOAuthClientRegistration(kind: kind, scope: scope, clientID: clientID, clientSecret: secret)
            secret = ""
            runtime.reload()
            message = "App credentials saved. Add a Shared connection to authorize the service login. Existing connections keep their own client credentials."
        } catch { message = error.localizedDescription }
    }

    private func register() {
        busy = true
        let service = runtime.integrations
        let scope = self.scope
        Task.detached {
            do {
                _ = try service.registerOAuthClient(kind, scope: scope)
                await MainActor.run { runtime.reload(); message = "Harnais client registration is saved. Add an Atlassian connection to authorize access."; busy = false }
            } catch { await MainActor.run { message = error.localizedDescription; busy = false } }
        }
    }
}
