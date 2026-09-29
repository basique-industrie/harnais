import Domain
import Foundation

public struct IntegrationService: Sendable {
    public var identity: AppIdentity
    public var registry: IntegrationRegistry
    public var credentials: IntegrationCredentialStore
    public var clients: OAuthClientsStore
    public var applyStore: MCPApplyStore
    public var exporter: HarnessMCPExporter
    public var oauth: MCPOAuthClient
    public var installer: HarnaisCLIInstaller

    public init(identity: AppIdentity = .current) {
        self.identity = identity
        self.registry = IntegrationRegistry(identity: identity)
        self.credentials = IntegrationCredentialStore(identity: identity)
        self.clients = OAuthClientsStore(identity: identity)
        self.applyStore = MCPApplyStore(identity: identity)
        self.exporter = HarnessMCPExporter(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            identity: identity
        )
        self.oauth = MCPOAuthClient()
        self.installer = HarnaisCLIInstaller(identity: identity)
    }

    public init(
        identity: AppIdentity,
        homeDirectory: URL
    ) {
        self.identity = identity
        self.registry = IntegrationRegistry(identity: identity)
        self.credentials = IntegrationCredentialStore(identity: identity)
        self.clients = OAuthClientsStore(identity: identity)
        self.applyStore = MCPApplyStore(identity: identity)
        self.exporter = HarnessMCPExporter(homeDirectory: homeDirectory, identity: identity)
        self.oauth = MCPOAuthClient()
        self.installer = HarnaisCLIInstaller(identity: identity)
    }

    public func connections() throws -> [IntegrationConnection] {
        try registry.connections()
    }

    public func connectWhatsApp(label: String, accounts: [Account]) throws -> IntegrationConnection {
        let status = try WhatsAppBridge(identity: identity).status()
        guard status.connected, let account = status.account else {
            throw HarnaisError.processFailed("Scan the WhatsApp QR code with your phone first.")
        }
        var connection = try registry.connections().first { $0.kind == .whatsapp }
            ?? makeConnection(kind: .whatsapp, label: Self.requireLabel(label), preferredMcpName: nil, grafanaURL: nil)
        connection.lastLoginAt = Date()
        connection.accountLabel = account.components(separatedBy: "@").first.map { "+" + $0 }
        if try registry.connections().contains(where: { $0.id == connection.id }) { try registry.update(connection) }
        else { try registry.add(connection) }
        do { _ = try apply(accounts: accounts) }
        catch { throw HarnaisError.processFailed("WhatsApp is linked and saved. Sync needs attention: \(error.localizedDescription)") }
        return connection
    }

    public func connectVendor(kind: IntegrationKind, label: String, localCanvas: Bool = false,
                              accounts: [Account], openURL: (URL) throws -> Void) throws -> IntegrationConnection {
        guard kind == .aikido || kind == .excalidraw else { throw HarnaisError.processFailed("Unsupported vendor connection.") }
        if kind == .aikido {
            guard try !registry.connections().contains(where: { $0.kind == .aikido }) else {
                throw HarnaisError.processFailed("Aikido uses one macOS Keychain login. Manage the existing shared connection.")
            }
            try VendorMCPProcess.loginAikido(cancellation: oauth.cancellation, openURL: openURL)
        }
        var connection = try makeConnection(kind: kind, label: Self.requireLabel(label), preferredMcpName: nil, grafanaURL: nil)
        connection.localCanvas = kind == .excalidraw && localCanvas ? true : nil
        connection.lastLoginAt = Date()
        connection.accountLabel = kind == .aikido ? "Aikido macOS Keychain" : localCanvas ? "Local canvas" : "Official remote server"
        try registry.add(connection)
        _ = try apply(accounts: accounts)
        return connection
    }

    public func connectGrafana(
        label: String,
        url: String,
        token: String,
        mcpName: String? = nil,
        readOnlyAccountIDs: [UUID] = [],
        accounts: [Account]
    ) throws -> IntegrationConnection {
        let trimmedLabel = try Self.requireLabel(label)
        let normalized = try GrafanaURL.normalize(url)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw HarnaisError.oauthFailed("Grafana needs a service-account token.")
        }
        var connection = try makeConnection(
            kind: .grafana,
            label: trimmedLabel,
            preferredMcpName: mcpName,
            grafanaURL: normalized
        )
        connection.readOnlyAccountIDs = readOnlyAccountIDs.isEmpty ? nil : readOnlyAccountIDs
        try credentials.save(.grafana(GrafanaTokenSet(url: normalized, token: trimmedToken)), for: connection)
        connection.lastLoginAt = Date()
        connection.accountLabel = normalized
        try registry.add(connection)
        do { _ = try apply(accounts: accounts) }
        catch { throw HarnaisError.processFailed("Connection saved in Shared. Sync needs attention: \(error.localizedDescription)") }
        return connection
    }

    public func connectOAuth(
        kind: IntegrationKind,
        label: String,
        clientId: String?,
        clientSecret: String?,
        endpoint: String? = nil,
        registrationScope: OAuthRegistrationScope? = nil,
        mode: OAuthConnectionMode = .harnais,
        accounts: [Account],
        openURL: (URL) throws -> Void
    ) throws -> IntegrationConnection {
        guard kind.authKind == .oauth else {
            throw HarnaisError.oauthFailed("\(kind.displayName) is not an OAuth connection.")
        }
        let trimmedLabel = try Self.requireLabel(label)
        let customEndpoint = kind == .custom ? try SharedMCPURL.parse(endpoint ?? "") : nil
        let usesOfficialApp = mode == .harnais && kind != .custom
        var record = try resolveOAuthClient(kind: kind, mode: mode, registrationScope: registrationScope)
        let trimmedId = clientId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        if usesOfficialApp && (!(trimmedId ?? "").isEmpty || !(trimmedSecret ?? "").isEmpty) {
            throw HarnaisError.oauthFailed("Use Advanced custom app settings to supply your own OAuth client.")
        }
        if !usesOfficialApp, let trimmedId, !trimmedId.isEmpty {
            record = OAuthClientRecord(
                clientId: trimmedId,
                clientSecret: (trimmedSecret?.isEmpty == false) ? trimmedSecret : (record?.clientId == trimmedId ? record?.clientSecret : nil),
                isPublicClient: record?.clientId == trimmedId ? record?.isPublicClient : nil,
                scopes: record?.clientId == trimmedId ? record?.scopes : nil
            )
            if kind != .custom { try clients.upsert(kind: kind, scope: registrationScope, record: record!) }
        }
        if kind.needsRegisteredOAuthClient, record == nil, kind != .atlassian {
            throw HarnaisError.oauthClientRequired(kind.displayName)
        }
        if kind.clientSecretRequired, record?.isPublicClient != true, (record?.clientSecret ?? "").isEmpty {
            throw HarnaisError.oauthClientRequired(kind.displayName)
        }
        let tokens = try oauth.authorize(kind: kind, endpoint: customEndpoint, client: record, openURL: openURL)
        var connection = try makeConnection(kind: kind, label: trimmedLabel, preferredMcpName: nil, grafanaURL: nil)
        connection.endpointURL = customEndpoint?.absoluteString
        try credentials.save(.oauth(tokens), for: connection)
        connection.lastLoginAt = Date()
        connection.accountLabel = IntegrationAccountLabel.make(tokens: tokens)
        try registry.add(connection)
        if kind == .custom || usesOfficialApp {
            // Official/native registrations stay separate from custom app defaults.
        } else if let record, record.clientId.isEmpty == false {
            try clients.upsert(kind: kind, scope: registrationScope, record: record)
        } else if let clientId = tokens.clientId, !clientId.isEmpty {
            try clients.upsert(
                kind: kind, scope: registrationScope,
                record: OAuthClientRecord(clientId: clientId, clientSecret: tokens.clientSecret)
            )
        }
        _ = try apply(accounts: accounts)
        return connection
    }

    public func reconnectOAuth(
        _ connection: IntegrationConnection,
        accounts: [Account],
        openURL: (URL) throws -> Void
    ) throws -> IntegrationConnection {
        if connection.kind == .aikido {
            try VendorMCPProcess.loginAikido(cancellation: oauth.cancellation, openURL: openURL)
            var updated = connection
            updated.lastLoginAt = Date()
            try registry.update(updated)
            _ = try apply(accounts: accounts)
            return updated
        }
        let record = try reconnectClient(for: connection)
        let tokens = try oauth.authorize(kind: connection.kind, endpoint: connection.mcpURL, client: record, openURL: openURL)
        try credentials.save(.oauth(tokens), for: connection)
        var updated = connection
        updated.lastLoginAt = Date()
        updated.accountLabel = IntegrationAccountLabel.make(tokens: tokens) ?? connection.accountLabel
        try registry.update(updated)
        _ = try apply(accounts: accounts)
        return updated
    }

    /// Keep the original app identity when renewing consent, including native
    /// PKCE settings and any deliberately configured custom scope set.
    public func reconnectClient(for connection: IntegrationConnection) throws -> OAuthClientRecord? {
        let prior = try credentials.load(for: connection).oauth
        guard let clientID = prior?.clientId else {
            return connection.kind == .custom ? nil : try clients.record(for: connection.kind)
        }
        let saved = try clients.load().clients
        let keys = [connection.kind.rawValue, "\(connection.kind.rawValue):personal", "\(connection.kind.rawValue):work"]
        let matching = keys.compactMap { saved[$0] }.first { $0.clientId == clientID }
        return OAuthClientRecord(
            clientId: clientID,
            clientSecret: matching?.clientSecret ?? prior?.clientSecret,
            isPublicClient: matching?.isPublicClient,
            scopes: matching?.scopes ?? prior?.scope?.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        )
    }

    public func disconnect(_ connection: IntegrationConnection, accounts: [Account]) throws {
        if connection.kind == .whatsapp { try WhatsAppBridge(identity: identity).unlink() }
        try registry.remove(id: connection.id)
        credentials.remove(for: connection)
        _ = try apply(accounts: accounts)
    }

    public func updateSettings(_ connection: IntegrationConnection, label: String, mcpName: String,
                               endpoint: String, token: String, clientID: String, clientSecret: String,
                               shared: Bool, excludedAccountIDs: [UUID]? = nil) throws -> IntegrationConnection {
        var updated = connection
        updated.label = try Self.requireLabel(label)
        let name = mcpName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw HarnaisError.processFailed("Use letters, numbers, hyphens, or underscores for the server name.")
        }
        guard try !registry.connections().contains(where: { $0.id != connection.id && $0.mcpName == name }) else {
            throw HarnaisError.duplicateIntegration(name)
        }
        updated.mcpName = name
        updated.isExcludedFromApply = shared ? nil : true
        if let excludedAccountIDs { updated.excludedAccountIDs = excludedAccountIDs.isEmpty ? nil : excludedAccountIDs }
        if connection.kind == .grafana {
            let url = try GrafanaURL.normalize(endpoint)
            let prior = try? credentials.load(for: connection).grafana
            let secret = token.isEmpty ? prior?.token ?? "" : token
            guard !secret.isEmpty else { throw HarnaisError.processFailed("Enter a service-account token.") }
            try credentials.save(.grafana(GrafanaTokenSet(url: url, token: secret)), for: updated)
            updated.grafanaURL = url
            updated.accountLabel = url
            updated.lastLoginAt = Date()
        } else if connection.kind.authKind == .oauth {
            let priorClient = try reconnectClient(for: connection)
            if connection.kind == .custom { updated.endpointURL = try SharedMCPURL.parse(endpoint).absoluteString }
            let tokens = try credentials.updateOAuth(for: connection) { tokens in
            let changedEndpoint = updated.mcpURL != connection.mcpURL
            let changedClient = !clientID.isEmpty && clientID != tokens.clientId
            if changedEndpoint || changedClient || !clientSecret.isEmpty {
                tokens.accessToken = ""
                tokens.refreshToken = nil
                tokens.expiresAt = nil
                updated.lastLoginAt = nil
                updated.accountLabel = nil
            }
            if changedClient { tokens.clientSecret = nil }
            if changedEndpoint {
                tokens = OAuthTokenSet(accessToken: "")
            }
            if !clientID.isEmpty { tokens.clientId = clientID }
            if !clientSecret.isEmpty { tokens.clientSecret = clientSecret }
            // Stable APIs do not need a new resource parameter. Preserve any existing
            // audience so authorizedTokens can validate or narrowly migrate it.
            if ![.googleDrive, .gmail, .outlook].contains(connection.kind) || connection.endpointURL != nil {
                if changedEndpoint || tokens.resource == nil { tokens.resource = updated.mcpURL.absoluteString }
            }
            }
            if connection.kind != .custom, let id = tokens.clientId, !id.isEmpty {
                try clients.upsert(kind: connection.kind, record: OAuthClientRecord(clientId: id, clientSecret: tokens.clientSecret,
                    isPublicClient: priorClient?.clientId == id ? priorClient?.isPublicClient : nil,
                    scopes: priorClient?.clientId == id ? priorClient?.scopes : nil))
            }
        }
        try registry.update(updated)
        return updated
    }

    public func apply(accounts: [Account]) throws -> MCPApplyReport {
        let commandPath = try installer.install()
        let connections = try registry.connections()
        let previous = (try? applyStore.load().mcpNames) ?? []
        let report = try exporter.apply(
            connections: connections,
            accounts: accounts,
            commandPath: commandPath,
            previousNames: previous
        )
        try applyStore.save(
            MCPApplyState(mcpNames: report.mcpNames, commandPath: commandPath, appliedAt: Date(), files: report.files)
        )
        return report
    }

    public func serve(mcpName: String, readOnly: Bool = false) throws {
        guard let connection = try registry.connection(mcpName: mcpName) else {
            throw HarnaisError.mcpServeUnknown(mcpName)
        }
        switch connection.kind {
        case .whatsapp:
            try WhatsAppBridge(identity: identity).run()
        case .aikido:
            try VendorMCPProcess.run(kind: .aikido)
        case .excalidraw:
            if connection.localCanvas == true { try VendorMCPProcess.run(kind: .excalidraw) }
            else { try MCPHTTPProxy(oauth: oauth, credentials: credentials).run(connection: connection) }
        case .grafana:
            try GrafanaMCPProcess().run(connection: connection, credentials: credentials, readOnly: readOnly)
        case .outlook, .gmail:
            try MailMCPServer(service: connection.kind, oauth: oauth, credentials: credentials).run(connection: connection)
        case .googleDrive:
            try DriveMCPServer(oauth: oauth, credentials: credentials).run(connection: connection)
        case .slack, .atlassian, .custom:
            try MCPHTTPProxy(oauth: oauth, credentials: credentials).run(connection: connection)
        }
    }

    public func importFromCursor(accounts: [Account]) throws -> [IntegrationConnection] {
        let importer = CursorMCPImporter(homeDirectory: exporter.homeDirectory)
        var created: [IntegrationConnection] = []
        // NOTE: Cursor's Slack CLIENT_ID is intentionally NOT imported. It
        // belongs to Cursor's Slack app, which does not list Harnais's
        // redirect URI — reusing it fails with "redirect_uri did not match
        // any configured URIs". Slack needs the user's own app (see
        // IntegrationKind.slack oauthSetupHint).
        let existing = try registry.connections()
        let existingNames = Set(existing.map(\.mcpName))
        for item in importer.grafanaImports() where !existingNames.contains(item.mcpName) && !existingNames.contains("harnais-" + item.mcpName) {
            let connection = try connectGrafana(
                label: item.label,
                url: item.url,
                token: item.token,
                mcpName: "harnais-" + item.mcpName,
                accounts: accounts
            )
            created.append(connection)
        }
        return created
    }

    public func saveOAuthClientRegistration(kind: IntegrationKind, scope: OAuthRegistrationScope, clientID: String, clientSecret: String) throws {
        guard kind.needsRegisteredOAuthClient else { throw HarnaisError.oauthFailed("Use this service's connection setup.") }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let entered = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let prior = try clients.record(for: kind, scope: scope)
        let secret = entered.isEmpty && prior?.clientId == id ? prior?.clientSecret : entered
        let sameApp = prior?.clientId == id
        guard !id.isEmpty, !kind.clientSecretRequired || (sameApp && prior?.isPublicClient == true) || !(secret ?? "").isEmpty else {
            throw HarnaisError.oauthFailed("Enter the client ID and secret issued to the Harnais app.")
        }
        try clients.upsert(kind: kind, scope: scope, record: OAuthClientRecord(
            clientId: id, clientSecret: (secret?.isEmpty == false) ? secret : nil,
            isPublicClient: sameApp ? prior?.isPublicClient : nil,
            scopes: sameApp ? prior?.scopes : nil
        ))
    }

    public func registerOAuthClient(_ kind: IntegrationKind, scope: OAuthRegistrationScope = .personal) throws -> OAuthClientRecord {
        guard kind == .atlassian else { throw HarnaisError.oauthFailed("Register this app in its service console.") }
        if let existing = try clients.record(for: kind, scope: scope), !existing.clientId.isEmpty { return existing }
        let record = try oauth.registerClient(kind: kind, appName: scope.appName)
        try clients.upsert(kind: kind, scope: scope, record: record)
        return record
    }

    public func resolveOAuthClient(kind: IntegrationKind, mode: OAuthConnectionMode,
                                   registrationScope: OAuthRegistrationScope? = nil) throws -> OAuthClientRecord? {
        if kind == .custom { return nil }
        if mode == .custom { return try clients.record(for: kind, scope: registrationScope) }
        let record = try OfficialOAuthClients.record(for: kind)
        if kind.needsRegisteredOAuthClient && record == nil {
            throw HarnaisError.oauthFailed("Harnais's \(kind.displayName) app is not available in this build. Existing connections still work. Advanced settings can use your own app.")
        }
        return record
    }

    public func hasProductClient(_ kind: IntegrationKind) throws -> Bool {
        if !kind.needsRegisteredOAuthClient { return true }
        return try OfficialOAuthClients.record(for: kind) != nil
    }

    private func makeConnection(
        kind: IntegrationKind,
        label: String,
        preferredMcpName: String?,
        grafanaURL: String?
    ) throws -> IntegrationConnection {
        let slug = Slug.make(from: label)
        let existing = try registry.connections()
        if existing.contains(where: { $0.kind == kind && $0.slug == slug }) {
            throw HarnaisError.duplicateIntegration(label)
        }
        let mcpName = IntegrationNaming.assignMcpName(
            kind: kind,
            slug: slug,
            existing: existing,
            preferred: preferredMcpName ?? "harnais-\(kind == .custom ? slug : kind.rawValue + "-" + slug)"
        )
        return IntegrationConnection(
            kind: kind,
            label: label,
            slug: slug,
            mcpName: mcpName,
            grafanaURL: grafanaURL
        )
    }

    private static func requireLabel(_ label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HarnaisError.invalidLabel }
        return trimmed
    }
}

public enum BrowserOpener {
    public static func open(_ url: URL) throws {
        _ = try ProcessRunner().run(
            executable: "/usr/bin/open",
            arguments: [url.absoluteString],
            environment: ProcessInfo.processInfo.environment,
            timeout: 8
        )
    }
}

public enum MCPCommand {
    public static func exitIfInvoked(arguments: [String] = CommandLine.arguments) {
        let args = Array(arguments.dropFirst())
        guard args.first == "mcp" else { return }
        do {
            try run(Array(args.dropFirst()))
            Foundation.exit(0)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    public static func run(_ args: [String], service: IntegrationService = IntegrationService()) throws {
        guard let action = args.first else {
            throw HarnaisError.processFailed("harnais mcp serve <name> | harnais mcp apply")
        }
        let rest = Array(args.dropFirst())
        switch action {
        case "serve":
            guard let name = rest.first else {
                throw HarnaisError.mcpServeUnknown("missing")
            }
            guard rest.dropFirst().allSatisfy({ $0 == "--read-only" }) else {
                throw HarnaisError.processFailed("Unknown MCP serve option.")
            }
            try service.serve(mcpName: name, readOnly: rest.contains("--read-only"))
        case "apply":
            let accounts = (try? AccountRegistry().accounts()) ?? []
            let report = try service.apply(accounts: accounts)
            print(report.summary)
        default:
            throw HarnaisError.processFailed("unknown mcp command \(action)")
        }
    }
}
