import AppKit
import Domain
import Infrastructure
import SwiftUI

struct IntegrationConnectSheet: View {
    let kind: IntegrationKind
    @Bindable var runtime: HarnaisRuntime
    @Environment(\.dismiss) private var dismiss

    @State private var label: String
    @State private var endpoint = ""
    @State private var localCanvas = false
    @State private var grafanaURL = ""
    @State private var grafanaToken = ""
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var errorMessage: String?
    @State private var signingIn = false
    @State private var loginCancellation: OAuthCancellation?
    @State private var showAppSetup = false
    @State private var useCustomApp = false
    @State private var registrationScope: OAuthRegistrationScope = .personal

    init(kind: IntegrationKind, runtime: HarnaisRuntime, initialEndpoint: String? = nil) {
        self.kind = kind
        self.runtime = runtime
        _endpoint = State(initialValue: initialEndpoint ?? "")
        _label = State(
            initialValue: IntegrationNaming.suggestedLabel(for: kind, existing: runtime.connections)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HarnaisSheetMetrics.spacing) {
            HStack(spacing: 8) {
                IntegrationMark(kind: kind, size: 22)
                Text("Connect \(kind.displayName)")
                    .font(HarnaisSheetMetrics.titleFont)
                    .foregroundStyle(HarnaisPalette.text)
            }
            Text("Sign in once in Harnais. This connection will be shared with your local coding accounts.")
                .font(HarnaisSheetMetrics.subtitleFont)
                .foregroundStyle(HarnaisPalette.label)
                .fixedSize(horizontal: false, vertical: true)
            field(title: "Display name") {
                HarnaisField(text: $label, placeholder: "Name", width: nil)
            }
            if kind == .custom {
                field(title: "MCP server URL") {
                    HarnaisField(text: $endpoint, placeholder: "https://example.com/mcp", width: nil)
                }
            }
            if kind == .aikido || kind == .excalidraw {
                Text(kind.oauthSetupHint).font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                if kind == .excalidraw {
                    Toggle("Use local canvas tools", isOn: $localCanvas)
                    Text("Local canvas keeps the existing 26 canvas tools. The official remote server provides a different diagram tool set.")
                        .font(HarnaisType.control).foregroundStyle(HarnaisPalette.label)
                }
            } else if kind == .grafana {
                field(title: "Grafana URL") {
                    HarnaisField(text: $grafanaURL, placeholder: "https://grafana.example.com", width: nil)
                }
                field(title: "Service account token") {
                    HarnaisField(text: $grafanaToken, placeholder: "glsa_…", width: nil, secure: true)
                }
                if !runtime.grafanaBinaryInstalled {
                    HStack(spacing: 8) {
                        Text("Agents also need mcp-grafana on PATH, or this connection can't serve.")
                            .font(HarnaisType.status)
                            .foregroundStyle(HarnaisPalette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        HarnaisButton(title: "Install guide") {
                            NSWorkspace.shared.open(GrafanaMCPProcess.installURL)
                        }
                    }
                }
            } else {
                if kind != .custom, let note = OfficialOAuthClients.availabilityNote(for: kind), !useCustomApp {
                    Text(note).font(HarnaisType.status).foregroundStyle(HarnaisPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 10) {
                        if kind != .custom {
                            Toggle("Use my own OAuth app", isOn: $useCustomApp)
                            Text("Personal and Work are connection names. Both use the same Harnais app unless you choose a custom registration.")
                                .font(HarnaisType.status).foregroundStyle(HarnaisPalette.label)
                        }
                        if needsClientFields {
                            if kind != .custom {
                                Picker("Saved custom registration", selection: $registrationScope) {
                                    ForEach(OAuthRegistrationScope.allCases) { scope in Text(scope.label).tag(scope) }
                                }
                            }
                            field(title: kind == .custom ? "Client ID, if required" : "Client ID") {
                                HarnaisField(text: $clientId, placeholder: "OAuth client ID", width: nil)
                            }
                            field(title: "Client secret, if required") {
                                HarnaisField(text: $clientSecret, placeholder: "Client secret", width: nil, secure: true)
                            }
                            redirectRow
                            HarnaisButton(title: "Custom app setup…", prominence: .ghostMuted) { showAppSetup = true }
                        }
                    }.padding(.top, 8)
                }
            }
            if signingIn {
                Text("Waiting for the browser…")
                    .font(HarnaisType.status)
                    .foregroundStyle(HarnaisPalette.label)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(HarnaisType.status)
                    .foregroundStyle(HarnaisPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 0)
                HarnaisButton(title: "Cancel") { loginCancellation?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                HarnaisButton(
                    title: primaryTitle,
                    prominence: .primary,
                    enabled: canSubmit && !signingIn
                ) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(HarnaisSheetMetrics.padding)
        .frame(width: 520)
        .background(HarnaisPalette.background)
        .harnaisChrome(title: "Connect \(kind.displayName)", kind: .sheet)
        .toolbar(removing: .title)
        .onAppear(perform: preloadClient)
        .onChange(of: registrationScope) { _, scope in
            clientSecret = ""; preloadClient()
        }
        .sheet(isPresented: $showAppSetup, onDismiss: preloadClient) {
            IntegrationRegistrationSheet(kind: kind, runtime: runtime)
        }
    }

    private var needsClientFields: Bool {
        useCustomApp || kind == .custom
    }

    private var canSubmit: Bool {
        guard AccountNaming.isReadable(label) else { return false }
        if kind == .grafana {
            return !grafanaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !grafanaToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if kind == .custom { return (try? SharedMCPURL.parse(endpoint)) != nil }
        if !useCustomApp { return runtime.hasProductClient(kind) }
        if needsClientFields {
            if clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            if kind.clientSecretRequired, clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let saved = try? runtime.integrations.clients.record(for: kind, scope: registrationScope)
                return saved?.clientId == clientId.trimmingCharacters(in: .whitespacesAndNewlines)
                    && (saved?.isPublicClient == true || !(saved?.clientSecret ?? "").isEmpty)
            }
        }
        return true
    }

    private var primaryTitle: String {
        if signingIn { return "Waiting" }
        return kind == .grafana || kind == .excalidraw ? "Connect" : "Sign in"
    }

    private var redirectRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Redirect URI")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HarnaisPalette.label)
            HStack(spacing: 8) {
                Text(IntegrationOAuth.redirectURI)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(HarnaisPalette.text)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background(HarnaisPalette.fieldFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(HarnaisPalette.input, lineWidth: 1)
                    }
                HarnaisIconButton(systemName: "square.on.square", accessibilityLabel: "Copy redirect URI") {
                    HarnaisPasteboard.copy(IntegrationOAuth.redirectURI)
                }
            }
        }
    }

    private func field<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HarnaisPalette.label)
            content()
        }
    }

    private func preloadClient() {
        clientId = (try? runtime.integrations.clients.record(for: kind, scope: registrationScope))?.clientId ?? ""

    }

    private func submit() {
        errorMessage = nil
        if kind == .grafana {
            do {
                let connection = try runtime.integrations.connectGrafana(
                    label: label,
                    url: grafanaURL,
                    token: grafanaToken,
                    accounts: runtime.accounts
                )
                runtime.finishConnection(connection)
                dismiss()
            } catch {
                runtime.reload()
                errorMessage = error.localizedDescription
            }
            return
        }
        signingIn = true
        let kind = self.kind
        let label = self.label
        let custom = useCustomApp || kind == .custom
        let clientId = custom ? self.clientId : ""
        let clientSecret = custom ? self.clientSecret : ""
        let endpoint = self.endpoint
        let localCanvas = self.localCanvas
        let registrationScope = self.registrationScope
        let cancellation = OAuthCancellation()
        loginCancellation = cancellation
        var service = runtime.integrations
        service.oauth.cancellation = cancellation
        let accounts = runtime.accounts
        let authorizedService = service
        Task.detached {
            do {
                let connection = try kind == .aikido || kind == .excalidraw
                    ? authorizedService.connectVendor(kind: kind, label: label, localCanvas: localCanvas, accounts: accounts, openURL: BrowserOpener.open)
                    : authorizedService.connectOAuth(
                    kind: kind,
                    label: label,
                    clientId: clientId.isEmpty ? nil : clientId,
                    clientSecret: clientSecret.isEmpty ? nil : clientSecret,
                    endpoint: endpoint.isEmpty ? nil : endpoint,
                    registrationScope: custom ? registrationScope : nil,
                    mode: custom ? .custom : .harnais,
                    accounts: accounts,
                    openURL: BrowserOpener.open
                )
                await MainActor.run {
                    runtime.finishConnection(connection)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    signingIn = false
                    runtime.reload()
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct IntegrationReconnectSheet: View {
    let connection: IntegrationConnection
    @Bindable var runtime: HarnaisRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var signingIn = false
    @State private var loginCancellation: OAuthCancellation?

    var body: some View {
        VStack(alignment: .leading, spacing: HarnaisSheetMetrics.spacing) {
            HStack(spacing: 8) {
                IntegrationMark(kind: connection.kind, size: 22)
                Text("Sign in to \(connection.kind.displayName)")
                    .font(HarnaisSheetMetrics.titleFont)
                    .foregroundStyle(HarnaisPalette.text)
            }
            Text("A browser window will open. Finish \(connection.kind.displayName) sign-in, then this sheet closes.")
                .font(HarnaisSheetMetrics.subtitleFont)
                .foregroundStyle(HarnaisPalette.label)
            if signingIn {
                Text("Waiting for the browser…")
                    .font(HarnaisType.status)
                    .foregroundStyle(HarnaisPalette.label)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(HarnaisType.status)
                    .foregroundStyle(HarnaisPalette.warning)
            }
            HStack {
                Spacer(minLength: 0)
                HarnaisButton(title: "Cancel") { loginCancellation?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                HarnaisButton(title: signingIn ? "Waiting" : "Sign in", prominence: .primary, enabled: !signingIn) {
                    start()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(HarnaisSheetMetrics.padding)
        .frame(width: 480)
        .background(HarnaisPalette.background)
        .harnaisChrome(title: "Sign in", kind: .sheet)
        .toolbar(removing: .title)
        .onAppear(perform: start)
    }

    private func start() {
        guard !signingIn else { return }
        signingIn = true
        let connection = self.connection
        let cancellation = OAuthCancellation()
        loginCancellation = cancellation
        var service = runtime.integrations
        service.oauth.cancellation = cancellation
        let accounts = runtime.accounts
        let authorizedService = service
        Task.detached {
            do {
                let updated = try authorizedService.reconnectOAuth(connection, accounts: accounts, openURL: BrowserOpener.open)
                await MainActor.run {
                    runtime.finishConnection(updated)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    signingIn = false
                    runtime.reload()
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
