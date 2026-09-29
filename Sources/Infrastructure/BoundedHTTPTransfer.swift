import Domain
import Foundation

/// Stops oversized downloads before URLSession retains the entire response.
final class BoundedHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let followRedirects: Bool
    private let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var response = HTTPResponse(data: Data(), status: 0, headers: [:])
    private var failure: Error?

    private init(limit: Int, followRedirects: Bool) {
        self.limit = limit
        self.followRedirects = followRedirects
    }

    static func send(_ request: URLRequest, timeout: TimeInterval, followRedirects: Bool, limit: Int,
                     configuration: URLSessionConfiguration = .ephemeral) throws -> HTTPResponse {
        guard limit >= 0 else { throw HarnaisError.processFailed("Invalid response size limit.") }
        let transfer = BoundedHTTPTransfer(limit: limit, followRedirects: followRedirects)
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request).resume()
        guard transfer.completed.wait(timeout: .now() + timeout) == .success else {
            throw HarnaisError.processFailed("Request timed out.")
        }
        return try transfer.lock.withLock {
            if let failure = transfer.failure { throw failure }
            return transfer.response
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive incoming: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let allowed = lock.withLock {
            if incoming.expectedContentLength > Int64(limit) { failLimit(); return false }
            if let http = incoming as? HTTPURLResponse {
                response.status = http.statusCode
                for (key, value) in http.allHeaderFields { response.headers["\(key)".lowercased()] = "\(value)" }
            }
            return true
        }
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock {
            guard failure == nil else { return true }
            guard data.count <= limit - response.data.count else { failLimit(); return true }
            response.data.append(data)
            return false
        }
        if overflow { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { if failure == nil { failure = error } }
        completed.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(followRedirects ? request : nil)
    }

    /// Called while holding the lock. Release any partial body on failure.
    private func failLimit() {
        failure = HarnaisError.processFailed("Response exceeds the \(limit / 1024 / 1024) MB limit. Request smaller ranges or a smaller file.")
        response.data = Data()
    }
}
