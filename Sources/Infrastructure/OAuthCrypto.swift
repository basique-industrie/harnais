import CryptoKit
import Domain
import Foundation

enum PKCE {
    static func make() -> (verifier: String, challenge: String, state: String) {
        let verifier = random(bytes: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URL(Data(digest))
        let state = random(bytes: 16)
        return (verifier, challenge, state)
    }

    static func random(bytes count: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
        precondition(status == errSecSuccess)
        return base64URL(Data(buffer))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum WWWAuthenticate {
    static func resourceMetadataURL(from header: String) -> URL? {
        let pairs = parameters(from: header)
        if let raw = pairs["resource_metadata"] ?? pairs["resource"] {
            return URL(string: raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return nil
    }

    static func parameters(from header: String) -> [String: String] {
        var values: [String: String] = [:]
        let body = header.replacingOccurrences(of: "Bearer", with: "", options: .caseInsensitive)
        for part in body.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = String(value)
        }
        return values
    }
}

enum JSONObjectFile {
    static func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarnaisError.mcpApplyFailed("\(url.lastPathComponent) is not a JSON object.")
        }
        return object
    }

    static func write(_ object: [String: Any], to url: URL, permissions: Int = 0o600) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
