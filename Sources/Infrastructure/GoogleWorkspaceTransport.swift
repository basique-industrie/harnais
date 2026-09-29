import Domain
import Foundation

/// Limits credential-bearing requests to the APIs used by the Drive adapter.
public enum GoogleWorkspaceTransport {
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil, url.user == nil, url.password == nil, url.fragment == nil else { return false }
        let prefixes = ["www.googleapis.com": ["/drive/v3/files", "/upload/drive/v3/files"],
                        "sheets.googleapis.com": ["/v4/spreadsheets"], "docs.googleapis.com": ["/v1/documents"],
                        "slides.googleapis.com": ["/v1/presentations"]]
        return prefixes[url.host ?? ""]?.contains { url.path == $0 || url.path.hasPrefix($0 + "/") } == true
    }

    static func payload(_ response: HTTPResponse, request: URLRequest) throws -> Data {
        guard (200...299).contains(response.status) else {
            let api = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
            let error = api?["error"] as? [String: Any]
            let reasons = (error?["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String } ?? []
            let details = error?["details"] as? [[String: Any]] ?? []
            let disabled = reasons.contains("accessNotConfigured") || details.contains { $0["reason"] as? String == "SERVICE_DISABLED" }
            let suffix = String((error?["message"] as? String ?? "").prefix(600))
            let message: String
            if disabled { message = "Enable \(request.url?.host ?? "the Google API") in the Google Cloud project that owns the Harnais OAuth app, then retry. " + suffix }
            else if response.status == 403 { message = "Google denied this operation. Harnais write access covers files created or explicitly authorized for this app; reading a file does not grant write access. " + suffix }
            else if response.status == 409 || response.status == 412 { message = "The file changed or the edit conflicts with its current state. Read it again before retrying. " + suffix }
            else if response.status == 429 { message = "Google API rate limit reached. Wait before retrying." }
            else { message = "Google API returned HTTP \(response.status). " + suffix }
            throw HarnaisError.processFailed(message)
        }
        guard response.data.count <= 16 * 1024 * 1024 else { throw HarnaisError.processFailed("Google response exceeds 16 MB. Request smaller ranges or download the file.") }
        let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        if request.httpMethod == "PATCH", query.contains(where: { $0.name == "uploadType" && $0.value == "resumable" }) {
            guard let location = response.headers["location"], let url = URL(string: location), isAllowed(url), url.path == request.url?.path else {
                throw HarnaisError.processFailed("Invalid Google upload session destination.")
            }
            return try JSONSerialization.data(withJSONObject: ["uploadURL": location])
        }
        return response.data
    }
}
