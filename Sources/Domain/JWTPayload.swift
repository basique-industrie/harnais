import Foundation

/// Unsigned JWT claim reader. Used only to label accounts (email / plan), never to verify tokens.
public enum JWTPayload {
    public static func dictionary(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let payload = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return json
    }

    public static func string(_ token: String, key: String) -> String? {
        dictionary(token)?[key] as? String
    }

    /// Mailbox claims only. ChatGPT `sub` is a UUID and is not an email.
    public static func email(_ token: String) -> String? {
        for key in ["email", "preferred_username"] {
            if let value = mailbox(string(token, key: key)) {
                return value
            }
        }
        return nil
    }

    public static func mailbox(_ value: String?) -> String? {
        guard let value, value.contains("@") else { return nil }
        return value
    }
}
