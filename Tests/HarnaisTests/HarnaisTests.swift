import AppKit
import Domain
import Foundation
import Infrastructure

@main
enum HarnaisSelfTests {
    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--verify-t3-sync-copy" {
            try T3SyncSafetyTests.verifyCopy(registry: URL(fileURLWithPath: CommandLine.arguments[2]),
                                             settings: URL(fileURLWithPath: CommandLine.arguments[3]))
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--benchmark-usage" {
            try UsagePresentationTests.benchmark(cacheURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        if CommandLine.arguments.contains("--benchmark-review") {
            try PerformanceBenchmarks.run()
            return
        }
        var failed = 0
        var passed = 0

        func expect(_ condition: Bool, _ message: String) {
            if condition {
                passed += 1
            } else {
                failed += 1
                fputs("FAIL \(message)\n", stderr)
            }
        }

        func expectEqual<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            expect(got == want, "\(message) (got \(got), want \(want))")
        }

        expectEqual(Slug.make(from: "Work Account"), "work-account", "slug from label")
        expectEqual(ProviderKind.claude.t3Driver, "claudeAgent", "T3 Claude driver")
        expectEqual(ProviderKind.cursor.defaultBinaryName, "cursor-agent", "Cursor binary name")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harnais-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try ProcessRunnerTests.run(expect: expect)
        #if DEBUG
        try HTTPTransferTests.run(expect: expect)
        #endif
        try UsageScannerCacheTests.run(root: root, expect: expect)
        try RegistrationOwnershipTests.run(root: root, expect: expect)
        try OutlookConnectionTests.run(expect: expect)
        try DriveConnectionTests.run(root: root, expect: expect)
        try DriveReaderTests.run(root: root, expect: expect)
        try DriveEditingTests.run(expect: expect)
        try WhatsAppConnectionTests.run(root: root, expect: expect)
        try ConnectionAvailabilityTests.run(root: root, expect: expect)
        try SharedConnectionTests.run(root: root, expect: expect)
        try ConnectionInventoryTests.run(root: root, expect: expect)
        try ConnectionLifecycleTests.run(root: root, expect: expect)
        try SkillLibraryTests.run(root: root, expect: expect)
        try SkillPresentationTests.run(root: root, expect: expect)
        try T3SyncSafetyTests.run(root: root, expect: expect)
        try CodexWeekTests.run(root: root, expect: expect)
        try TerminalCLITests.run(root: root, expect: expect)
        try OpenCodeTests.run(root: root, expect: expect)
        try OpenCodeAccountDetailsTests.run(root: root, expect: expect)
        try ResetCreditsTests.run(expect: expect)
        UsagePresentationTests.run(expect: expect)

        let isolation = IsolationEngine(
            identity: AppIdentity(),
            homeDirectory: root,
            profilesRoot: root.appendingPathComponent("profiles")
        )

        let claude = isolation.plan(provider: .claude, slug: "work", importDefault: false)
        expect(claude.env["CLAUDE_CONFIG_DIR"] == claude.homePath, "Claude uses CLAUDE_CONFIG_DIR")
        expect(claude.env["HOME"] == nil, "Claude never overrides HOME")

        let importedClaude = isolation.plan(provider: .claude, slug: "default", importDefault: true)
        expect(importedClaude.env.isEmpty, "imported Claude keeps the default home")
        expect(importedClaude.importedDefault, "imported flag")

        let isolatedCodex = isolation.plan(provider: .codex, slug: "personal", importDefault: false, codexMode: .isolated)
        expect(isolatedCodex.env["CODEX_HOME"] == isolatedCodex.homePath, "isolated Codex home")
        expect(isolatedCodex.shadowHomePath == nil, "isolated Codex has no shadow")

        let shadow = isolation.plan(provider: .codex, slug: "personal", importDefault: false, codexMode: .t3Shadow)
        expect(shadow.homePath.hasSuffix(".codex"), "T3 shadow shares ~/.codex")
        expect(shadow.shadowHomePath != nil, "T3 shadow path is set")
        expect(shadow.env["CODEX_HOME"] == shadow.shadowHomePath, "login writes auth into the shadow")

        let cursor = isolation.plan(provider: .cursor, slug: "work", importDefault: false)
        expectEqual(cursor.env["AGENT_CLI_CREDENTIAL_STORE"], "file", "Cursor file store")
        expect(cursor.env["CURSOR_CONFIG_DIR"] == cursor.homePath, "Cursor config dir")
        expect(isolation.isManaged(claude.homePath), "isolated Claude lives under profiles")
        expect(isolation.isManaged(importedClaude.homePath) == false, "imported Claude is not a Harnais profile")
        expect(isolation.isManaged(shadow.homePath) == false, "shared ~/.codex is not a Harnais profile")
        expect(isolation.isManaged(shadow.shadowHomePath ?? ""), "Codex shadow lives under profiles")
        let wipe = isolation.plan(provider: .claude, slug: "wipe-me", importDefault: false)
        try isolation.materialize(wipe)
        isolation.removeManagedHomes(
            for: Account(provider: .claude, label: "Wipe", slug: "wipe-me", homePath: wipe.homePath)
        )
        expect(
            FileManager.default.fileExists(atPath: wipe.homePath) == false,
            "delete removes Harnais-created profile folders"
        )
        try isolation.materialize(importedClaude)
        isolation.removeManagedHomes(
            for: Account(
                provider: .claude,
                label: "Default",
                slug: "default",
                homePath: importedClaude.homePath,
                importedDefault: true
            )
        )
        expect(
            FileManager.default.fileExists(atPath: importedClaude.homePath),
            "delete leaves imported vendor homes"
        )

        let registryURL = root.appendingPathComponent("accounts.json")
        let registry = AccountRegistry(fileURL: registryURL)
        let service = AccountService(
            registry: registry,
            isolation: IsolationEngine(
                identity: AppIdentity(),
                homeDirectory: root,
                profilesRoot: root.appendingPathComponent("profiles")
            ),
            wrappers: WrapperGenerator(identity: AppIdentity())
        )
        _ = service
        // Avoid writing wrappers into the real ~/.harnais/bin during tests by
        // creating the account through the registry after materializing a plan.
        let plan = isolation.plan(provider: .claude, slug: "work", importDefault: false)
        try isolation.materialize(plan)
        let account = Account(
            provider: .claude,
            label: "Work",
            slug: "work",
            homePath: plan.homePath,
            env: plan.env
        )
        try registry.add(account)
        expectEqual(try registry.accounts().count, 1, "registry stores an account")
        do {
            try registry.add(account)
            expect(false, "duplicate slug is rejected")
        } catch HarnaisError.duplicateSlug {
            expect(true, "duplicate slug is rejected")
        }

        let snippet = try T3Exporter(settingsURL: root.appendingPathComponent("missing.json")).snippetJSON(for: account)
        expect(snippet.contains("claudeAgent"), "T3 snippet names the Claude driver")
        expect(snippet.contains("homePath"), "T3 snippet includes homePath")

        let t3Settings = root.appendingPathComponent("settings.json")
        try Data("{\"_schemaVersion\":1,\"providerInstances\":{}}".utf8).write(to: t3Settings)
        try T3Exporter(settingsURL: t3Settings).apply(accounts: [account])
        let merged = try JSONSerialization.jsonObject(with: Data(contentsOf: t3Settings)) as? [String: Any]
        let instances = merged?["providerInstances"] as? [String: Any]
        expect(instances?[account.t3InstanceID] != nil, "T3 merge inserts the instance")
        expectEqual(
            T3Exporter(settingsURL: t3Settings).placement(of: account),
            .merged,
            "applied extra account is merged"
        )

        let t3Home = root.appendingPathComponent(".t3-home")
        let candidates = T3Exporter.candidateSettingsURLs(
            home: t3Home,
            environment: ["T3CODE_HOME": t3Home.appendingPathComponent("custom-t3").path]
        )
        expect(
            candidates.contains { $0.path.hasSuffix("custom-t3/userdata/settings.json") },
            "T3 discovery prefers T3CODE_HOME"
        )
        expect(
            candidates.contains { $0.path.hasSuffix(".t3/userdata/settings.json") },
            "T3 discovery includes ~/.t3/userdata/settings.json"
        )
        expect(
            candidates.contains { $0.path.hasSuffix("Library/Application Support/T3 Code/userdata/settings.json") },
            "T3 discovery still lists the legacy Application Support path"
        )
        let realT3 = t3Home.appendingPathComponent(".t3/userdata")
        try FileManager.default.createDirectory(at: realT3, withIntermediateDirectories: true)
        let discoveredSettings = realT3.appendingPathComponent("settings.json")
        try Data("{\"providerInstances\":{\"cursor\":{\"driver\":\"cursor\",\"enabled\":true,\"config\":{}}}}".utf8)
            .write(to: discoveredSettings)
        try T3Exporter(homeDirectory: t3Home, environment: [:]).apply(accounts: [account])
        let discovered = try JSONSerialization.jsonObject(with: Data(contentsOf: discoveredSettings)) as? [String: Any]
        let discoveredInstances = discovered?["providerInstances"] as? [String: Any]
        expect(discoveredInstances?["cursor"] != nil, "T3 merge keeps existing instances")
        expect(discoveredInstances?[account.t3InstanceID] != nil, "T3 apply finds ~/.t3/userdata/settings.json")

        let removed = Account(
            provider: .codex,
            label: "Gone",
            slug: "gone",
            homePath: "/tmp/gone",
            env: [:]
        )
        try T3Exporter(settingsURL: discoveredSettings).apply(accounts: [account, removed])
        try T3Exporter(settingsURL: discoveredSettings).apply(accounts: [account])
        let pruned = try JSONSerialization.jsonObject(with: Data(contentsOf: discoveredSettings)) as? [String: Any]
        let prunedInstances = pruned?["providerInstances"] as? [String: Any]
        expect(prunedInstances?[removed.t3InstanceID] != nil, "T3 apply preserves retired IDs referenced by conversations")

        let importedCursor = Account(
            provider: .cursor,
            label: "Default",
            slug: "default",
            homePath: t3Home.appendingPathComponent(".cursor").path,
            importedDefault: true
        )
        let importedClaudeAccount = Account(
            provider: .claude,
            label: "Perso",
            slug: "default",
            homePath: t3Home.appendingPathComponent(".claude").path,
            importedDefault: true
        )
        let existingCodexHome = t3Home.appendingPathComponent("codex-personal").path
        let collidingCodex = Account(
            provider: .codex,
            label: "Personal",
            slug: "personal",
            homePath: existingCodexHome,
            env: ["CODEX_HOME": existingCodexHome]
        )
        try Data(
            """
            {"providerInstances":{"cursor":{"driver":"cursor","enabled":true,"config":{"binaryPath":"/opt/cursor-agent"}},"codex_personal":{"driver":"codex","enabled":true,"config":{"homePath":"\(existingCodexHome)"}},"harnais_cursor_default":{"driver":"cursor","enabled":true,"config":{}},"harnais_claude_default":{"driver":"claudeAgent","enabled":true,"config":{}}}}
            """.utf8
        ).write(to: discoveredSettings)
        try T3Exporter(settingsURL: discoveredSettings, homeDirectory: t3Home).apply(
            accounts: [importedCursor, importedClaudeAccount, account, collidingCodex]
        )
        let deduped = try JSONSerialization.jsonObject(with: Data(contentsOf: discoveredSettings)) as? [String: Any]
        let dedupedInstances = deduped?["providerInstances"] as? [String: Any]
        expect(dedupedInstances?["cursor"] != nil, "T3 apply keeps the native Cursor instance")
        expect(dedupedInstances?[importedCursor.t3InstanceID] != nil, "T3 apply retains a previously linked default Cursor")
        expect(dedupedInstances?[importedClaudeAccount.t3InstanceID] != nil, "T3 apply retains a previously linked default Claude")
        expect(dedupedInstances?[account.t3InstanceID] != nil, "T3 apply still inserts isolated extra accounts")
        expect(dedupedInstances?["codex_personal"] != nil, "T3 apply keeps a native Codex instance with the same home")
        expect(dedupedInstances?[collidingCodex.t3InstanceID] == nil, "T3 apply does not duplicate a native instance with the same home")

        try TerminalLauncherTests.run(root: root, expect: expect)

        let wrapperIdentity = AppIdentity(dataDirectory: root.appendingPathComponent("harnais-data"))
        let wrappers = WrapperGenerator(identity: wrapperIdentity)
        let wrapperHome = isolation.profilePath(provider: .claude, slug: "temp-wrapper")
        try FileManager.default.createDirectory(atPath: wrapperHome, withIntermediateDirectories: true)
        let wrapperAccount = Account(
            provider: .claude,
            label: "Temp",
            slug: "temp-wrapper",
            homePath: wrapperHome,
            env: ["CLAUDE_CONFIG_DIR": wrapperHome, "NOTE": "it's"]
        )
        let wrapped = try wrappers.write(for: wrapperAccount, binaryPath: "/bin/echo")
        let wrapperBody = try String(contentsOf: wrapped, encoding: .utf8)
        expect(FileManager.default.isExecutableFile(atPath: wrapped.path), "wrapper is executable")
        expect(wrapperBody.contains("exec '/bin/echo'"), "wrapper quotes the binary")
        expect(wrapperBody.contains("\\''"), "wrapper quotes apostrophes")
        let wrapperRegistry = AccountRegistry(
            fileURL: wrapperIdentity.accountsFileURL,
            identity: wrapperIdentity
        )
        try wrapperRegistry.add(wrapperAccount)
        try AccountService(
            registry: wrapperRegistry,
            isolation: isolation,
            wrappers: wrappers
        ).remove(wrapperAccount)
        expect(try wrapperRegistry.accounts().isEmpty, "remove drops the registry row")
        expect(
            FileManager.default.fileExists(atPath: wrapped.path) == false,
            "remove deletes the PATH wrapper"
        )
        expect(
            FileManager.default.fileExists(atPath: wrapperHome) == false,
            "remove deletes the Harnais profile folder"
        )
        expectEqual(BinaryLocator.which("/bin/echo"), "/bin/echo", "absolute executables skip the login shell")
        expectEqual(ModelRates.pricedAsOf, "Sep 2026", "cost copy names the rate vintage")

        let lockFile = AtomicJSONFile(fileURL: root.appendingPathComponent("locked-settings.json"))
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            try? lockFile.write(HarnaisSettingsDocument(terminalAppID: "n\(index)"))
        }
        expect(
            (try? lockFile.read(HarnaisSettingsDocument.self))?.terminalAppID?.hasPrefix("n") == true,
            "locked concurrent writes leave valid JSON"
        )

        do {
            try T3Exporter(homeDirectory: t3Home.appendingPathComponent("empty"), environment: [:]).apply(accounts: [account])
            expect(false, "missing T3 settings throws")
        } catch HarnaisError.t3SettingsMissing {
            expect(true, "missing T3 settings throws")
        }

        let extensionSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Infrastructure/Resources/iles-extension")
        let ilesRoot = root.appendingPathComponent("iles-install")
        let ilesDest = ilesRoot.appendingPathComponent("extensions/harnais")
        let installer = IlesExtensionInstaller(
            sourceDirectory: extensionSource,
            destinations: [ilesDest]
        )
        let installed = try installer.install()
        expectEqual(installed, [ilesDest], "Iles installer copies the bundled extension")
        expect(
            FileManager.default.fileExists(atPath: ilesDest.appendingPathComponent("manifest.json").path),
            "Iles install writes manifest.json"
        )
        expect(
            FileManager.default.isExecutableFile(atPath: ilesDest.appendingPathComponent("probe.sh").path),
            "Iles install marks probe.sh executable"
        )
        let packagedResources = root.appendingPathComponent("Packaged.app/Contents/Resources")
        let packagedExtension = packagedResources
            .appendingPathComponent("Harnais_Infrastructure.bundle/iles-extension")
        try FileManager.default.createDirectory(at: packagedExtension, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: packagedExtension.appendingPathComponent("manifest.json"))
        let foundExtension = IlesExtensionInstaller.bundledExtensionDirectory(searchRoots: [packagedResources])
        expect(
            foundExtension?.standardizedFileURL.path == packagedExtension.standardizedFileURL.path,
            "Iles installer finds the extension under Contents/Resources"
        )
        expect(
            IlesExtensionInstaller.bundledExtensionDirectory(searchRoots: [root.appendingPathComponent("empty")]) == nil,
            "Iles installer returns nil when the resource bundle is absent"
        )

        expect(account.wrapperName == "claude-work", "wrapper name")
        try QuotaParsingTests.run(root: root, expect: expect)

        try AccountAuthenticationTests.run(root: root, expect: expect)

        expectEqual(BinaryUpdater.npmGlobalPrefix(
            realPath: "/usr/local/lib/node_modules/@openai/codex/bin/codex",
            packageName: "@openai/codex"
        ), "/usr/local", "npm prefix from node_modules")
        expect(BinaryUpdater.homebrewOwnership(realPath: "/opt/homebrew/Cellar/claude-code/2.1.0/bin/claude")?.name == "claude-code", "homebrew formula")
        let bunPlan = BinaryUpdater.plan(
            provider: .codex,
            binaryPath: "/Users/x/.bun/bin/codex",
            realPath: "/Users/x/.bun/bin/codex"
        )
        expectEqual(bunPlan?.command, "bun i -g @openai/codex@latest", "bun global update command")
        let cursorPlan = BinaryUpdater.plan(
            provider: .cursor,
            binaryPath: "/usr/local/bin/cursor-agent",
            realPath: "/usr/local/bin/cursor-agent"
        )
        expectEqual(cursorPlan?.command, "cursor-agent update", "cursor native update")
        let brewPlan = BinaryUpdater.plan(
            provider: .claude,
            binaryPath: "/opt/homebrew/bin/claude",
            realPath: "/opt/homebrew/Cellar/claude-code/2.1.0/bin/claude"
        )
        expectEqual(brewPlan?.command, "brew upgrade claude-code", "homebrew update command")
        let npmPlan = BinaryUpdater.plan(
            provider: .claude,
            binaryPath: "/usr/local/bin/claude",
            realPath: "/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude"
        )
        expect(npmPlan?.command.contains("npm install -g --prefix /usr/local") == true, "npm global update command")
        expect(BinaryUpdater.compareVersions("0.153.4", "0.160.0") < 0, "semver behind")
        expect(BinaryUpdater.compareVersions("2.1.268", "2.1.268") == 0, "semver equal")

        try UsageFormattingTests.run(root: root, expect: expect)

        try UsageTranscriptTests.run(root: root, expect: expect)

        func sample(_ provider: ProviderKind, _ label: String, _ slug: String) -> Account {
            Account(provider: provider, label: label, slug: slug, homePath: "/tmp")
        }
        let grouped = [
            sample(.claude, "Default", "default"),
            sample(.codex, "Default", "default"),
            sample(.claude, "Work", "work"),
        ].groupedByProvider()
        expectEqual(grouped.map(\.provider), [.claude, .codex], "groups follow provider order")
        expectEqual(grouped[0].accounts.map(\.label), ["Default", "Work"], "keeps account order inside a group")
        expectEqual(
            AccountNaming.suggestedLabel(for: .claude, existing: grouped[0].accounts),
            "Personal",
            "suggests Personal when Default already exists"
        )
        expectEqual(
            AccountNaming.suggestedLabel(for: .cursor, existing: grouped.flatMap(\.accounts)),
            "Personal",
            "suggests Personal for a provider with no accounts"
        )
        expectEqual(
            QuotaAggregator.quotaTypeKey(provider: .claude, slug: "default", window: "7d"),
            "time:Claude · default 7d",
            "Iles type keys use slug so a rename does not orphan rings"
        )
        expectEqual(
            QuotaAggregator.quotaTypeKey(provider: .claude, slug: "work", window: "5h"),
            "time:Claude · work 5h",
            "session windows also key off slug"
        )
        expectEqual(
            QuotaAggregator.quotaGroupTitle(provider: .claude, visibleName: "ada"),
            "Claude · ada",
            "quota groups use the visible account name, not the mailbox"
        )
        expect(AccountNaming.isReadable("Work"), "Work is a readable label")
        expect(AccountNaming.isReadable("g") == false, "single letter is not readable")
        expect(
            AccountNaming.shouldShowMailbox(visibleName: "Work", email: "ada@example.com"),
            "mailbox shows when the name is not the address"
        )
        expect(
            AccountNaming.shouldShowMailbox(visibleName: "ada", email: "ada@example.com"),
            "mailbox shows the domain even when the name is the local part"
        )
        expect(
            AccountNaming.shouldShowMailbox(visibleName: "ada@example.com", email: "ada@example.com") == false,
            "mailbox hides when the name is the full address"
        )
        let shortNamed = Account(
            provider: .claude,
            label: "g",
            slug: "g",
            homePath: "/tmp",
            accountEmail: "ada@example.com"
        )
        expectEqual(shortNamed.displayLabel(), "ada", "short label falls back to email local part")
        expectEqual(
            sample(.claude, "g", "g").displayLabel(),
            "Claude",
            "short label without email uses the provider name"
        )
        expectEqual(
            ConnectionReport.updatedAgoLabel(from: nil),
            nil,
            "no timestamp without a date"
        )
        expectEqual(
            ConnectionReport.updatedAgoLabel(from: Date()),
            "Updated just now",
            "fresh timestamp is just now"
        )
        expectEqual(
            T3Exporter(settingsURL: discoveredSettings, homeDirectory: t3Home).placement(of: importedCursor),
            .nativeDefault,
            "imported default stays T3 native"
        )
        let unmerged = Account(provider: .claude, label: "Extra", slug: "extra", homePath: "/tmp/extra")
        let emptyT3 = root.appendingPathComponent("empty-t3.json")
        try Data("{\"providerInstances\":{}}".utf8).write(to: emptyT3)
        expectEqual(
            T3Exporter(settingsURL: emptyT3).placement(of: unmerged),
            .notMerged,
            "missing instance is not merged"
        )

        try IntegrationExportTests.run(root: root, expect: expect)

        if failed == 0 {
            print("HarnaisSelfTests: \(passed) passed")
            Foundation.exit(0)
        } else {
            fputs("HarnaisSelfTests: \(failed) failed, \(passed) passed\n", stderr)
            Foundation.exit(1)
        }
    }
}
