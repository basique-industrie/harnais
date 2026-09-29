import Domain
import Foundation
import Infrastructure

enum ProcessRunnerTests {
    static func run(expect: (Bool, String) -> Void) throws {
        let runner = ProcessRunner()
        func shell(_ command: String, input: String? = nil, timeout: Double = 3, cap: Int = 4 * 1024 * 1024) throws -> ProcessResult {
            try runner.run(executable: "/bin/sh", arguments: ["-c", command], environment: ["PATH": "/usr/bin:/bin"], timeout: timeout, input: input, maximumOutputBytes: cap)
        }
        let large = try shell("head -c 2097152 /dev/zero")
        expect(large.exitCode == 0 && large.output.utf8.count == 2_097_152, "drains output larger than pipe capacity before waiting for exit")
        let input = String(repeating: "hello", count: 200_000)
        let echoed = try shell("head -c 131072 /dev/zero; cat", input: input)
        expect(echoed.output.utf8.count == 131_072 + input.utf8.count && echoed.output.hasSuffix(input), "large input and output make progress together")
        let failure = try shell("printf stdout; printf stderr >&2; exit 7")
        expect(failure.exitCode == 7 && failure.output == "stdoutstderr", "preserves merged output and nonzero exit status")
        let stdoutOnly = try runner.run(executable: "/bin/sh", arguments: ["-c", "printf path; printf warning >&2"], environment: [:], timeout: 2, mergeStandardError: false)
        expect(stdoutOnly.output == "path", "PATH discovery can exclude shell startup warnings")
        let closed = try shell("exec true", input: input)
        expect(closed.exitCode == 0, "child closing stdin does not crash the app with SIGPIPE")
        var start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try shell("trap '' TERM; exec sleep 10", timeout: 0.15)
            expect(false, "silent child must time out")
        } catch {
            expect(ProcessInfo.processInfo.systemUptime - start < 2, "timeout kills even a child ignoring SIGTERM")
        }
        do {
            _ = try shell("head -c 2097152 /dev/zero", cap: 1024)
            expect(false, "output cap must reject excessive output")
        } catch { expect(true, "output cap bounds process memory") }
        let session = try runner.openSession(executable: "/bin/sh", arguments: ["-c", "printf '{\"id\":2,\"result\":{\"value\":2}}\\n{\"id\":1,'; sleep 0.05; printf '\"result\":{\"value\":1}}\\n'; sleep 2"], environment: ["PATH": "/bin:/usr/bin"])
        defer { session.terminate() }
        let first = try session.waitForResult(id: 1, timeout: 1)
        let second = try session.waitForResult(id: 2, timeout: 1)
        expect(first["value"] as? Int == 1 && second["value"] as? Int == 2, "handles split JSON lines and queued replies without rereading old responses")
        start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try session.waitForResult(id: 1, timeout: 0.1)
            expect(false, "consumed response must not be replayed")
        } catch { expect(ProcessInfo.processInfo.systemUptime - start < 1, "consumed response is removed and silence respects timeout") }
    }
}
