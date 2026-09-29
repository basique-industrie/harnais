#if DEBUG
import Foundation
@testable import Infrastructure

enum HTTPTransferTests {
    static func run(expect: (Bool, String) -> Void) throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponseFixture.self]
        func send(_ path: String, limit: Int = 8, timeout: TimeInterval = 2) throws -> HTTPResponse {
            try BoundedHTTPTransfer.send(URLRequest(url: URL(string: "https://fixture.invalid/" + path)!),
                                         timeout: timeout, followRedirects: false, limit: limit, configuration: configuration)
        }
        let exact = try send("exact")
        expect(exact.data == Data("12345678".utf8), "bounded HTTP accepts the exact byte limit across chunks")
        expect(exact.status == 201 && exact.headers["x-fixture"] == "present", "bounded HTTP preserves status and normalizes headers")
        for path in ["declared-large", "stream-large"] {
            do { _ = try send(path); expect(false, "bounded HTTP rejects \(path)") }
            catch { expect(error.localizedDescription.contains("exceeds"), "bounded HTTP rejects \(path) with a size error") }
        }
        expect(try send("empty", limit: 0).data.isEmpty, "bounded HTTP accepts an empty response with zero limit")
        do { _ = try send("error"); expect(false, "bounded HTTP reports transport errors") }
        catch { expect((error as NSError).code == URLError.networkConnectionLost.rawValue, "bounded HTTP preserves transport errors") }
        let start = ContinuousClock.now
        do { _ = try send("stall", timeout: 0.05); expect(false, "bounded HTTP times out") }
        catch { expect(error.localizedDescription.contains("timed out") && start.duration(to: .now) < .seconds(1), "bounded HTTP cancels a stalled request within its timeout") }
        do { _ = try send("empty", limit: -1); expect(false, "bounded HTTP rejects negative limits") }
        catch { expect(true, "bounded HTTP rejects negative limits") }
    }
}

private final class ResponseFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        if path == "stall" { return }
        if path == "error" { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        var headers = ["X-Fixture": "present"]
        if path == "declared-large" { headers["Content-Length"] = "1000000000" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if path == "exact" || path == "stream-large" {
            client?.urlProtocol(self, didLoad: Data("1234".utf8))
            client?.urlProtocol(self, didLoad: Data("5678".utf8))
            if path == "stream-large" { client?.urlProtocol(self, didLoad: Data("9".utf8)) }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
