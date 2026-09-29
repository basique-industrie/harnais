import Domain
import Foundation

/// Resolves and runs CLI updates the way T3 does: native `update`, Homebrew,
/// bun/pnpm/npm globals, plus an npm-registry latest check.
public struct BinaryUpdater: Sendable {
    public var runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func advisory(
        provider: ProviderKind,
        binaryPath: String,
        currentVersion: String?,
        environment: [String: String],
        fetchLatest: Bool = true
    ) -> VersionAdvisory {
        let realPath = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path
        let plan = Self.plan(
            provider: provider,
            binaryPath: binaryPath,
            realPath: realPath
        )
        let latest: String?
        if fetchLatest {
            latest = Self.latestVersion(
                provider: provider,
                realPath: realPath,
                environment: environment,
                runner: runner
            )
        } else {
            latest = nil
        }
        let status: VersionAdvisoryStatus
        if let currentVersion, let latest, Self.compareVersions(currentVersion, latest) < 0 {
            status = .behindLatest
        } else if currentVersion != nil, latest != nil {
            status = .current
        } else {
            status = .unknown
        }
        return VersionAdvisory(
            status: status,
            currentVersion: currentVersion,
            latestVersion: latest,
            plan: plan,
            message: status == .behindLatest ? "Install the update now or review provider settings." : nil
        )
    }

    public func run(_ plan: BinaryUpdatePlan, environment: [String: String]) throws -> ProcessResult {
        let executable: String
        if plan.executable.hasPrefix("/") {
            executable = plan.executable
        } else if let resolved = BinaryLocator.which(plan.executable) {
            executable = resolved
        } else {
            throw HarnaisError.updateFailed("Could not find \(plan.executable) to run the update.")
        }
        var env = environment
        if env["PATH"] == nil {
            env["PATH"] = BinaryLocator.shellPath()
        }
        let result = try runner.run(
            executable: executable,
            arguments: plan.arguments,
            environment: env,
            timeout: 180
        )
        if result.exitCode != 0 {
            throw HarnaisError.updateFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Update exited \(result.exitCode)."
                : result.output)
        }
        return result
    }

    public static func plan(
        provider: ProviderKind,
        binaryPath: String,
        realPath: String
    ) -> BinaryUpdatePlan? {
        let normalized = normalize(realPath)
        let resolvedNormalized = normalize(binaryPath)
        let paths = [normalized, resolvedNormalized]

        if provider == .opencode {
            return makePlan(executable: binaryPath, arguments: ["upgrade"])
        }

        if provider == .cursor {
            return makePlan(executable: binaryPath, arguments: ["update"])
        }

        if provider == .claude, paths.contains(where: {
            $0.hasSuffix("/.local/bin/claude") || $0.contains("/.local/share/claude/")
        }) {
            return makePlan(executable: binaryPath, arguments: ["update"])
        }

        if provider == .codex, paths.contains(where: { $0.contains("/packages/standalone/") }) {
            return makePlan(executable: binaryPath, arguments: ["update"])
        }

        if paths.contains(where: { $0.contains("/.vite-plus/bin/") }), let pkg = provider.npmPackageName {
            return makePlan(executable: "vp", arguments: ["i", "-g", pkg])
        }
        if paths.contains(where: { $0.contains("/.bun/bin/") }), let pkg = provider.npmPackageName {
            return makePlan(executable: "bun", arguments: ["i", "-g", "\(pkg)@latest"])
        }
        if paths.contains(where: isPnpmGlobal), let pkg = provider.npmPackageName {
            return makePlan(executable: "pnpm", arguments: ["add", "-g", "\(pkg)@latest"])
        }

        if let pkg = provider.npmPackageName, let prefix = npmGlobalPrefix(realPath: realPath, packageName: pkg) {
            return makePlan(
                executable: "npm",
                arguments: [
                    "install",
                    "-g",
                    "--prefix",
                    prefix,
                    "--allow-scripts=\(pkg)",
                    "\(pkg)@latest",
                ]
            )
        }

        if let brew = homebrewOwnership(realPath: realPath) {
            let args = brew.kind == .cask
                ? ["upgrade", "--cask", brew.name]
                : ["upgrade", brew.name]
            return makePlan(executable: "brew", arguments: args)
        }

        return makePlan(executable: binaryPath, arguments: ["update"])
    }

    public static func npmGlobalPrefix(realPath: String, packageName: String) -> String? {
        let slashPath = realPath.replacingOccurrences(of: "\\", with: "/")
        let needle = "/lib/node_modules/\(packageName.lowercased())/"
        let lower = slashPath.lowercased()
        guard let range = lower.range(of: needle, options: .backwards) else { return nil }
        let prefixEnd = slashPath.index(slashPath.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.lowerBound))
        let prefix = String(slashPath[..<prefixEnd])
        return prefix.isEmpty ? nil : prefix
    }

    public static func homebrewOwnership(realPath: String) -> (kind: HomebrewKind, name: String)? {
        let path = realPath.replacingOccurrences(of: "\\", with: "/")
        guard let regex = try? NSRegularExpression(pattern: #"/(cellar|caskroom)/([^/]+)/[^/]+/"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let kindRange = Range(match.range(at: 1), in: path),
              let nameRange = Range(match.range(at: 2), in: path)
        else { return nil }
        let kind: HomebrewKind = path[kindRange].lowercased() == "caskroom" ? .cask : .formula
        return (kind, String(path[nameRange]))
    }

    public static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = numericParts(lhs)
        let right = numericParts(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a < b { return -1 }
            if a > b { return 1 }
        }
        return 0
    }

    public enum HomebrewKind: Sendable {
        case formula
        case cask
    }

    private static func latestVersion(
        provider: ProviderKind,
        realPath: String,
        environment: [String: String],
        runner: ProcessRunner
    ) -> String? {
        if let brew = homebrewOwnership(realPath: realPath),
           let brewPath = BinaryLocator.which("brew")
        {
            return brewLatest(brewPath: brewPath, ownership: brew, environment: environment, runner: runner)
        }
        if let pkg = provider.npmPackageName {
            return LatestVersionCache.shared.npmLatest(pkg)
        }
        return nil
    }

    private static func brewLatest(
        brewPath: String,
        ownership: (kind: HomebrewKind, name: String),
        environment: [String: String],
        runner: ProcessRunner
    ) -> String? {
        let cacheKey = "brew:\(ownership.name)"
        if let cached = LatestVersionCache.shared.get(cacheKey) { return cached }
        let result = try? runner.run(
            executable: brewPath,
            arguments: ["info", "--json=v2", ownership.name],
            environment: environment,
            timeout: 8
        )
        guard let output = result?.output,
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let version: String?
        if ownership.kind == .formula {
            let formulae = root["formulae"] as? [[String: Any]]
            let versions = formulae?.first?["versions"] as? [String: Any]
            version = versions?["stable"] as? String
        } else {
            let casks = root["casks"] as? [[String: Any]]
            version = (casks?.first?["version"] as? String)?.split(separator: ",").first.map(String.init)
        }
        LatestVersionCache.shared.set(cacheKey, version)
        return version
    }

    private static func makePlan(executable: String, arguments: [String]) -> BinaryUpdatePlan {
        BinaryUpdatePlan(
            executable: executable,
            arguments: arguments,
            command: ([executable.lastPathComponent] + arguments).joined(separator: " ")
        )
    }

    private static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    private static func isPnpmGlobal(_ path: String) -> Bool {
        path.contains("/.local/share/pnpm/")
            || path.contains("/library/pnpm/")
            || path.contains("/pnpm/global/")
    }

    private static func numericParts(_ version: String) -> [Int] {
        let ns = version as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = try? NSRegularExpression(pattern: #"(\d+)(?:\.(\d+))?(?:\.(\d+))?"#)
            .firstMatch(in: version, range: range)
        else { return [] }
        return (1...3).compactMap { index in
            let part = match.range(at: index)
            guard part.location != NSNotFound else { return nil }
            return Int(ns.substring(with: part))
        }
    }
}

private extension String {
    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}

private final class VersionBox: @unchecked Sendable {
    var value: String?
}

private final class LatestVersionCache: @unchecked Sendable {
    static let shared = LatestVersionCache()
    private let lock = NSLock()
    private var values: [String: (value: String?, expires: Date)] = [:]

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = values[key], entry.expires > Date() else { return nil }
        return entry.value
    }

    func set(_ key: String, _ value: String?) {
        lock.lock()
        values[key] = (value, Date().addingTimeInterval(60 * 60))
        lock.unlock()
    }

    func npmLatest(_ package: String) -> String? {
        if let cached = get("npm:\(package)") { return cached }
        var components = URLComponents(string: "https://registry.npmjs.org/\(package)/latest")
        if components?.url == nil {
            components = URLComponents(string: "https://registry.npmjs.org/\(package.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? package)/latest")
        }
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let semaphore = DispatchSemaphore(value: 0)
        let box = VersionBox()
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                box.value = json["version"] as? String
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 4)
        set("npm:\(package)", box.value)
        return box.value
    }
}
