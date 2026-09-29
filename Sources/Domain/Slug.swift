import Foundation

public enum Slug {
    public static func make(from label: String) -> String {
        let folded = label
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return folded.isEmpty ? "account" : String(folded.prefix(32))
    }
}
