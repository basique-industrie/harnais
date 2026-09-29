import CryptoKit
import Domain
import Foundation

/// Reads the same profile-specific store as Claude Code. Credentials stay in memory.
public enum ClaudeCredentials {
    public static func keychainService(environment: [String: String]) -> String {
        let directory = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] ?? environment["CLAUDE_CONFIG_DIR"] ?? ""
        guard !directory.isEmpty else { return "Claude Code-credentials" }
        let normalized = directory.precomposedStringWithCanonicalMapping
        let hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hash.prefix(8))"
    }

    public static func accessToken(account: Account, environment: [String: String], runner: ProcessRunner) -> String? {
        #if os(macOS)
        let username = environment["USER"] ?? NSUserName()
        if let result = try? runner.run(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-a", username, "-s", keychainService(environment: environment), "-w"],
            environment: environment, timeout: 5
        ), result.exitCode == 0, let token = token(from: Data(result.output.utf8)) {
            return token
        }
        #endif
        let directory: String
        if let override = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            directory = override.isEmpty ? (NSHomeDirectory() as NSString).appendingPathComponent(".claude") : override
        } else {
            directory = environment["CLAUDE_CONFIG_DIR"] ?? account.homePath
        }
        let file = URL(fileURLWithPath: directory).appendingPathComponent(".credentials.json")
        return (try? Data(contentsOf: file)).flatMap(token(from:))
    }

    private static func token(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}
