import Domain
import Foundation

public struct CursorMCPImporter: Sendable {
    public var mcpURL: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.mcpURL = homeDirectory.appendingPathComponent(".cursor/mcp.json")
    }

    public init(mcpURL: URL) {
        self.mcpURL = mcpURL
    }

    public func slackClientID() -> String? {
        guard let servers = servers(),
              let slack = servers["slack"] as? [String: Any]
        else { return nil }
        if let auth = slack["auth"] as? [String: Any], let id = string(auth["CLIENT_ID"]) {
            return id
        }
        if let oauth = slack["oauth"] as? [String: Any], let id = string(oauth["clientId"]) ?? string(oauth["CLIENT_ID"]) {
            return id
        }
        return nil
    }

    public func grafanaImports() -> [GrafanaImport] {
        guard let servers = servers() else { return [] }
        var items: [GrafanaImport] = []
        for (name, value) in servers {
            guard let object = value as? [String: Any] else { continue }
            let env = object["env"] as? [String: Any] ?? [:]
            guard let url = string(env["GRAFANA_URL"]) else { continue }
            var token: String?
            if let tokenFile = string(env["GRAFANA_TOKEN_FILE"]) {
                let path = (tokenFile as NSString).expandingTildeInPath
                token = try? String(contentsOfFile: path, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if token == nil {
                token = string(env["GRAFANA_SERVICE_ACCOUNT_TOKEN"])
            }
            guard let token, !token.isEmpty else { continue }
            items.append(
                GrafanaImport(
                    mcpName: name,
                    label: IntegrationNaming.humanizeMcpName(name, kind: .grafana),
                    url: url,
                    token: token
                )
            )
        }
        return items.sorted { $0.mcpName < $1.mcpName }
    }

    private func servers() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: mcpURL.path),
              let root = try? JSONObjectFile.read(mcpURL)
        else { return nil }
        return root["mcpServers"] as? [String: Any]
    }

    private func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct GrafanaImport: Sendable, Equatable {
    public var mcpName: String
    public var label: String
    public var url: String
    public var token: String
}
