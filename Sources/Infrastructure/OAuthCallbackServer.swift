import Domain
import Foundation
import Network

/// Loopback HTTP listener for OAuth redirects at `http://127.0.0.1:<port>/callback`.
public final class OAuthCallbackServer: @unchecked Sendable {
    public let port: UInt16
    private var listener: NWListener?
    private let lock = NSLock()
    private var result: Result<(code: String, state: String), Error>?
    private let done = DispatchSemaphore(value: 0)

    public init(port: UInt16 = IntegrationOAuth.callbackPort) {
        self.port = port
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HarnaisError.callbackPortBusy
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        let failed = FailedFlag()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed:
                failed.mark()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: DispatchQueue(label: "harnais.oauth.callback"))
        if ready.wait(timeout: .now() + 2) == .timedOut {
            listener.cancel()
            throw HarnaisError.callbackPortBusy
        }
        if failed.isSet {
            listener.cancel()
            throw HarnaisError.callbackPortBusy
        }
    }

    public func waitForCode(timeout: TimeInterval = 300) throws -> (code: String, state: String) {
        if done.wait(timeout: .now() + timeout) == .timedOut {
            stop()
            throw HarnaisError.oauthFailed("Sign-in timed out. Try again from Harnais.")
        }
        stop()
        switch lock.withLock({ result }) {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case nil:
            throw HarnaisError.oauthFailed("Sign-in did not return a code.")
        }
    }

    public func cancel() {
        lock.withLock {
            if result == nil { result = .failure(HarnaisError.oauthFailed("Sign-in cancelled.")) }
        }
        done.signal()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "harnais.oauth.conn"))
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if let headerEnd = next.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(data: next.subdata(in: next.startIndex..<headerEnd.lowerBound), encoding: .utf8) ?? ""
                self.finish(connection: connection, request: header)
                return
            }
            if isComplete || error != nil {
                self.finish(connection: connection, request: String(data: next, encoding: .utf8) ?? "")
                return
            }
            self.receive(connection, buffer: next)
        }
    }

    private func finish(connection: NWConnection, request: String) {
        let line = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? request
        let path = Self.requestPath(from: line)
        let query = Self.queryItems(from: path)
        let html: String
        if let error = query["error"] {
            let description = query["error_description"] ?? error
            finishResult(.failure(HarnaisError.oauthFailed(description.replacingOccurrences(of: "+", with: " "))))
            html = Self.page("Could not sign in. Return to Harnais and try again.")
        } else if let code = query["code"], let state = query["state"] {
            finishResult(.success((code, state)))
            html = Self.page("Signed in. You can close this window and return to Harnais.")
        } else {
            html = Self.page("Waiting for Harnais…")
        }
        let body = Data(html.utf8)
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: text/html; charset=utf-8\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var payload = Data(response.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finishResult(_ value: Result<(code: String, state: String), Error>) {
        lock.lock()
        if result == nil {
            result = value
            lock.unlock()
            done.signal()
        } else {
            lock.unlock()
        }
    }

    public static func requestPath(from requestLine: String) -> String {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return "" }
        return String(parts[1])
    }

    public static func queryItems(from path: String) -> [String: String] {
        guard let question = path.firstIndex(of: "?") else { return [:] }
        let query = String(path[path.index(after: question)...])
        var values: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pieces.first else { continue }
            let raw = pieces.count > 1 ? String(pieces[1]) : ""
            values[Self.decode(String(key))] = Self.decode(raw)
        }
        return values
    }

    static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? value
    }

    static func page(_ message: String) -> String {
        """
        <!doctype html>
        <meta charset="utf-8">
        <title>Harnais</title>
        <body style="font-family:system-ui,-apple-system,sans-serif;padding:48px;color:#27272a;background:#fafafa">
        <p style="font-size:16px">\(message)</p>
        </body>
        """
    }
}

private final class FailedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func mark() {
        lock.withLock { value = true }
    }
}
