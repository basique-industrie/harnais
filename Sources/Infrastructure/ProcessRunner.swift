import Domain
import Darwin
import Foundation

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public struct ProcessRunner: Sendable {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        workingDirectory: URL? = nil,
        input: String? = nil,
        maximumOutputBytes: Int = 64 * 1024 * 1024,
        mergeStandardError: Bool = true
    ) throws -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = mergeStandardError ? stdout : FileHandle.nullDevice
        process.standardInput = stdin
        process.currentDirectoryURL = workingDirectory
        try process.run()
        defer {
            try? stdin.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        try stdout.fileHandleForWriting.close()
        let readFD = stdout.fileHandleForReading.fileDescriptor
        let writeFD = stdin.fileHandleForWriting.fileDescriptor
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        let inputData = Data((input ?? "").utf8)
        var offset = 0
        var inputOpen = true
        var outputOpen = true
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while outputOpen || process.isRunning {
            if inputOpen && offset == inputData.count {
                try stdin.fileHandleForWriting.close()
                inputOpen = false
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw HarnaisError.processFailed("Timed out running \(executable)")
            }
            var descriptors = [
                pollfd(fd: outputOpen ? readFD : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: inputOpen ? writeFD : -1, events: Int16(POLLOUT), revents: 0),
            ]
            let ready = poll(&descriptors, 2, Int32(min(20, max(1, remaining * 1000))))
            if ready < 0 && errno != EINTR {
                throw HarnaisError.processFailed("Could not read process output.")
            }
            if outputOpen && descriptors[0].revents != 0 {
                let count = Darwin.read(readFD, &bytes, bytes.count)
                if count > 0 {
                    output.append(contentsOf: bytes.prefix(count))
                    guard output.count <= maximumOutputBytes else {
                        throw HarnaisError.processFailed("Process output exceeded \(maximumOutputBytes) bytes.")
                    }
                } else if count == 0 {
                    outputOpen = false
                } else if errno != EAGAIN && errno != EINTR {
                    throw HarnaisError.processFailed("Could not read process output.")
                }
            }
            if inputOpen && descriptors[1].revents != 0 {
                let count = inputData.withUnsafeBytes { buffer in
                    Darwin.write(writeFD, buffer.baseAddress!.advanced(by: offset), min(16 * 1024, inputData.count - offset))
                }
                if count > 0 { offset += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR {
                    let failure = errno
                    try stdin.fileHandleForWriting.close()
                    inputOpen = false
                    if failure != EPIPE { throw HarnaisError.processFailed("Could not write process input.") }
                }
            }
        }
        return ProcessResult(exitCode: process.terminationStatus, output: String(data: output, encoding: .utf8) ?? "")
    }

    /// Long-lived stdin/stdout session for line-delimited JSON-RPC (Codex app-server).
    public func openSession(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> LineProcessSession {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        return LineProcessSession(process: process, stdin: stdin, stdout: stdout)
    }
}
