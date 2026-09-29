import Darwin
import Domain
import Foundation

/// Pinned upstream servers retain their tool contracts and vendor-managed authentication.
public enum VendorMCPProcess {
    public static func process(kind: IntegrationKind) throws -> Process {
        guard let npx = BinaryLocator.which("npx") else { throw HarnaisError.processFailed("Install Node.js to use this connection.") }
        let package: String
        switch kind {
        case .aikido: package = "@aikidosec/mcp@1.0.17"
        case .excalidraw: package = "mcp-excalidraw-server@2.0.0"
        default: throw HarnaisError.processFailed("Unsupported local server.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", package]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = BinaryLocator.shellPath()
        // All coding accounts use the same vendor login, regardless of profile variables.
        if kind == .aikido {
            environment.removeValue(forKey: "AIKIDO_API_KEY")
            environment.removeValue(forKey: "AIKIDO_DEV_MODE")
            environment.removeValue(forKey: "AIKIDO_MCP_ALL_TOOLS")
        }
        process.environment = environment
        return process
    }

    public static func run(kind: IntegrationKind) throws {
        let process = try process(kind: kind)
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        Foundation.exit(process.terminationStatus)
    }

    public static func loginAikido(cancellation: OAuthCancellation? = nil, openURL: (URL) throws -> Void) throws {
        let client = try VendorMCPClient(process: process(kind: .aikido), cancellation: cancellation)
        defer { client.close() }
        _ = try client.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "Harnais", "version": "1"]])
        try client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        var opened = false
        let deadline = Date().addingTimeInterval(300)
        repeat {
            try cancellation?.check()
            let reply = try client.request("tools/call", ["name": "aikido_login", "arguments": [:]])
            let text = (reply["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard reply["isError"] as? Bool != true else { throw HarnaisError.oauthFailed("Aikido rejected the saved login. Sign in through Aikido's setup tool to renew it.") }
            if text.contains("Already signed in to Aikido and the credential is valid") { return }
            if !opened {
                guard let url = text.split(whereSeparator: \.isWhitespace).compactMap({ URL(string: String($0)) }).first(where: validLoginURL) else {
                    throw HarnaisError.oauthFailed("Aikido did not return a supported sign-in URL.")
                }
                try openURL(url)
                opened = true
            }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        throw HarnaisError.oauthFailed("Aikido sign-in timed out. Try again.")
    }

    public static func validLoginURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil
            && ["app.aikido.dev", "app.us.aikido.dev", "app.me.aikido.dev", "app.au.aikido.dev"].contains(url.host ?? "")
            && url.path == "/settings/integrations/ide/mcp"
    }
}

/// Small, bounded stdio client used only for the vendor login handshake.
private final class VendorMCPClient {
    let process: Process
    let input = Pipe()
    let output = Pipe()
    let cancellation: OAuthCancellation?
    var buffer = Data()
    var framing = MCPFraming.newline
    var id = 0
    init(process: Process, cancellation: OAuthCancellation?) throws {
        self.process = process; self.cancellation = cancellation
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
    func close() { if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
    func send(_ value: [String: Any]) throws {
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: value) + Data([10]))
    }
    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        id += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            try cancellation?.check()
            while let message = MCPStdio.pullMessage(from: &buffer, framing: &framing) {
                if let reply = try JSONSerialization.jsonObject(with: message) as? [String: Any], reply["id"] as? Int == id {
                    guard let result = reply["result"] as? [String: Any] else { throw HarnaisError.oauthFailed("Aikido could not complete the login request.") }
                    return result
                }
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 250) > 0 {
                let bytes = output.fileHandleForReading.availableData
                guard !bytes.isEmpty else { throw HarnaisError.oauthFailed("Aikido's server stopped during sign-in.") }
                buffer.append(bytes)
                guard buffer.count < 1_048_576 else { throw HarnaisError.oauthFailed("Aikido returned an oversized login response.") }
            }
        }
        throw HarnaisError.oauthFailed("Aikido did not respond. Check Node.js and your network connection.")
    }
}
