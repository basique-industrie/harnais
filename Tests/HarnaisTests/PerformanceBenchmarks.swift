import Domain
import Foundation
import Infrastructure

enum PerformanceBenchmarks {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harnais-benchmark-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(provider: .claude, label: "Benchmark", slug: "benchmark", homePath: root.path)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        for file in 0..<12 {
            let lines = (0..<500).map { index in
                "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"message\":{\"id\":\"\(file)-\(index)\",\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20}},\"padding\":\"\(String(repeating: "x", count: 2200))\"}\n"
            }.joined()
            try lines.write(to: root.appendingPathComponent("projects/\(file).jsonl"), atomically: true, encoding: .utf8)
        }
        let cache = root.appendingPathComponent("usage.json")
        func measure(_ name: String, _ work: () throws -> Int) rethrows {
            let start = ProcessInfo.processInfo.systemUptime
            let count = try work()
            print("\(name): \(String(format: "%.4f", ProcessInfo.processInfo.systemUptime - start)) s; count=\(count)")
        }
        let scanner = SessionUsageScanner()
        measure("scan cold") { scanner.scan(accounts: [account], cacheURL: cache).events.count }
        for _ in 0..<3 { measure("scan warm") { scanner.scan(accounts: [account], cacheURL: cache).events.count } }
        try measure("20 short processes") {
            for _ in 0..<20 { _ = try ProcessRunner().run(executable: "/usr/bin/true", arguments: [], environment: [:], timeout: 2) }
            return 20
        }
    }
}
