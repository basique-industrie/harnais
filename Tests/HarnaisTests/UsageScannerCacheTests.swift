import Domain
import Foundation
import Infrastructure

enum UsageScannerCacheTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let folder = root.appendingPathComponent("cache-regression")
        let projects = folder.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let file = projects.appendingPathComponent("session.jsonl")
        let cache = folder.appendingPathComponent("usage-cache.json")
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        let line = "{\"type\":\"assistant\",\"timestamp\":\"\(stamp)\",\"message\":{\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20}}}"
        let account = Account(provider: .claude, label: "Cache", slug: "cache", homePath: folder.path)
        let scanner = SessionUsageScanner()
        // Cross chunk boundaries, discard an oversized line, and retain an unterminated final line.
        let contents = String(repeating: " ", count: 262_120) + "\n" + line + "\r\n" + String(repeating: "x", count: SessionUsageScanner.maxClaudeLineBytes + 1) + "\n" + line
        try contents.write(to: file, atomically: true, encoding: .utf8)
        let cold = scanner.scan(accounts: [account], cacheURL: cache, now: now)
        expect(cold.events.count == 2, "streaming scan handles chunk boundaries, CRLF, oversized lines and final partial line")
        let marker = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: cache.path)
        let warm = scanner.scan(accounts: [account], cacheURL: cache, now: now)
        let modified = try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        expect(warm.events == cold.events, "warm scan preserves all events")
        expect(modified == marker, "unchanged scan does not rewrite cache")
        let other = Account(provider: .claude, label: "Other", slug: "other", homePath: folder.path)
        let reassigned = scanner.scan(accounts: [other], cacheURL: cache, now: now)
        expect(reassigned.events.count == 2 && reassigned.events.allSatisfy { $0.accountID == other.id }, "same transcript cannot inherit an old account's cached attribution")
        try FileManager.default.removeItem(at: file)
        expect(scanner.scan(accounts: [other], cacheURL: cache, now: now).events.isEmpty, "deleted transcripts are pruned from cache")
        expect(scanner.load(cacheURL: cache) == nil, "pruned cache does not resurrect deleted events")
        let dates = ["2026-09-28T10:20:30Z", "2026-09-28T10:20:30.123Z", "2026-09-28T12:20:30+02:00", "bad date"]
        for value in dates {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let whole = ISO8601DateFormatter()
            whole.formatOptions = [.withInternetDateTime]
            expect(QuotaReset.isoDate(value) == (fractional.date(from: value) ?? whole.date(from: value)), "cached date parser preserves ISO8601 behavior for \(value)")
        }
    }
}
