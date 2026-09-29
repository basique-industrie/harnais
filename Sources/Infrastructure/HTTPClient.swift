import Domain
import Foundation

struct HTTPResponse: Sendable {
    var data: Data
    var status: Int
    var headers: [String: String]
}

enum HTTPClient {
    static func getBlocking(_ request: URLRequest) throws -> (Data, Int) {
        let response = try send(request)
        return (response.data, response.status)
    }

    static func sendBlocking(_ request: URLRequest, timeout: TimeInterval = 16) throws -> (Data, Int) {
        let response = try send(request, timeout: timeout)
        return (response.data, response.status)
    }

    static func send(_ request: URLRequest, timeout: TimeInterval = 20, followRedirects: Bool = true,
                     maxResponseBytes: Int? = nil) throws -> HTTPResponse {
        if let maxResponseBytes {
            return try BoundedHTTPTransfer.send(request, timeout: timeout, followRedirects: followRedirects, limit: maxResponseBytes)
        }
        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral, delegate: followRedirects ? nil : RefuseHTTPRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            if let fields = http?.allHeaderFields {
                for (key, value) in fields {
                    headers["\(key)".lowercased()] = "\(value)"
                }
            }
            box.store(
                data: data,
                status: http?.statusCode ?? 0,
                headers: headers,
                error: error
            )
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw HarnaisError.processFailed("Request timed out.")
        }
        if let error = box.error { throw error }
        return HTTPResponse(data: box.data ?? Data(), status: box.status, headers: box.headers)
    }

    static func postForm(
        _ url: URL,
        fields: [String: String],
        timeout: TimeInterval = 20,
        followRedirects: Bool = true
    ) throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody(fields)
        return try send(request, timeout: timeout, followRedirects: followRedirects)
    }

    static func postJSON(
        _ url: URL,
        object: [String: Any],
        headers: [String: String] = [:],
        timeout: TimeInterval = 20,
        followRedirects: Bool = true
    ) throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        return try send(request, timeout: timeout, followRedirects: followRedirects)
    }

    static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: ":#[]@!$&'()*+,;="))
        let body = fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?
    private var storedStatus = 0
    private var storedHeaders: [String: String] = [:]
    private var storedError: Error?

    var data: Data? { lock.withLock { storedData } }
    var status: Int { lock.withLock { storedStatus } }
    var headers: [String: String] { lock.withLock { storedHeaders } }
    var error: Error? { lock.withLock { storedError } }

    func store(data: Data?, status: Int, headers: [String: String], error: Error?) {
        lock.withLock {
            storedData = data
            storedStatus = status
            storedHeaders = headers
            storedError = error
        }
    }
}

private final class RefuseHTTPRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
