import Foundation

public enum DocumentSearch {
    public struct Matches: Sendable {
        public let ranges: [NSRange]
        public let truncated: Bool
    }
    public static func matches(in text: String, query: String, matchCase: Bool, limit: Int = 10_000) -> Matches {
        guard !query.isEmpty else { return Matches(ranges: [], truncated: false) }
        let source = text as NSString
        var ranges: [NSRange] = [], cursor = 0
        while cursor < source.length {
            let range = source.range(of: query, options: matchCase ? [] : [.caseInsensitive],
                range: NSRange(location: cursor, length: source.length - cursor))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if ranges.count >= limit { return Matches(ranges: ranges, truncated: true) }
            ranges.append(range); cursor = NSMaxRange(range)
        }
        return Matches(ranges: ranges, truncated: false)
    }
    public static func replacing(_ text: String, ranges: [NSRange], with replacement: String) throws -> String {
        let original = text as NSString, replacementLength = (replacement as NSString).length
        var length = original.length, end = 0
        for range in ranges {
            guard range.location >= end, range.length > 0, range.location <= original.length,
                  range.length <= original.length - range.location else { throw FileFailure.unsupportedText }
            end = NSMaxRange(range)
            length += replacementLength - range.length
            guard length <= TextFiles.sizeLimit else { throw FileFailure.tooLarge }
        }
        let result = NSMutableString(string: text)
        for range in ranges.reversed() { result.replaceCharacters(in: range, with: replacement) }
        let value = result as String
        guard value.utf8.count <= TextFiles.sizeLimit else { throw FileFailure.tooLarge }
        return value
    }
}
