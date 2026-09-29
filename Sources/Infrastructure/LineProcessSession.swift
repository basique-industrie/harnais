import Domain
import Darwin
import Foundation

public final class LineProcessSession: @unchecked Sendable {
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private var buffer = Data()
    private var pending: [Int: [String: Any]] = [:]

    init(process: Process, stdin: Pipe, stdout: Pipe) {
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
    }

    deinit {
        terminate()
    }

    public func sendJSON(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try stdin.fileHandleForWriting.write(contentsOf: data)
        try stdin.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
    }

    public func waitForResult(id: Int, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                let line = Data(buffer[start..<newline])
                start = buffer.index(after: newline)
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let responseID = QuotaReset.jsonRPCID(json["id"])
                else { continue }
                pending[responseID] = json
                guard pending.count <= 128 else {
                    terminate()
                    throw HarnaisError.processFailed("Too many pending process responses.")
                }
            }
            if start != buffer.startIndex { buffer.removeSubrange(..<start) }
            if let json = pending.removeValue(forKey: id) {
                if let result = json["result"] as? [String: Any] { return result }
                if json["error"] != nil { throw HarnaisError.processFailed("Codex could not read its usage limits.") }
            }
            var descriptor = pollfd(fd: stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            let ready = poll(&descriptor, 1, Int32(min(100, max(1, remaining * 1000))))
            if ready <= 0 { continue }
            let available = stdout.fileHandleForReading.availableData
            guard !available.isEmpty else {
                throw HarnaisError.processFailed("Codex stopped before reporting its limits.")
            }
            buffer.append(available)
            guard buffer.count <= 4 * 1024 * 1024 else {
                terminate()
                throw HarnaisError.processFailed("Process response exceeded 4 MB.")
            }
        }
        terminate()
        throw HarnaisError.processFailed("Timed out waiting for process \(id)")
    }

    public func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}
