import Domain
import Foundation

public enum SharedMCPURL {
    public static func parse(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw HarnaisError.oauthFailed("Enter a valid MCP server URL.")
        }
        try validate(url)
        return url
    }

    public static func validate(_ url: URL) throws {
        let local = ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? "")
        guard url.host != nil, url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && local) else {
            throw HarnaisError.oauthFailed("Use HTTPS, or HTTP for a local server. Put credentials in the login fields, not in the URL.")
        }
    }
}

public enum OAuthResource {
    /// A service can advertise an origin or parent path as its canonical resource.
    /// The token must still belong to this endpoint's origin and path boundary.
    public static func contains(endpoint: URL, resource: String) -> Bool {
        guard let scope = try? SharedMCPURL.parse(resource),
              scope.scheme == endpoint.scheme, scope.host == endpoint.host,
              (scope.port ?? (scope.scheme == "https" ? 443 : 80)) == (endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80)),
              scope.query == nil || scope.query == endpoint.query else { return false }
        let path = scope.standardized.path
        let target = endpoint.standardized.path
        return path.isEmpty || path == "/" || target == path || target.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }
}
