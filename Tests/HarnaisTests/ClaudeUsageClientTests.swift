import Domain
import Foundation
import Infrastructure

enum ClaudeUsageClientTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
        var total: Int { lock.withLock { count } }
    }

    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let now = Date(timeIntervalSince1970: 1_792_679_400)
        let data = Data(#"{"seven_day":{"utilization":100}}"#.utf8)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!)
        request.setValue("Bearer test-account-a", forHTTPHeaderField: "Authorization")
        let calls = Calls()
        let client = ClaudeUsageClient { _ in
            calls.next() == 2 ? (Data(), 429, "120") : (data, 200, nil)
        }
        _ = try client.send(request, now: now)
        let preflight = try client.send(request, now: now.addingTimeInterval(2))
        expect(preflight.0 == data && calls.total == 1, "reset preflight reuses a fresh usage response instead of immediately hitting the endpoint again")
        _ = try client.send(request, now: now.addingTimeInterval(61), maximumAge: ClaudeUsageClient.resetMaxAge)
        let cooled = try client.send(request, now: now.addingTimeInterval(130))
        expect(cooled.1 == 429 && calls.total == 2, "Retry-After prevents refresh and preflight from repeating a refused request")
        var other = request
        other.setValue("Bearer test-account-b", forHTTPHeaderField: "Authorization")
        expect(try client.send(other, now: now.addingTimeInterval(130)).1 == 200, "one account's cooldown does not block another")
        expect(try client.send(request, now: now.addingTimeInterval(182)).1 == 200, "a request is allowed after Retry-After")
        try client.withInvalidatedUsage(request) {}
        _ = try client.send(request, now: now.addingTimeInterval(183))
        expect(calls.total == 5, "redemption invalidates that account's cached quota and credit count")

        let dateCalls = Calls()
        let dateClient = ClaudeUsageClient { _ in
            _ = dateCalls.next()
            return (Data(), 429, "Thu, 22 Oct 2026 16:00:00 GMT")
        }
        let beforeExpiry = QuotaReset.isoDate("2026-10-22T15:55:00Z")!
        _ = try dateClient.send(request, now: beforeExpiry)
        _ = try dateClient.send(request, now: beforeExpiry.addingTimeInterval(120))
        expect(dateCalls.total == 1, "Retry-After also accepts an HTTP date")

        for header in [nil, "0", "invalid", "-1", "NaN", "Infinity", "0.5", "Wed, 21 Oct 2026 16:00:00 GMT"] as [String?] {
            let attempts = Calls()
            let backoff = ClaudeUsageClient { _ in
                _ = attempts.next()
                return (Data(), 429, header)
            }
            _ = try backoff.send(request, now: beforeExpiry)
            _ = try backoff.send(request, now: beforeExpiry.addingTimeInterval(299), maximumAge: 0)
            expect(attempts.total == 1, "invalid Retry-After \(header ?? "missing") waits five minutes even for a forced read")
            _ = try backoff.send(request, now: beforeExpiry.addingTimeInterval(301))
            _ = try backoff.send(request, now: beforeExpiry.addingTimeInterval(900))
            expect(attempts.total == 2, "repeated 429s increase the fallback wait to ten minutes")
        }

        let sharedDirectory = root.appendingPathComponent("claude-usage-shared")
        let sharedCalls = Calls()
        let first = ClaudeUsageClient(cacheDirectory: sharedDirectory) { _ in
            _ = sharedCalls.next()
            return (data, 200, nil)
        }
        _ = try first.send(request, now: now)
        let restarted = ClaudeUsageClient(cacheDirectory: sharedDirectory) { _ in
            _ = sharedCalls.next()
            return (Data(), 429, "3600")
        }
        _ = try restarted.send(request, now: now.addingTimeInterval(120))
        expect(sharedCalls.total == 1, "new CLI instances reuse the GUI's five-minute provider response")
        _ = try restarted.send(request, now: now.addingTimeInterval(121), maximumAge: ClaudeUsageClient.resetMaxAge)
        _ = try first.send(request, now: now.addingTimeInterval(600))
        expect(sharedCalls.total == 2, "a preflight needs a response under sixty seconds and its cooldown is shared back to the GUI")
        try first.withInvalidatedUsage(request) {}
        _ = try first.send(request, now: now.addingTimeInterval(700))
        expect(sharedCalls.total == 2, "invalidating a response cannot bypass a server cooldown")
        let files = try FileManager.default.contentsOfDirectory(at: sharedDirectory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600,
                   "shared usage state is owner-only")
            expect(try !String(contentsOf: file, encoding: .utf8).contains("test-account-a"), "shared state stores no bearer credentials")
        }

        let mutationDirectory = root.appendingPathComponent("claude-usage-mutation")
        let mutationCalls = Calls()
        let mutating = ClaudeUsageClient(cacheDirectory: mutationDirectory) { _ in
            _ = mutationCalls.next()
            return (data, 200, nil)
        }
        _ = try mutating.send(request, now: now)
        struct LostResponse: Error {}
        do {
            try mutating.withInvalidatedUsage(request) { throw LostResponse() }
            expect(false, "a lost redemption response remains an error")
        } catch is LostResponse {}
        _ = try mutating.send(request, now: now.addingTimeInterval(1))
        expect(mutationCalls.total == 2, "even an unconfirmed redemption invalidates the shared usage response")

        let stateFile = try FileManager.default.contentsOfDirectory(at: mutationDirectory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" }!
        try Data("invalid state".utf8).write(to: stateFile)
        do {
            _ = try mutating.send(request, now: now.addingTimeInterval(2))
            expect(false, "corrupt coordination state must fail closed")
        } catch {
            expect(mutationCalls.total == 2, "a corrupt shared state does not silently bypass request coordination")
        }

        // Separate processes exercise the actual flock boundary, not only NSLock.
        let processDirectory = root.appendingPathComponent("claude-usage-processes")
        let children = (0..<2).map { _ in Process() }
        for child in children {
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--claude-usage-probe-fixture", processDirectory.path]
            child.standardOutput = FileHandle.nullDevice
            try child.run()
        }
        for child in children { child.waitUntilExit() }
        expect(children.allSatisfy { $0.terminationStatus == 0 }, "parallel usage helper processes succeed")
        expect(try String(contentsOf: processDirectory.appendingPathComponent("calls.txt"), encoding: .utf8) == "1",
               "the GUI and an Iles-style CLI process make a single shared request")

        let probeCalls = Calls()
        let probe = ClaudeQuotaProbe(http: { _ in
            _ = probeCalls.next()
            return (Data(), 429)
        })
        let limited = try probe.fetchUsage(request)
        expect(limited.error?.contains("429") == true && limited.quotas.isEmpty && probeCalls.total == 1,
               "a usage 429 returns an error without retrying the plain endpoint or throwing into CLI fallback")

        let fallbackCalls = Calls()
        let fallback = ClaudeQuotaProbe(http: { _ in
            fallbackCalls.next() == 1 ? (Data(), 400) : (data, 200)
        })
        expect(try fallback.fetchUsage(request).quotas.first?.percentRemaining == 0 && fallbackCalls.total == 2,
               "servers without the optional credit query still support the plain usage endpoint")

        let unavailableCalls = Calls()
        let unavailable = ClaudeQuotaProbe(http: { _ in
            _ = unavailableCalls.next()
            return (Data(), 503)
        })
        do {
            _ = try unavailable.fetchUsage(request)
            expect(false, "a service failure should be reported")
        } catch {
            expect(unavailableCalls.total == 1, "a service failure does not retry the same endpoint without query parameters")
        }

        let identity = AppIdentity(dataDirectory: root.appendingPathComponent("retained-usage"))
        let account = Account(provider: .claude, label: "Fixture", slug: "fixture", homePath: root.path)
        let previous = AccountQuotaSnapshot(id: account.id.uuidString, provider: "claude", label: account.label,
            quotas: [FeedQuota(type: "weekly", percentRemaining: 0)],
            resetCredits: ResetCredits(availableCount: 1, nextExpiresAt: now.addingTimeInterval(3_600)))
        try AtomicJSONFile(fileURL: identity.quotasFileURL).write(QuotaFeed(capturedAt: now, accounts: [previous]))
        let collector = QuotaAggregator(identity: identity, isolation: IsolationEngine(identity: identity), claudeProbe: { _, _ in
            ProbeResult(error: ClaudeUsageClient.rateLimitMessage)
        })
        let retained = collector.refresh(accounts: [account]).accounts.first
        expect(retained?.quotas == previous.quotas && retained?.resetCredits == previous.resetCredits,
               "a 429 preserves the last authoritative quota and reset count")
        expect(retained?.error?.contains("Showing the last known usage") == true,
               "retained values carry an explicit stale-reading error")
    }

    static func runProcessFixture(directory: URL) throws {
        let client = ClaudeUsageClient(cacheDirectory: directory) { _ in
            let counter = directory.appendingPathComponent("calls.txt")
            let previous = (try? String(contentsOf: counter, encoding: .utf8)).flatMap(Int.init) ?? 0
            Thread.sleep(forTimeInterval: 0.15)
            try String(previous + 1).write(to: counter, atomically: true, encoding: .utf8)
            return (Data(#"{"seven_day":{"utilization":100}}"#.utf8), 200, nil)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer subprocess-fixture", forHTTPHeaderField: "Authorization")
        _ = try client.send(request)
    }
}
