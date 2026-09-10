import Foundation

public struct FileSearchQuery: Equatable, Sendable {
    public let contents: Bool
    public let text: String
    public init(_ input: String) {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        contents = input.lowercased().hasPrefix("contents:")
        text = (contents ? String(input.dropFirst(9)) : input).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func switchingToContents(_ enabled: Bool) -> String {
        enabled ? "contents: " + text : text
    }
    public static func prefixCompletion(for input: String) -> String? {
        let prefix = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !prefix.isEmpty, prefix.count < "contents:".count, "contents:".hasPrefix(prefix) else { return nil }
        return "contents: "
    }
    public struct Match: Equatable, Sendable {
        public let line: Int
        public let excerpt: String
    }
    public func firstMatch(in content: String) -> Match? {
        guard contents, !text.isEmpty else { return nil }
        let source = content as NSString
        let match = source.range(of: text, options: [.caseInsensitive, .diacriticInsensitive])
        guard match.location != NSNotFound else { return nil }
        let line = source.substring(to: match.location).utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        let range = source.lineRange(for: NSRange(location: match.location, length: 0))
        let excerpt = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        return Match(line: line, excerpt: String(excerpt.prefix(180)))
    }
}
