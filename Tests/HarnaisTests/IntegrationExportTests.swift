import AppKit
import Domain
import Foundation
import Infrastructure

enum IntegrationExportTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        func expectEqual<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            expect(got == want, "\(message) (got \(got), want \(want))")
        }

        expectEqual(IntegrationKind.googleDrive.canonicalMcpName, "google-drive", "Drive MCP name")
        expectEqual(
            IntegrationNaming.assignMcpName(kind: .grafana, slug: "prod", existing: []),
            "grafana",
            "first Grafana connection uses the canonical name"
        )
        let grafanaDefault = IntegrationConnection(kind: .grafana, label: "Default", slug: "default", mcpName: "grafana")
        expectEqual(
            IntegrationNaming.assignMcpName(kind: .grafana, slug: "prod", existing: [grafanaDefault]),
            "grafana-prod",
            "second Grafana connection keeps the slug"
        )
        expectEqual(
            IntegrationNaming.humanizeMcpName("grafana-prod", kind: .grafana),
            "Prod",
            "Grafana mcp name becomes a label"
        )

        let driveURLs = MCPOAuthClient().wellKnownProtectedResourceURLs(
            for: URL(string: "https://drivemcp.googleapis.com/mcp/v1")!
        )
        expect(
            driveURLs.contains { $0.absoluteString == "https://drivemcp.googleapis.com/.well-known/oauth-protected-resource/mcp/v1" },
            "Drive protected-resource metadata uses the path suffix"
        )

        let query = OAuthCallbackServer.queryItems(from: "/callback?code=abc%2Fdef&state=one+two")
        expectEqual(query["code"], "abc/def", "callback decodes the OAuth code")
        expectEqual(query["state"], "one two", "callback decodes state spaces")

        let harnessRoot = root.appendingPathComponent("harness-home")
        let dataDir = root.appendingPathComponent("harnais-data")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let identity = AppIdentity(bundleIdentifier: "com.jean.harnais.test", dataDirectory: dataDir)
        let integrations = IntegrationRegistry(identity: identity)
        let drive = IntegrationConnection(
            kind: .googleDrive,
            label: "Personal",
            slug: "personal",
            mcpName: "google-drive"
        )
        try integrations.add(drive)
        expectEqual(try integrations.connections().count, 1, "integration registry stores a connection")
        do {
            try integrations.add(drive)
            expect(false, "duplicate integration slug is rejected")
        } catch HarnaisError.duplicateIntegration {
            expect(true, "duplicate integration slug is rejected")
        }

        let secrets = IntegrationCredentialStore(identity: identity)
        let tokens = OAuthTokenSet(accessToken: "tok", refreshToken: "ref")
        try secrets.save(.oauth(tokens), for: drive)
        let loaded = try secrets.load(for: drive)
        expectEqual(loaded.oauth?.accessToken, "tok", "OAuth tokens round-trip")
        let credURL = identity.integrationCredentialsURL(kind: .googleDrive, slug: "personal")
        let mode = try FileManager.default.attributesOfItem(atPath: credURL.path)[.posixPermissions] as? NSNumber
        expectEqual((mode?.uint16Value ?? 0) & 0o777, 0o600, "integration credentials are owner-only")

        try FileManager.default.createDirectory(
            at: harnessRoot.appendingPathComponent(".cursor"),
            withIntermediateDirectories: true
        )
        let cursorMCP = harnessRoot.appendingPathComponent(".cursor/mcp.json")
        try Data(#"{ "mcpServers": { "excalidraw": { "command": "npx" } } }"#.utf8).write(to: cursorMCP)
        try FileManager.default.createDirectory(
            at: harnessRoot.appendingPathComponent(".codex"),
            withIntermediateDirectories: true
        )
        let codexConfig = harnessRoot.appendingPathComponent(".codex/config.toml")
        try Data("model = \"gpt-5\"\n".utf8).write(to: codexConfig)
        let extraCursor = Account(
            provider: .cursor,
            label: "Work",
            slug: "work",
            homePath: harnessRoot.appendingPathComponent("profiles/cursor/work").path
        )
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: extraCursor.homePath),
            withIntermediateDirectories: true
        )
        let exporter = HarnessMCPExporter(homeDirectory: harnessRoot, identity: identity)
        let report = try exporter.apply(
            connections: [drive],
            accounts: [extraCursor],
            commandPath: "/tmp/harnais",
            previousNames: ["stale-server"]
        )
        expect(report.mcpNames.contains("google-drive"), "apply reports the Drive MCP name")
        let cursorMCPJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: cursorMCP)) as? [String: Any]
        let servers = cursorMCPJSON?["mcpServers"] as? [String: Any]
        expect(servers?["excalidraw"] != nil, "apply keeps unrelated MCP servers")
        expect(servers?["stale-server"] == nil, "apply drops previously managed names")
        let driveServer = servers?["google-drive"] as? [String: Any]
        expectEqual(driveServer?["command"] as? String, "/tmp/harnais", "Cursor MCP command is the Harnais wrapper")
        let args = driveServer?["args"] as? [String]
        expectEqual(args ?? [], ["mcp", "serve", "google-drive"], "Cursor MCP args serve the connection")
        let extraMCP = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: extraCursor.homePath).appendingPathComponent("mcp.json"))
        ) as? [String: Any]
        expect((extraMCP?["mcpServers"] as? [String: Any])?["google-drive"] != nil, "isolated Cursor homes get MCP too")
        let toml = try String(contentsOf: codexConfig, encoding: .utf8)
        expect(toml.contains("BEGIN HARNAIS MCP"), "Codex config gets a Harnais block")
        expect(toml.contains("[mcp_servers.\"google-drive\"]"), "Codex quotes hyphenated MCP names")
        expect(toml.contains("model = \"gpt-5\""), "Codex apply keeps existing TOML")

        let importMCP = root.appendingPathComponent("import-mcp.json")
        let tokenFile = root.appendingPathComponent("grafana.token")
        try Data("glsa-test-token\n".utf8).write(to: tokenFile)
        try Data("""
        {
          "mcpServers": {
            "grafana-prod": {
              "command": "mcp-grafana",
              "env": {
                "GRAFANA_URL": "https://grafana.example.com",
                "GRAFANA_TOKEN_FILE": "\(tokenFile.path)"
              }
            },
            "slack": {
              "url": "https://mcp.slack.com/mcp",
              "auth": { "CLIENT_ID": "123.456" }
            }
          }
        }
        """.utf8).write(to: importMCP)
        let importer = CursorMCPImporter(mcpURL: importMCP)
        expectEqual(importer.slackClientID(), "123.456", "importer reads the public Slack client id")
        expect(IntegrationKind.slack.clientSecretRequired, "Slack requires a client secret")
        expect(IntegrationKind.googleDrive.clientSecretRequired, "Drive requires a client secret")
        expect(IntegrationKind.atlassian.clientSecretRequired == false, "Atlassian registers itself")
        expectEqual(importer.grafanaImports().count, 1, "importer finds Grafana token files")
        expectEqual(importer.grafanaImports().first?.mcpName, "grafana-prod", "importer keeps the existing MCP name")
        expectEqual(importer.grafanaImports().first?.token, "glsa-test-token", "importer reads the token file")

        do {
            _ = try GrafanaURL.normalize("http://example.com")
            expect(false, "plain http Grafana URLs are rejected")
        } catch {
            expect(true, "plain http Grafana URLs are rejected")
        }
        expectEqual(
            try GrafanaURL.normalize("https://grafana.example.com/"),
            "https://grafana.example.com",
            "Grafana URLs drop a trailing slash"
        )

        let islandType = "time:Claude · work 5h"
        let islandConfig = IslandPublishConfig().settingHidden(type: islandType, hidden: true)
        expect(islandConfig.isHidden(type: islandType), "hidden island types stay hidden")
        expect(islandConfig.isHidden(type: "time:Claude · work 7d") == false, "other types stay visible")
        let islandShown = islandConfig.settingHidden(type: islandType, hidden: false)
        expect(islandShown.hiddenTypes.isEmpty, "unhiding removes the type")
        expect(
            IslandFeed.isStale(capturedAt: Date().addingTimeInterval(-300)),
            "feed older than 2x probe interval is stale"
        )
        expect(
            IslandFeed.isStale(capturedAt: Date()) == false,
            "fresh feed is not stale"
        )
        expect(IslandFeed.isStale(capturedAt: nil), "missing feed is stale")

        let excludedDrive = IntegrationConnection(
            kind: .googleDrive,
            label: "Work",
            slug: "work",
            mcpName: "google-drive",
            isExcludedFromApply: true
        )
        expect(excludedDrive.excludedFromApply, "excluded connections report excluded")
        let legacyDrive = IntegrationConnection(
            kind: .googleDrive,
            label: "Work",
            slug: "work",
            mcpName: "google-drive"
        )
        expect(legacyDrive.excludedFromApply == false, "registries without the flag default to included")
        let excludedReport = try exporter.apply(
            connections: [excludedDrive],
            accounts: [],
            commandPath: "/tmp/harnais",
            previousNames: ["google-drive"]
        )
        expect(excludedReport.mcpNames.isEmpty, "excluded connections are not reported as applied")
        let excludedAfter = try JSONSerialization.jsonObject(with: Data(contentsOf: cursorMCP)) as? [String: Any]
        expect(
            ((excludedAfter?["mcpServers"] as? [String: Any])?["google-drive"] == nil),
            "excluded connections are cleaned like removed names"
        )

        let breakdownRow = UsageBreakdownRow(
            id: "x",
            title: "Claude · Work",
            provider: .claude,
            cost: 1.5,
            tokens: 100
        )
        expectEqual(breakdownRow.title, "Claude · Work", "account breakdown rows carry display titles")

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let probeURL = repoRoot.appendingPathComponent("Sources/Infrastructure/Resources/iles-extension/probe.sh")
        expect(FileManager.default.fileExists(atPath: probeURL.path), "probe.sh ships in resources")
        let fakeHome = root.appendingPathComponent("fake-home")
        try FileManager.default.createDirectory(
            at: fakeHome.appendingPathComponent(".harnais"),
            withIntermediateDirectories: true
        )
        func writeHarnaisJSON(_ name: String, _ object: Any) throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            try data.write(to: fakeHome.appendingPathComponent(".harnais/\(name)"))
        }
        try writeHarnaisJSON("quotas.json", [
            "schemaVersion": 1,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "accounts": [[
                "id": "a1",
                "provider": "claude",
                "label": "Work",
                "quotas": [
                    ["type": "time:Claude · work 5h", "percentRemaining": 33],
                    ["type": "time:Claude · work 7d", "percentRemaining": 63],
                ],
            ]],
        ])
        try writeHarnaisJSON("islands.json", ["schemaVersion": 1, "hiddenTypes": ["time:Claude · work 7d"]])
        try writeHarnaisJSON("integrations.json", [
            "schemaVersion": 1,
            "connections": [
                ["id": UUID().uuidString, "kind": "google-drive", "label": "Work", "slug": "work",
                 "mcpName": "google-drive", "createdAt": "2026-09-18T12:00:00Z",
                 "lastLoginAt": "2026-09-18T12:00:00Z"],
                ["id": UUID().uuidString, "kind": "slack", "label": "Work", "slug": "work",
                 "mcpName": "slack", "createdAt": "2026-09-18T12:00:00Z",
                 "lastLoginAt": "2026-09-18T12:00:00Z", "isExcludedFromApply": true],
                ["id": UUID().uuidString, "kind": "grafana", "label": "Prod", "slug": "prod",
                 "mcpName": "grafana-prod", "createdAt": "2026-09-18T12:00:00Z"],
            ],
        ])
        try writeHarnaisJSON("mcp-apply.json", [
            "mcpNames": ["google-drive", "slack"],
            "commandPath": "/tmp/harnais",
            "appliedAt": "2026-09-18T12:00:00Z",
            "files": ["/tmp/x/mcp.json"],
        ])
        func runProbe(home: URL) throws -> [String: Any] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [probeURL.path]
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home.path
            process.environment = env
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            process.waitUntilExit()
            expect(process.terminationStatus == 0, "probe exits 0")
            return try JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile()) as? [String: Any] ?? [:]
        }
        let probe = try runProbe(home: fakeHome)
        let probeQuotas = probe["quotas"] as? [[String: Any]] ?? []
        expectEqual(probeQuotas.count, 1, "probe hides island rings in hiddenTypes")
        expectEqual(probeQuotas.first?["type"] as? String, "time:Claude · work 5h", "probe keeps visible rings")
        let feedBack = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fakeHome.appendingPathComponent(".harnais/quotas.json"))
        ) as? [String: Any]
        expectEqual(
            probe["capturedAt"] as? String, feedBack?["capturedAt"] as? String,
            "probe passes capturedAt through"
        )
        let harnesses = probe["harnesses"] as? [String: Any] ?? [:]
        let probeConnections = harnesses["connections"] as? [[String: Any]] ?? []
        expectEqual(probeConnections.count, 3, "probe reports every connection")
        func synced(_ name: String) -> Bool? {
            (probeConnections.first { $0["mcpName"] as? String == name })?["synced"] as? Bool
        }
        expectEqual(synced("google-drive"), true, "applied connections report synced")
        expectEqual(synced("slack"), false, "excluded connections report unsynced")
        expectEqual(synced("grafana-prod"), false, "never-applied connections report unsynced")
        let lastApply = harnesses["lastApply"] as? [String: Any] ?? [:]
        expectEqual(lastApply["files"] as? [String], ["/tmp/x/mcp.json"], "probe reports last apply files")
        expectEqual(lastApply["hiddenRings"] as? [String], ["time:Claude · work 7d"], "probe reports hidden rings")
        let emptyHome = root.appendingPathComponent("empty-home")
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        let emptyProbe = try runProbe(home: emptyHome)
        expectEqual((emptyProbe["quotas"] as? [Any])?.count, 0, "probe with no feed reports empty quotas")
        expectEqual(
            ((emptyProbe["harnesses"] as? [String: Any])?["connections"] as? [Any])?.count, 0,
            "probe with no registry reports no connections"
        )
        expectEqual(emptyProbe["stale"] as? Bool, true, "probe marks a missing feed stale")
        expectEqual(
            emptyProbe["refreshTriggered"] as? Bool, false,
            "probe does not trigger refresh without the harnais wrapper"
        )
        expectEqual(probe["stale"] as? Bool, false, "probe marks a fresh feed live")
        expectEqual(
            IslandFeed.staleAfter, 240,
            "Swift staleness matches the probe's STALE_AFTER"
        )

        let secretDecoder = JSONDecoder()
        secretDecoder.dateDecodingStrategy = .iso8601
        let flatOAuth = try secretDecoder.decode(
            IntegrationSecret.self,
            from: Data("{\"oauth\":{\"accessToken\":\"a\",\"tokenType\":\"Bearer\"}}".utf8)
        )
        expectEqual(flatOAuth.oauth?.accessToken, "a", "credentials decode the flat oauth shape")
        let legacyOAuth = try secretDecoder.decode(
            IntegrationSecret.self,
            from: Data("{\"oauth\":{\"_0\":{\"accessToken\":\"b\",\"tokenType\":\"Bearer\"}}}".utf8)
        )
        expectEqual(legacyOAuth.oauth?.accessToken, "b", "credentials still read legacy _0 files")
        let reencoded = try JSONEncoder().encode(
            IntegrationSecret.grafana(GrafanaTokenSet(url: "https://x.example", token: "t"))
        )
        let reencodedShape = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        let reencodedGrafana = reencodedShape?["grafana"] as? [String: Any]
        expectEqual(reencodedGrafana?["token"] as? String, "t", "credentials save the flat shape")
        expect(reencodedGrafana?["_0"] == nil, "credentials never write the _0 wrapper")

        let cleared = try exporter.apply(
            connections: [],
            accounts: [],
            commandPath: "/tmp/harnais",
            previousNames: ["google-drive"]
        )
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: cursorMCP)) as? [String: Any]
        let afterServers = after?["mcpServers"] as? [String: Any]
        expect(afterServers?["google-drive"] == nil, "empty apply removes Harnais MCP names")
        expect(afterServers?["excalidraw"] != nil, "empty apply still keeps unrelated servers")
        expect(cleared.mcpNames.isEmpty, "empty apply reports no MCP names")
    }
}
