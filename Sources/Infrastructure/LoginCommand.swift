import Domain
import Foundation

public struct LoginCommand: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public static func make(for account: Account, isolation: IsolationEngine = IsolationEngine()) throws -> LoginCommand {
        guard let binary = BinaryLocator.resolve(account.provider, override: account.binaryPath) else {
            throw HarnaisError.binaryNotFound(account.provider.defaultBinaryName)
        }
        let env = isolation.spawnEnvironment(for: account)
        let workDir = account.shadowHomePath ?? account.homePath
        return LoginCommand(
            executable: binary,
            arguments: account.provider.loginArguments,
            environment: env,
            workingDirectory: workDir
        )
    }
}
