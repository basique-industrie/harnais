import Domain
import Foundation

struct AuthServerMetadata: Sendable {
    var issuer: String
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var registrationEndpoint: URL?
    var scopesSupported: [String]
    var requestedScopes: [String]? = nil
    var resource: String? = nil
}

public struct MCPOAuthClient: Sendable {
    public var cancellation: OAuthCancellation?
    public var callbackPort: UInt16
    public var redirectURI: String

    public init(
        callbackPort: UInt16 = IntegrationOAuth.callbackPort,
        redirectURI: String = IntegrationOAuth.redirectURI
    ) {
        self.callbackPort = callbackPort
        self.redirectURI = redirectURI
    }

    public func authorize(
        kind: IntegrationKind,
        endpoint: URL? = nil,
        client: OAuthClientRecord?,
        openURL: (URL) throws -> Void,
        makeServer: () throws -> OAuthCallbackServer = { OAuthCallbackServer() }
    ) throws -> OAuthTokenSet {
        try cancellation?.check()
        let mcpURL = endpoint ?? kind.mcpURL
        try SharedMCPURL.validate(mcpURL)
        let discovery: AuthServerMetadata
        if kind == .outlook {
            discovery = AuthServerMetadata(issuer: "https://login.microsoftonline.com/common/v2.0",
                authorizationEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
                tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                registrationEndpoint: nil, scopesSupported: kind.defaultScopes)
        } else if kind == .gmail || kind == .googleDrive {
            discovery = AuthServerMetadata(issuer: "https://accounts.google.com",
                authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                registrationEndpoint: nil, scopesSupported: kind.defaultScopes)
        } else {
            discovery = try discover(mcpURL: mcpURL)
        }
        var clientId = client?.clientId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var clientSecret = client?.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        if clientSecret?.isEmpty == true { clientSecret = nil }

        if clientId.isEmpty {
            guard let registration = discovery.registrationEndpoint else {
                throw HarnaisError.oauthClientRequired(kind.displayName)
            }
            let registered = try register(at: registration, kind: kind)
            clientId = registered.clientId
            clientSecret = registered.clientSecret
        }

        let pkce = PKCE.make()
        let scopes = client?.scopes ?? (kind.defaultScopes.isEmpty ? discovery.requestedScopes ?? [] : kind.defaultScopes)
        let resource = discovery.resource ?? mcpURL.absoluteString
        let server = try makeServer()
        try cancellation?.check()
        try server.start()
        cancellation?.install { server.cancel() }
        defer { cancellation?.clear(); server.stop() }

        var authorize = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if !scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        if kind != .outlook && kind != .gmail && kind != .googleDrive { items.append(URLQueryItem(name: "resource", value: resource)) }
        if kind == .googleDrive || kind == .gmail {
            items.append(URLQueryItem(name: "access_type", value: "offline"))
            items.append(URLQueryItem(name: "prompt", value: "consent"))
        }
        authorize.queryItems = items
        guard let authorizeURL = authorize.url else {
            throw HarnaisError.oauthFailed("Could not build the sign-in URL.")
        }
        try cancellation?.check()
        try openURL(authorizeURL)
        let callback = try server.waitForCode()
        guard callback.state == pkce.state else {
            throw HarnaisError.oauthFailed("OAuth state did not match. Try signing in again.")
        }
        try cancellation?.check()
        let tokens = try exchange(
            mcpURL: URL(string: resource)!,
            metadata: discovery,
            clientId: clientId,
            clientSecret: clientSecret,
            code: callback.code,
            verifier: pkce.verifier,
            includeResource: kind != .outlook && kind != .gmail && kind != .googleDrive
        )
        try cancellation?.check()
        return tokens
    }

    public func registerClient(kind: IntegrationKind, appName: String = "Harnais") throws -> OAuthClientRecord {
        guard kind == .atlassian else {
            throw HarnaisError.oauthFailed("Use the service's app console to register this integration.")
        }
        let metadata = try discover(mcpURL: kind.mcpURL)
        guard let endpoint = metadata.registrationEndpoint else {
            throw HarnaisError.oauthFailed("This service no longer advertises automatic client registration.")
        }
        return try register(at: endpoint, kind: kind, appName: appName)
    }

    public func refresh(_ tokens: OAuthTokenSet) throws -> OAuthTokenSet {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw HarnaisError.oauthFailed("Sign in again. This connection has no refresh token.")
        }
        guard let endpoint = tokens.tokenEndpoint, let url = URL(string: endpoint) else {
            throw HarnaisError.oauthFailed("Missing token endpoint.")
        }
        try SharedMCPURL.validate(url)
        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        if let clientId = tokens.clientId { fields["client_id"] = clientId }
        if let secret = tokens.clientSecret, !secret.isEmpty {
            fields["client_secret"] = secret
        }
        if let resource = tokens.resource { fields["resource"] = resource }
        let response = try HTTPClient.postForm(url, fields: fields, followRedirects: false)
        var next = try parseTokens(response, fallbackClientId: tokens.clientId, fallbackSecret: tokens.clientSecret)
        if next.refreshToken == nil { next.refreshToken = refreshToken }
        next.tokenEndpoint = tokens.tokenEndpoint
        next.authorizationEndpoint = tokens.authorizationEndpoint
        next.resource = tokens.resource ?? next.resource
        next.clientId = tokens.clientId
        next.clientSecret = tokens.clientSecret
        return next
    }

    func discover(mcpURL: URL) throws -> AuthServerMetadata {
        var metadataURL = optionalMetadataURL(from: mcpURL)
        var challengeScopes: [String]?
        if metadataURL == nil {
            var probe = URLRequest(url: mcpURL)
            probe.httpMethod = "GET"
            probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            let response = try HTTPClient.send(probe, timeout: 12, followRedirects: false)
            if let header = response.headers["www-authenticate"] {
                metadataURL = WWWAuthenticate.resourceMetadataURL(from: header)
                challengeScopes = WWWAuthenticate.parameters(from: header)["scope"].map { $0.split(separator: " ").map(String.init) }
            }
        }
        if metadataURL == nil {
            for candidate in wellKnownProtectedResourceURLs(for: mcpURL) {
                if let _ = try? fetchJSON(candidate) {
                    metadataURL = candidate
                    break
                }
            }
        }
        guard let metadataURL, let prm = try? fetchJSON(metadataURL) else {
            return try fetchAuthServerMetadata(issuer: fallbackIssuer(for: mcpURL))
        }
        if let resource = prm["resource"] as? String, !OAuthResource.contains(endpoint: mcpURL, resource: resource) {
            throw HarnaisError.oauthFailed("The server's authorization metadata identifies a different resource.")
        }
        let servers = prm["authorization_servers"] as? [String] ?? []
        let issuer = servers.first.flatMap(URL.init(string:)) ?? fallbackIssuer(for: mcpURL)
        var metadata = try fetchAuthServerMetadata(issuer: issuer)
        metadata.requestedScopes = challengeScopes ?? (prm["scopes_supported"] as? [String])
        metadata.resource = prm["resource"] as? String
        return metadata
    }

    public func wellKnownProtectedResourceURLs(for mcpURL: URL) -> [URL] {
        guard let base = origin(of: mcpURL) else { return [] }
        let path = mcpURL.path.hasPrefix("/") ? mcpURL.path : "/\(mcpURL.path)"
        var urls: [URL] = []
        if path.count > 1 {
            urls.append(contentsOf: join(base, "/.well-known/oauth-protected-resource\(path)"))
        }
        urls.append(contentsOf: join(base, "/.well-known/oauth-protected-resource"))
        return urls
    }

    func wellKnownAuthURLs(for issuer: URL) -> [URL] {
        guard let base = origin(of: issuer) else { return [] }
        let extra = issuer.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var urls: [URL] = []
        if !extra.isEmpty {
            urls.append(contentsOf: join(base, "/.well-known/oauth-authorization-server/\(extra)"))
            urls.append(contentsOf: join(base, "/.well-known/openid-configuration/\(extra)"))
            urls.append(contentsOf: join(base, "/\(extra)/.well-known/openid-configuration"))
        }
        urls.append(contentsOf: join(base, "/.well-known/oauth-authorization-server"))
        urls.append(contentsOf: join(base, "/.well-known/openid-configuration"))
        return urls
    }

    private func origin(of url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    private func join(_ base: URL, _ path: String) -> [URL] {
        let root = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        if let url = URL(string: root + path) {
            return [url]
        }
        return []
    }

    private func optionalMetadataURL(from mcpURL: URL) -> URL? {
        _ = mcpURL
        return nil
    }

    private func fallbackIssuer(for mcpURL: URL) -> URL {
        switch mcpURL.host {
        case "drivemcp.googleapis.com":
            URL(string: "https://accounts.google.com/")!
        case "mcp.slack.com":
            URL(string: "https://mcp.slack.com/")!
        case "mcp.atlassian.com":
            URL(string: "https://auth.atlassian.com/")!
        default:
            mcpURL
        }
    }

    func fetchAuthServerMetadata(issuer: URL) throws -> AuthServerMetadata {
        let candidates = wellKnownAuthURLs(for: issuer)
        var lastError: Error = HarnaisError.oauthFailed("Could not load OAuth metadata.")
        for url in candidates {
            do {
                let json = try fetchJSON(url)
                return try metadata(from: json, issuer: issuer)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func metadata(from json: [String: Any], issuer: URL) throws -> AuthServerMetadata {
        let expectedIssuer = issuer.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let declared = json["issuer"] as? String,
           declared.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != expectedIssuer {
            throw HarnaisError.oauthFailed("The authorization server returned a different issuer.")
        }
        guard let authorization = (json["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (json["token_endpoint"] as? String).flatMap(URL.init(string:))
        else {
            throw HarnaisError.oauthFailed("OAuth metadata is missing endpoints.")
        }
        try SharedMCPURL.validate(authorization)
        try SharedMCPURL.validate(token)
        if let registration = (json["registration_endpoint"] as? String).flatMap(URL.init(string:)) {
            try SharedMCPURL.validate(registration)
        }
        return AuthServerMetadata(
            issuer: json["issuer"] as? String ?? issuer.absoluteString,
            authorizationEndpoint: authorization,
            tokenEndpoint: token,
            registrationEndpoint: (json["registration_endpoint"] as? String).flatMap(URL.init(string:)),
            scopesSupported: json["scopes_supported"] as? [String] ?? []
        )
    }

    private func register(at url: URL, kind: IntegrationKind, appName: String = "Harnais") throws -> OAuthClientRecord {
        let body: [String: Any] = [
            "client_name": appName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
        ]
        let response = try HTTPClient.postJSON(url, object: body, followRedirects: false)
        guard (200...299).contains(response.status),
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let clientId = json["client_id"] as? String
        else {
            throw HarnaisError.oauthFailed("\(kind.displayName) did not accept client registration.")
        }
        return OAuthClientRecord(clientId: clientId, clientSecret: json["client_secret"] as? String)
    }

    private func exchange(
        mcpURL: URL,
        metadata: AuthServerMetadata,
        clientId: String,
        clientSecret: String?,
        code: String,
        verifier: String,
        includeResource: Bool
    ) throws -> OAuthTokenSet {
        var fields = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ]
        if let clientSecret, !clientSecret.isEmpty {
            fields["client_secret"] = clientSecret
        }
        if includeResource {
            fields["resource"] = mcpURL.absoluteString
        }
        let response = try HTTPClient.postForm(metadata.tokenEndpoint, fields: fields, followRedirects: false)
        var tokens = try parseTokens(response, fallbackClientId: clientId, fallbackSecret: clientSecret)
        tokens.tokenEndpoint = metadata.tokenEndpoint.absoluteString
        tokens.authorizationEndpoint = metadata.authorizationEndpoint.absoluteString
        tokens.resource = includeResource ? mcpURL.absoluteString : nil
        return tokens
    }

    func parseTokens(
        _ response: HTTPResponse,
        fallbackClientId: String?,
        fallbackSecret: String?
    ) throws -> OAuthTokenSet {
        guard (200...299).contains(response.status) else {
            throw HarnaisError.oauthFailed("The token endpoint returned HTTP \(response.status). Check the OAuth app settings and sign in again.")
        }
        guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw HarnaisError.oauthFailed("Token response was not JSON.")
        }
        if let error = json["error"] as? String, (json["ok"] as? Bool) != true {
            let description = json["error_description"] as? String ?? error
            throw HarnaisError.oauthFailed(description)
        }
        if let ok = json["ok"] as? Bool, ok == false {
            throw HarnaisError.oauthFailed(json["error"] as? String ?? "Slack sign-in failed.")
        }
        let authed = json["authed_user"] as? [String: Any]
        guard let access = json["access_token"] as? String ?? authed?["access_token"] as? String, !access.isEmpty else {
            throw HarnaisError.oauthFailed("Token response had no access token.")
        }
        let expires = (json["expires_in"] as? Int) ?? (authed?["expires_in"] as? Int)
        let expiry = expires.map { Date().addingTimeInterval(TimeInterval($0)) }
        return OAuthTokenSet(
            clientId: fallbackClientId,
            clientSecret: fallbackSecret,
            accessToken: access,
            refreshToken: json["refresh_token"] as? String ?? authed?["refresh_token"] as? String,
            expiresAt: expiry,
            tokenType: json["token_type"] as? String ?? "Bearer",
            scope: json["scope"] as? String,
            idToken: json["id_token"] as? String
        )
    }

    private func fetchJSON(_ url: URL) throws -> [String: Any] {
        try SharedMCPURL.validate(url)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try HTTPClient.send(request, timeout: 12, followRedirects: false)
        guard (200...299).contains(response.status),
              let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        else {
            throw HarnaisError.oauthFailed("Could not read \(url.lastPathComponent).")
        }
        return json
    }
}

enum IntegrationAccountLabel {
    static func make(tokens: OAuthTokenSet) -> String? {
        if let idToken = tokens.idToken, let email = JWTPayload.email(idToken) {
            return email
        }
        if let email = JWTPayload.email(tokens.accessToken) {
            return email
        }
        return nil
    }
}
