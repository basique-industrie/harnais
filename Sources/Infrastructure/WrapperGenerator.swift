import Domain
import Foundation

/// Writes executable wrappers that pin the isolation env for Terminal use.
public struct WrapperGenerator: Sendable {
    public var identity: AppIdentity

    public init(identity: AppIdentity = .current) {
        self.identity = identity
    }

    public func write(for account: Account, binaryPath: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: identity.binDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = identity.binDirectory.appendingPathComponent(account.wrapperName)
        var lines = [
            "#!/bin/zsh",
            "set -euo pipefail",
        ]
        for (key, value) in account.env.sorted(by: { $0.key < $1.key }) {
            let expanded = (value as NSString).expandingTildeInPath
            lines.append("export \(key)=\(ShellQuote.quote(expanded))")
        }
        lines.append("exec \(ShellQuote.quote(binaryPath)) \"$@\"")
        let body = lines.joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    public func refreshAll(accounts: [Account]) throws {
        for account in accounts {
            guard let binary = BinaryLocator.resolve(account.provider, override: account.binaryPath) else {
                continue
            }
            _ = try write(for: account, binaryPath: binary)
        }
    }

    public func remove(for account: Account) {
        let url = identity.binDirectory.appendingPathComponent(account.wrapperName)
        try? FileManager.default.removeItem(at: url)
    }
}
