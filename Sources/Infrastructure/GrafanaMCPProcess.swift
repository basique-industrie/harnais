import Domain
import Foundation

public struct GrafanaMCPProcess: Sendable {
    public init() {}

    public static let installURL = URL(string: "https://github.com/grafana/mcp-grafana")!

    public static func binaryPath() -> String? {
        BinaryLocator.which("mcp-grafana")
    }

    public func run(connection: IntegrationConnection, credentials: IntegrationCredentialStore, readOnly: Bool = false) throws {
        guard let grafana = try credentials.load(for: connection).grafana else {
            throw HarnaisError.notLoggedIn
        }
        guard let binary = Self.binaryPath() else {
            throw HarnaisError.grafanaBinaryMissing
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = BinaryLocator.shellPath()
        environment["GRAFANA_URL"] = grafana.url
        environment["GRAFANA_SERVICE_ACCOUNT_TOKEN"] = grafana.token
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-t", "stdio"] + (readOnly ? ["--disable-write"] : [])
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        Foundation.exit(process.terminationStatus)
    }
}

public enum GrafanaURL {
    public static func normalize(_ raw: String) throws -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme, url.host != nil else {
            throw HarnaisError.oauthFailed("Grafana URL looks invalid.")
        }
        if scheme != "https", !(scheme == "http" && (url.host == "localhost" || url.host == "127.0.0.1")) {
            throw HarnaisError.oauthFailed("Grafana URL must be https.")
        }
        return trimmed
    }
}
