import Domain
import Foundation
import Infrastructure

@main
struct HarnaisCLI {
    static func main() {
        // Harnesses spawn `harnais mcp serve` and surface stderr on failure:
        // never crash with a Swift fatal — print one clean line instead.
        do {
            try run()
        } catch {
            fputs("harnais: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            print(help)
            return
        }
        let rest = Array(args.dropFirst())
        let service = AccountService()
        let integrations = IntegrationService()
        switch command {
        case "whatsapp-document":
            guard rest.count == 2 else { throw HarnaisError.processFailed("Expected a downloaded document path and MIME type.") }
            let value = try WhatsAppBridge().readDocument(path: rest[0], mime: rest[1])
            print(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        case "list":
            for account in try service.registry.accounts() {
                let email = account.accountEmail ?? "unsigned"
                print("\(account.provider.rawValue)\t\(account.label)\t\(account.slug)\t\(email)\t\(account.homePath)")
            }
        case "register-oauth":
            guard rest.first == "atlassian" else { throw HarnaisError.oauthFailed("Usage: harnais register-oauth atlassian") }
            let scope = rest.count > 1 ? OAuthRegistrationScope(rawValue: rest[1]) : .personal
            guard let scope else { throw HarnaisError.oauthFailed("Choose personal or work.") }
            _ = try integrations.registerOAuthClient(.atlassian, scope: scope)
            print("Atlassian Harnais client registration saved. Service authorization is still required.")
        case "connections":
            for connection in try integrations.connections() {
                let status = connection.isSignedIn ? (connection.accountLabel ?? "signed-in") : "unsigned"
                print("\(connection.kind.rawValue)\t\(connection.label)\t\(connection.mcpName)\t\(status)")
            }
        case "skills":
            let accounts = try service.registry.accounts()
            let inventory = ConnectionInventoryReader().scan(accounts: accounts, connections: try integrations.connections())
            let skills = SkillInventoryReader().scan(accounts: accounts, connections: inventory)
            let output: [[String: Any]] = skills.entries.map { entry in
                ["name": entry.name, "accountID": entry.account.id.uuidString, "provider": entry.account.provider.rawValue,
                 "label": entry.account.label, "origin": entry.origin.rawValue, "state": entry.state,
                 "plugin": entry.plugin ?? "", "path": entry.path, "warnings": entry.warnings]
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        case "inventory":
            let accounts = try service.registry.accounts()
            let inventory = ConnectionInventoryReader().scan(accounts: accounts, connections: try integrations.connections())
            let output: [[String: Any]] = inventory.map { group in
                let account = accounts.first { $0.id == group.accountID }!
                return ["accountID": account.id.uuidString, "provider": account.provider.rawValue,
                        "label": account.label, "warnings": group.warnings, "notes": group.notes,
                        "entries": group.entries.map { entry -> [String: Any] in
                            ["name": entry.name, "kind": entry.kind.rawValue, "origin": entry.origin.rawValue,
                             "source": entry.source, "scope": entry.scope, "state": entry.state,
                             "warnings": entry.warnings, "supportsLogin": entry.supportsLogin]
                        }]
            }
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        case "import-defaults":
            let imported = try service.importDefaults()
            print("imported \(imported.count)")
        case "import-mcp":
            let created = try integrations.importFromCursor(accounts: service.registry.accounts())
            print("imported \(created.count)")
        case "add":
            try add(rest, service: service)
        case "connect":
            try connect(rest, accounts: service.registry.accounts(), integrations: integrations)
        case "reconnect":
            guard let name = rest.first,
                  let connection = try integrations.connections().first(where: { $0.mcpName == name }) else {
                throw HarnaisError.mcpServeUnknown(rest.first ?? "missing")
            }
            let updated = try connection.kind == .whatsapp
                ? integrations.connectWhatsApp(label: connection.label, accounts: service.registry.accounts())
                : integrations.reconnectOAuth(connection, accounts: service.registry.accounts(), openURL: BrowserOpener.open)
            print("reconnected \(updated.mcpName)")
        case "disconnect":
            guard let name = rest.first else { throw HarnaisError.mcpServeUnknown("missing") }
            let accounts = try service.registry.accounts()
            guard let connection = try integrations.connections().first(where: {
                $0.mcpName == name || $0.slug == name || $0.kind.rawValue == name
            }) else {
                throw HarnaisError.mcpServeUnknown(name)
            }
            try integrations.disconnect(connection, accounts: accounts)
            print("disconnected \(connection.mcpName)")
        case "wrappers":
            try WrapperGenerator().refreshAll(accounts: service.registry.accounts())
            print(AppIdentity.current.binDirectory.path)
        case "path":
            try PathHelper().install()
            print("PATH includes \(AppIdentity.current.binDirectory.path)")
        case "quotas":
            let feed = QuotaAggregator().refresh(accounts: try service.registry.accounts())
            if rest.contains("--json") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                print(String(data: try encoder.encode(feed), encoding: .utf8) ?? "{}")
            } else {
                print("captured \(feed.accounts.count) accounts")
            }
        case "t3-export":
            let exporter = T3Exporter()
            for account in try service.registry.accounts() {
                print(try exporter.snippetJSON(for: account))
            }
        case "t3-apply":
            try T3Exporter().apply(accounts: service.registry.accounts())
            print("merged providerInstances")
        case "iles-extension":
            let urls = try IlesExtensionInstaller().install()
            for url in urls { print(url.path) }
        case "mcp":
            try MCPCommand.run(rest, service: integrations)
        case "help", "--help", "-h":
            print(help)
        default:
            fputs("unknown command \(command)\n", stderr)
            print(help)
            Foundation.exit(2)
        }
    }

    static func add(_ args: [String], service: AccountService) throws {
        guard let providerName = args.first, let provider = ProviderKind(rawValue: providerName) else {
            throw HarnaisError.invalidLabel
        }
        var label = "Personal"
        var importDefault = false
        var shadow = false
        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--label", index + 1 < args.count {
                label = args[index + 1]
                index += 2
            } else if arg == "--import-default" {
                importDefault = true
                index += 1
            } else if arg == "--t3-shadow" {
                shadow = true
                index += 1
            } else {
                index += 1
            }
        }
        let account = try service.create(
            provider: provider,
            label: label,
            importDefault: importDefault,
            codexMode: shadow ? .t3Shadow : .isolated
        )
        print(account.id.uuidString)
        print(account.homePath)
    }

    static func connect(
        _ args: [String],
        accounts: [Account],
        integrations: IntegrationService
    ) throws {
        guard let kindName = args.first, let kind = IntegrationKind(rawValue: kindName) else {
            throw HarnaisError.invalidLabel
        }
        var label = IntegrationNaming.suggestedLabel(for: kind, existing: try integrations.connections())
        var url = ""
        var token = ""
        var tokenFile = ""
        var clientId: String?
        var clientSecret: String?
        var registrationScope: OAuthRegistrationScope? = nil
        var readOnlyAccountIDs: [UUID] = []
        var index = 1
        while index < args.count {
            let arg = args[index]
            func take() -> String? {
                guard index + 1 < args.count else { return nil }
                index += 1
                return args[index]
            }
            if arg == "--label", let value = take() {
                label = value
            } else if arg == "--url", let value = take() {
                url = value
            } else if arg == "--token", let value = take() {
                token = value
            } else if arg == "--token-file", let value = take() {
                tokenFile = value
            } else if arg == "--read-only-account", let value = take() {
                guard let id = UUID(uuidString: value), accounts.contains(where: { $0.id == id }) else {
                    throw HarnaisError.processFailed("Unknown read-only account ID.")
                }
                readOnlyAccountIDs.append(id)
            } else if arg == "--registration", let value = take() {
                guard let scope = OAuthRegistrationScope(rawValue: value) else { throw HarnaisError.oauthFailed("Choose personal or work for --registration.") }
                registrationScope = scope
            } else if arg == "--client-id", let value = take() {
                clientId = value
            } else if arg == "--client-secret", let value = take() {
                clientSecret = value
            }
            index += 1
        }
        if kind == .aikido || kind == .excalidraw {
            let connection = try integrations.connectVendor(kind: kind, label: label, localCanvas: args.contains("--local-canvas"), accounts: accounts, openURL: BrowserOpener.open)
            print(connection.mcpName)
            return
        }
        if kind == .whatsapp {
            let connection = try integrations.connectWhatsApp(label: label, accounts: accounts)
            print("connected \(connection.mcpName)")
            return
        }
        if kind == .grafana {
            if token.isEmpty, !tokenFile.isEmpty {
                token = try String(contentsOfFile: (tokenFile as NSString).expandingTildeInPath, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let connection = try integrations.connectGrafana(
                label: label,
                url: url,
                token: token,
                readOnlyAccountIDs: readOnlyAccountIDs,
                accounts: accounts
            )
            print(connection.mcpName)
            return
        }
        let connection = try integrations.connectOAuth(
            kind: kind,
            label: label,
            clientId: clientId,
            clientSecret: clientSecret,
            endpoint: kind == .custom ? url : nil,
            registrationScope: registrationScope,
            mode: registrationScope != nil || clientId != nil || clientSecret != nil ? .custom : .harnais,
            accounts: accounts,
            openURL: BrowserOpener.open
        )
        print(connection.mcpName)
    }

    static var help: String {
        """
        harnais list
        harnais connections
        harnais inventory
        harnais import-defaults
        harnais register-oauth atlassian [personal|work]
        harnais import-mcp
        harnais add claude|codex|cursor|opencode --label Work [--import-default] [--t3-shadow]
        harnais connect google-drive|gmail|outlook|slack|atlassian|grafana|aikido|excalidraw|whatsapp|custom --label Work
        harnais disconnect <mcp-name>
        harnais reconnect <mcp-name>
        harnais wrappers
        harnais path
        harnais quotas
        harnais t3-export
        harnais t3-apply
        harnais iles-extension
        harnais mcp apply
        harnais mcp serve <name>
        """
    }
}
