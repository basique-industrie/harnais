import Domain
import Foundation
import Infrastructure

enum T3ServerTests {
    /// Read-only check against the T3 server running for `settings`: issues a read-only session,
    /// lists provider statuses and revokes the session. Prints no tokens.
    static func probe(settings: URL) throws {
        guard let server = T3Server.running(settingsURL: settings) else {
            throw HarnaisError.processFailed("No T3 server is running for \(settings.path).")
        }
        print("T3 server pid \(server.runtime.pid) via \(server.executableURL.lastPathComponent)")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<[T3ProviderStatus], Error> = .success([])
        Task.detached {
            do {
                outcome = .success(try await server.withSession(scopes: ["orchestration:read"]) { session in
                    let connection = session.connect()
                    defer { Task { await connection.close() } }
                    return T3ProviderStatus.parseConfig(try await connection.request("server.getConfig"))
                })
            } catch {
                outcome = .failure(error)
            }
            done.signal()
        }
        done.wait()
        for status in try outcome.get() {
            print("\(status.instanceID) [\(status.driver)] \(status.auth.rawValue) windows=\(status.usageWindows.count)")
        }
    }

    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        func expectEqual<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            expect(got == want, "\(message) (got \(got), want \(want))")
        }
        func json(_ text: String) -> Data { Data(text.utf8) }
        func object(_ text: String) -> [String: Any]? {
            try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }

        // server-runtime.json
        let state = root.appendingPathComponent("t3-server/userdata", isDirectory: true)
        let runtime = T3ServerRuntime.parse(
            json(#"{"version":1,"pid":4242,"port":3773,"origin":"http://127.0.0.1:3773","startedAt":"2026-10-08T07:00:00.000Z"}"#),
            stateDirectory: state
        )
        expectEqual(runtime?.pid, 4242, "T3 server runtime PID")
        expectEqual(runtime?.webSocketURL?.absoluteString, "ws://127.0.0.1:3773/ws?orchestrationProtocol=2", "T3 WebSocket URL carries the protocol version")
        expect(T3ServerRuntime.parse(json(#"{"version":2,"pid":4242,"origin":"http://127.0.0.1:3773"}"#), stateDirectory: state) == nil, "unknown runtime file version is ignored")
        expect(T3ServerRuntime.parse(json(#"{"version":1,"pid":0,"origin":"http://127.0.0.1:3773"}"#), stateDirectory: state) == nil, "runtime file without a valid PID is ignored")
        expect(T3ServerRuntime.parse(json(#"{"version":1,"pid":4242,"origin":"file:///tmp"}"#), stateDirectory: state) == nil, "runtime file with a non-HTTP origin is ignored")
        let settings = state.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try json(#"{"version":1,"pid":2147483000,"origin":"http://127.0.0.1:3773"}"#)
            .write(to: state.appendingPathComponent("server-runtime.json"))
        expect(T3ServerRuntime.running(settingsURL: settings) == nil, "a runtime file left by a stopped server is ignored")
        expect(T3Server.running(settingsURL: settings) == nil, "no T3 server without a live process")

        // RPC frames
        let request = try T3RPC.request(id: "7", tag: "server.updateSettings", payload: json(#"{"patch":{}}"#))
        let requestObject = object(request)
        expect(requestObject?["_tag"] as? String == "Request" && requestObject?["id"] as? String == "7"
               && requestObject?["tag"] as? String == "server.updateSettings"
               && (requestObject?["payload"] as? [String: Any])?["patch"] != nil
               && (requestObject?["headers"] as? [Any])?.isEmpty == true, "RPC request frame")
        expect(object(T3RPC.ack(id: "3"))?["requestId"] as? String == "3", "RPC ack names the stream")
        let interrupt = object(T3RPC.interrupt(id: "3"))
        expect(interrupt?["_tag"] as? String == "Interrupt" && (interrupt?["interruptors"] as? [Any]) != nil, "RPC interrupt frame")
        expectEqual(
            T3RPC.frame(json(#"{"_tag":"Exit","requestId":"1","exit":{"_tag":"Success","value":{"ok":true}}}"#)),
            .success(requestID: "1", value: json(#"{"ok":true}"#)),
            "RPC success frame"
        )
        expectEqual(
            T3RPC.frame(json(#"{"_tag":"Exit","requestId":"2","exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"ServerSettingsError","detail":"Provider instance is busy."}}]}}"#)),
            .failure(requestID: "2", message: "Provider instance is busy."),
            "RPC failure frame keeps T3's detail"
        )
        expectEqual(
            T3RPC.frame(json(#"{"_tag":"Exit","requestId":"2","exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"AuthorizationError"}}]}}"#)),
            .failure(requestID: "2", message: "T3 Code did not allow this change."),
            "RPC authorization failure"
        )
        expectEqual(
            T3RPC.frame(json(#"{"_tag":"Chunk","requestId":"4","values":[{"phase":"waiting"},{"phase":"succeeded"}]}"#)),
            .chunk(requestID: "4", values: [json(#"{"phase":"waiting"}"#), json(#"{"phase":"succeeded"}"#)]),
            "RPC stream chunk"
        )
        expectEqual(T3RPC.frame(json(#"{"_tag":"Pong"}"#)), .other, "RPC frames Harnais does not use")

        // Sign-in states
        let waiting = T3AuthState.parse(json(#"{"phase":"waiting","flowId":"f1","authorizationUrl":"https://cursor.com/loginDeepControl?challenge=x","message":"Finish in your browser."}"#))
        expectEqual(waiting?.phase, .waiting, "T3 sign-in phase")
        expectEqual(waiting?.flowID, "f1", "T3 sign-in flow ID")
        expectEqual(waiting?.authorizationURL?.host, "cursor.com", "T3 sign-in page")
        expect(waiting?.isFinished == false, "a waiting sign-in is not finished")
        let unsafe = T3AuthState.parse(json(#"{"phase":"waiting","authorizationUrl":"file:///Applications/Calculator.app"}"#))
        expect(unsafe != nil && unsafe?.authorizationURL == nil, "Harnais only opens HTTPS sign-in pages")
        expect(T3AuthState.parse(json(#"{"phase":"succeeded"}"#))?.isFinished == true, "a succeeded sign-in is finished")
        expect(T3AuthState.parse(json(#"{"phase":"later"}"#)) == nil, "unknown sign-in phases are ignored")

        // Provider status and managed ChatGPT accounts
        let status = T3ProviderStatus.parse(json(#"""
            {"instanceId":"managed_chatgpt","driver":"codex","checkedAt":"2026-10-08T05:54:45.913Z",
             "auth":{"status":"authenticated","email":"me@example.com","label":"ChatGPT Plus"},
             "usageLimits":{"windows":[{"kind":"weekly","label":"Weekly","usedPercent":52,"resetsAt":"2026-10-14T05:47:22.000Z"}],
                            "externalUsage":{"url":"https://chatgpt.com/#settings/Usage"}}}
            """#))
        expectEqual(status?.auth, .authenticated, "T3 status auth")
        expectEqual(status?.planLabel, "ChatGPT Plus", "T3 status plan")
        expectEqual(status?.usageWindows.first?.label, "Weekly", "T3 status usage window")
        expectEqual(status?.usageWindows.first?.usedPercent, 52, "T3 status usage percent")
        expect(status?.usageWindows.first?.resetsAt != nil, "T3 status reset date")
        expectEqual(status?.externalUsageURL?.host, "chatgpt.com", "T3 status external usage page")
        let configStatuses = T3ProviderStatus.parseConfig(json(#"{"providers":[{"instanceId":"cursor","driver":"cursor","auth":{"status":"unauthenticated"}},{"driver":"broken"}]}"#))
        expectEqual(configStatuses.map(\.instanceID), ["cursor"], "server.getConfig provider statuses")
        expectEqual(configStatuses.first?.auth, .unauthenticated, "server.getConfig auth state")

        let managed = T3ManagedAccount.parse(settings: json(#"""
            {"providerInstances":{
              "codex":{"driver":"codex","enabled":true,"config":{}},
              "work_chatgpt":{"driver":"codex","displayName":"Work ChatGPT","enabled":false,"config":{"setupMode":"managed"}},
              "chatgpt_2":{"driver":"codex","config":{"setupMode":"managed"}},
              "harnais_codex_work":{"driver":"codex","config":{"homePath":"/tmp/codex"}},
              "cursor_managed":{"driver":"cursor","config":{"setupMode":"managed"}}}}
            """#))
        expectEqual(managed.map(\.instanceID), ["chatgpt_2", "work_chatgpt"], "only T3-managed ChatGPT accounts are listed")
        expectEqual(managed.first?.displayName, "ChatGPT", "managed account without a name")
        expectEqual(managed.last?.enabled, false, "managed account keeps T3's enabled flag")

        // Instance changes shared by the server and file paths
        let account = Account(provider: .codex, label: "Work", slug: "work", homePath: "/tmp/harnais-codex-work")
        let exporter = T3Exporter(settingsURL: settings, homeDirectory: root)
        let existing = object(#"""
            {"codex":{"driver":"codex","enabled":true,"config":{}},
             "harnais_codex_old":{"driver":"codex","enabled":true,"config":{}},
             "custom":{"driver":"codex","enabled":true,"config":{"homePath":"/elsewhere"}}}
            """#) ?? [:]
        let merged = try exporter.mergedProviderInstances(
            accounts: [account],
            into: existing,
            changes: T3InstanceChanges(disable: ["harnais_codex_old", "codex", "custom", account.t3InstanceID])
        )
        expect((merged[account.t3InstanceID] as? [String: Any])?["driver"] as? String == "codex", "merge adds the Harnais profile")
        expect((merged["harnais_codex_old"] as? [String: Any])?["enabled"] as? Bool == false, "removed Harnais profiles are turned off in T3")
        expect((merged["codex"] as? [String: Any])?["enabled"] as? Bool == true, "T3's own providers are never turned off")
        expect((merged["custom"] as? [String: Any])?["enabled"] as? Bool == true, "user-made T3 providers are never turned off")
        expect((merged[account.t3InstanceID] as? [String: Any])?["enabled"] as? Bool != false, "a profile being synced is not turned off")
        expectEqual(Set(merged.keys), Set(existing.keys).union([account.t3InstanceID]), "merge keeps every existing entry")

        // A removed profile's entry stays in T3, switched off. Adding the profile again turns it back on.
        try json(#"{"providerInstances":{"\#(account.t3InstanceID)":{"driver":"codex","enabled":false,"config":{}}}}"#)
            .write(to: settings)
        expectEqual(exporter.placement(of: account), .notMerged, "a switched-off Harnais entry is not counted as in T3")
        let switchedOff = object(#"{"\#(account.t3InstanceID)":{"driver":"codex","enabled":false,"config":{}}}"#) ?? [:]
        let kept = try exporter.mergedProviderInstances(accounts: [account], into: switchedOff)
        expect((kept[account.t3InstanceID] as? [String: Any])?["enabled"] as? Bool == false, "a plain sync keeps T3's enabled flag")
        let enabled = try exporter.mergedProviderInstances(
            accounts: [account], into: switchedOff, changes: T3InstanceChanges(enable: [account.t3InstanceID])
        )
        expect((enabled[account.t3InstanceID] as? [String: Any])?["enabled"] as? Bool == true, "adding a profile again turns its entry back on")
    }
}
