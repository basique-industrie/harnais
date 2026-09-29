import Domain
import Foundation

/// Each provider owns its MCP session. Only the upstream credential is shared.
public struct MCPHTTPProxy: Sendable {
    public var oauth: MCPOAuthClient
    public var credentials: IntegrationCredentialStore

    public init(oauth: MCPOAuthClient = MCPOAuthClient(), credentials: IntegrationCredentialStore = IntegrationCredentialStore()) {
        self.oauth = oauth
        self.credentials = credentials
    }

    public func run(connection: IntegrationConnection) throws {
        let bridge = MCPHTTPBridge(connection: connection, oauth: oauth, credentials: credentials)
        defer { bridge.close() }
        var framing = MCPFraming.newline
        var buffer = Data()
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            guard buffer.count <= 32 * 1024 * 1024 else {
                throw HarnaisError.processFailed("MCP input exceeded the message size limit.")
            }
            while let message = MCPStdio.pullMessage(from: &buffer, framing: &framing) {
                bridge.submit(message, framing: framing)
            }
        }
    }
}

/// The serial delegate queue owns all mutable state and stdout writes. Reading
/// stdin continues while an HTTP stream waits for a server-initiated response.
private final class MCPHTTPBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let connection: IntegrationConnection
    let oauth: MCPOAuthClient
    let credentials: IntegrationCredentialStore
    let queue = DispatchQueue(label: "com.jean.harnais.mcp-http")
    private var sessionID: String?
    private var protocolVersion: String?
    private var transfers: [Int: Transfer] = [:]
    private var listening = false
    private var closed = false
    private lazy var session: URLSession = {
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        callbacks.underlyingQueue = queue
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 86400
        return URLSession(configuration: configuration, delegate: self, delegateQueue: callbacks)
    }()

    struct Transfer {
        var message: Data?
        var framing: MCPFraming
        var accessToken: String
        var retried: Bool
        var status = 0
        var sse = false
        var buffer = Data()
        var deliveredResponse = false
    }

    init(connection: IntegrationConnection, oauth: MCPOAuthClient, credentials: IntegrationCredentialStore) {
        self.connection = connection
        self.oauth = oauth
        self.credentials = credentials
    }

    func submit(_ message: Data, framing: MCPFraming) {
        queue.async { [self] in
            guard !closed else { return }
            send(message, framing: framing)
            if Self.object(message)?["method"] as? String == "notifications/initialized", !listening {
                listening = true
                send(nil, framing: framing)
            }
        }
    }

    func close() {
        queue.sync {
            closed = true
            session.invalidateAndCancel()
            transfers.removeAll()
        }
    }

    private func send(_ message: Data?, framing: MCPFraming, rejected: String? = nil) {
        do {
            let tokens = connection.kind.authKind == .none ? nil : try credentials.authorizedTokens(for: connection, rejectedAccessToken: rejected, refresh: oauth.refresh)
            let endpoint = IntegrationDebug.mcpURLOverride ?? connection.mcpURL
            try SharedMCPURL.validate(endpoint)
            var request = URLRequest(url: endpoint)
            request.httpMethod = message == nil ? "GET" : "POST"
            request.httpBody = message
            request.setValue(message == nil ? "text/event-stream" : "application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if message != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let tokens { request.setValue("\(tokens.tokenType) \(tokens.accessToken)", forHTTPHeaderField: "Authorization") }
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
            if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
            let task = session.dataTask(with: request)
            transfers[task.taskIdentifier] = Transfer(message: message, framing: framing, accessToken: tokens?.accessToken ?? "", retried: rejected != nil)
            task.resume()
        } catch {
            fail(message, framing: framing, description: "Shared login is unavailable. Open this connection in Harnais and sign in again.")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never send an upstream credential to a redirect destination.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, var transfer = transfers[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        transfer.status = http.statusCode
        transfer.sse = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream")
        if (200...299).contains(http.statusCode), let id = http.value(forHTTPHeaderField: "MCP-Session-Id") {
            sessionID = id
        }
        transfers[dataTask.taskIdentifier] = transfer
        completionHandler((200...299).contains(http.statusCode) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var transfer = transfers[dataTask.taskIdentifier], (200...299).contains(transfer.status) else { return }
        transfer.buffer.append(data)
        if transfer.buffer.count > 32 * 1024 * 1024 {
            transfers.removeValue(forKey: dataTask.taskIdentifier)
            dataTask.cancel()
            fail(transfer.message, framing: transfer.framing, description: "The MCP server response exceeded the message size limit.")
            return
        }
        if transfer.sse {
            while let range = transfer.buffer.range(of: Data("\r\n\r\n".utf8)) ?? transfer.buffer.range(of: Data("\n\n".utf8)) {
                let event = transfer.buffer.subdata(in: transfer.buffer.startIndex..<range.upperBound)
                transfer.buffer.removeSubrange(transfer.buffer.startIndex..<range.upperBound)
                for message in MCPStdio.parseSSE(event) {
                    deliver(message, transfer: &transfer)
                }
            }
        }
        transfers[dataTask.taskIdentifier] = transfer
        if transfer.deliveredResponse { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard var transfer = transfers.removeValue(forKey: task.taskIdentifier), !closed else { return }
        if transfer.status == 401, !transfer.retried, connection.kind.authKind != .none {
            send(transfer.message, framing: transfer.framing, rejected: transfer.accessToken)
            return
        }
        if transfer.deliveredResponse { return }
        guard (200...299).contains(transfer.status) else {
            // The optional GET stream can be unsupported. It must not break POSTs.
            if transfer.message == nil { return }
            let description: String
            switch transfer.status {
            case 401: description = "Sign in again to this shared connection in Harnais."
            case 403: description = "The service denied access. Check this connection's permissions in Harnais."
            case 404: description = "The MCP session expired or the endpoint was not found. Restart this MCP connection in your coding tool."
            default: description = "The shared MCP server returned HTTP \(transfer.status). Check its settings in Harnais."
            }
            fail(transfer.message, framing: transfer.framing, description: description)
            return
        }
        if error != nil {
            fail(transfer.message, framing: transfer.framing, description: "The shared MCP connection was interrupted. Reconnect in your coding tool.")
        } else if !transfer.sse, !transfer.buffer.isEmpty {
            deliver(transfer.buffer, transfer: &transfer)
        } else if transfer.message != nil, Self.object(transfer.message!)?["id"] != nil {
            fail(transfer.message, framing: transfer.framing, description: "The MCP server closed the response without a result.")
        }
    }

    private func deliver(_ message: Data, transfer: inout Transfer) {
        guard let object = Self.object(message), object["jsonrpc"] as? String == "2.0" else { return }
        if let original = transfer.message, let request = Self.object(original),
           let id = request["id"], let responseID = object["id"],
           String(describing: id) == String(describing: responseID),
           object["result"] != nil || object["error"] != nil {
            transfer.deliveredResponse = true
            if request["method"] as? String == "initialize",
               let result = object["result"] as? [String: Any], let version = result["protocolVersion"] as? String {
                protocolVersion = version
            }
        }
        if let compact = try? JSONSerialization.data(withJSONObject: object) {
            try? FileHandle.standardOutput.write(contentsOf: MCPStdio.encode(compact, framing: transfer.framing))
        }
    }

    private func fail(_ original: Data?, framing: MCPFraming, description: String) {
        guard let original, let object = Self.object(original), let id = object["id"], object["method"] != nil else { return }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": description]]
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            try? FileHandle.standardOutput.write(contentsOf: MCPStdio.encode(data, framing: framing))
        }
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum MCPFraming: Sendable {
    case newline
    case contentLength
}

enum MCPStdio {
    static func pullMessage(from buffer: inout Data, framing: inout MCPFraming) -> Data? {
        if buffer.starts(with: Data("Content-Length:".utf8)) || buffer.starts(with: Data("content-length:".utf8)) {
            framing = .contentLength
            return pullContentLength(from: &buffer)
        }
        if let index = buffer.firstIndex(of: 0x0A) {
            var line = buffer.subdata(in: buffer.startIndex..<index)
            buffer.removeSubrange(buffer.startIndex...index)
            if line.last == 0x0D { line.removeLast() }
            if line.isEmpty { return pullMessage(from: &buffer, framing: &framing) }
            return line
        }
        return nil
    }

    static func pullContentLength(from buffer: inout Data) -> Data? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) ?? buffer.range(of: Data("\n\n".utf8)) else {
            return nil
        }
        let header = String(data: buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound), encoding: .utf8) ?? ""
        var length: Int?
        for raw in header.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lowered = line.lowercased()
            if lowered.hasPrefix("content-length:") {
                let value = line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces)
                length = value.flatMap(Int.init)
            }
        }
        guard let length, length >= 0, length <= 32 * 1024 * 1024 else { return nil }
        let start = headerEnd.upperBound
        let end = start + length
        guard buffer.endIndex >= end else { return nil }
        let body = buffer.subdata(in: start..<end)
        buffer.removeSubrange(buffer.startIndex..<end)
        return body
    }

    static func encode(_ message: Data, framing: MCPFraming) -> Data {
        switch framing {
        case .newline:
            var data = message
            if data.last != 0x0A { data.append(0x0A) }
            return data
        case .contentLength:
            var data = Data("Content-Length: \(message.count)\r\n\r\n".utf8)
            data.append(message)
            return data
        }
    }

    static func parseSSE(_ data: Data) -> [Data] {
        let text = (String(data: data, encoding: .utf8) ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var messages: [Data] = []
        var payload: [String] = []
        func flush() {
            guard !payload.isEmpty else { return }
            let joined = payload.joined(separator: "\n")
            if let body = joined.data(using: .utf8) {
                messages.append(body)
            }
            payload.removeAll()
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("data:") {
                payload.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        return messages
    }
}
