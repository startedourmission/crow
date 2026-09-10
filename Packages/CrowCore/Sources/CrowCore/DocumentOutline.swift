import Foundation

public struct EditorLocationRequest: Equatable, Sendable {
    public let id = UUID()
    public let offset: Int
    public let headingIndex: Int?
    public init(offset: Int, headingIndex: Int? = nil) { self.offset = offset; self.headingIndex = headingIndex }
}

public struct OutlineItem: Identifiable, Equatable, Sendable {
    public var id: Int { offset }
    public let title: String
    public let line: Int
    public let offset: Int
    public let depth: Int
    public let headingIndex: Int?
}

/// Markdown uses Foundation's parsed heading structure. Code outlines are lexical
/// declaration recognition, not a compiler/LSP symbol index; unsupported languages stay empty.
public enum DocumentOutline {
    public static func items(_ source: String, language: LanguageMode) -> [OutlineItem] {
        if language == .markdown { return headings(source) }
        let name = #"([\p{L}_$][\p{L}\p{N}_$]*)"#
        let patterns: [String]
        switch language {
        case .swift: patterns = [#"\bfunc\s+"# + name + #"\s*(?:<[^{}]*?>)?\s*\("#, #"\b(init|deinit)\s*[?!]?\s*\("#]
        case .python: patterns = [#"(?m)^[\t ]*(?:async\s+)?def\s+"# + name + #"\s*(?:\[[^\]]*\])?\s*\("#]
        case .go: patterns = [#"(?m)^\s*func\s+(?:\([^)]*\)\s*)?"# + name + #"\s*(?:\[[^\]]*\])?\s*\("#]
        case .rust: patterns = [#"\bfn\s+"# + name + #"\s*(?:<[^{}]*?>)?\s*\("#]
        case .ruby: patterns = [#"(?m)^[\t ]*def\s+(?:self\.)?"# + name]
        case .shell: patterns = [#"(?m)^[\t ]*(?:function\s+)?"# + name + #"\s*\(\s*\)\s*\{"#, #"(?m)^[\t ]*function\s+"# + name + #"\s*\{"#]
        case .javascript, .typescript:
            patterns = [#"\bfunction\s*\*?\s*"# + name + #"\s*(?:<[^{}]*?>)?\s*\("#,
                #"\b(?:const|let|var)\s+"# + name + #"\s*(?::[^=;\n]+)?=\s*(?:async\s+)?(?:\([^;{}]*?\)|[\p{L}_$][\w$]*)\s*(?::[^=;\n]+)?=>"#,
                #"(?m)^[\t ]*(?:(?:public|private|protected|static|async|abstract|override|get|set)\s+)*"# + name + #"\s*(?:<[^{}]*?>)?\s*\([^;{}]*?\)\s*(?::[^;{}=\n]+)?\s*\{"#]
        case .c:
            patterns = [#"(?m)^[\t ]*(?!(?:return|if|else|while|for|switch|throw)\b)(?:[\w:*&<>]+[\t ]+)+"# + name + #"\s*\([^;{}]*?\)\s*(?:const\s*)?(?:noexcept\s*)?\{"#]
        default: return []
        }
        let masked = maskTrivia(source, language: language) as NSString
        let original = source as NSString
        var lineStarts = [0]
        for (index, unit) in source.utf16.enumerated() where unit == 10 { lineStarts.append(index + 1) }
        let excluded: Set<String> = ["if", "for", "while", "switch", "catch", "with", "function"]
        var found: [Int: OutlineItem] = [:]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)) {
                let range = match.range(at: 1)
                guard range.location != NSNotFound else { continue }
                let title = original.substring(with: range)
                guard !excluded.contains(title) else { continue }
                var low = 0, high = lineStarts.count
                while low < high {
                    let middle = (low + high) / 2
                    if lineStarts[middle] <= range.location { low = middle + 1 } else { high = middle }
                }
                let line = max(1, low)
                let prefix = original.substring(with: NSRange(location: lineStarts[line - 1], length: range.location - lineStarts[line - 1]))
                let indentation = prefix.prefix { $0 == " " || $0 == "\t" }.count
                found[range.location] = OutlineItem(title: title, line: line, offset: range.location,
                    depth: min(6, indentation / 4), headingIndex: nil)
            }
        }
        return found.values.sorted { $0.offset < $1.offset }
    }

    private static func headings(_ source: String) -> [OutlineItem] {
        guard let parsed = try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .full, appliesSourcePositionAttributes: true)) else { return [] }
        var starts = [0]
        for (index, unit) in source.utf16.enumerated() where unit == 10 { starts.append(index + 1) }
        var entries: [(identity: Int, title: String, level: Int, line: Int)] = []
        for run in parsed.runs {
            guard let heading = run.presentationIntent?.components.first(where: {
                if case .header = $0.kind { return true }; return false
            }), case .header(let level) = heading.kind else { continue }
            let title = String(parsed[run.range].characters)
            if entries.last?.identity == heading.identity { entries[entries.count - 1].title += title }
            else { entries.append((heading.identity, title, level, run.markdownSourcePosition?.startLine ?? 1)) }
        }
        return entries.enumerated().map { index, entry in
            let line = min(starts.count, max(1, entry.line))
            return OutlineItem(title: entry.title.trimmingCharacters(in: .whitespacesAndNewlines), line: line,
                offset: starts[line - 1], depth: entry.level - 1, headingIndex: index)
        }
    }

    private static func maskTrivia(_ source: String, language: LanguageMode) -> String {
        let units = Array(source.utf16)
        var result = units, index = 0
        let hashComments: Set<LanguageMode> = [.python, .ruby, .shell, .c]
        func blank(_ start: Int, _ end: Int) {
            for i in start..<end where units[i] != 10 && units[i] != 13 { result[i] = 32 }
        }
        while index < units.count {
            let start = index
            if (hashComments.contains(language) && units[index] == 35) ||
                (!hashComments.contains(language) && index + 1 < units.count && units[index] == 47 && units[index + 1] == 47) ||
                (language == .c && index + 1 < units.count && units[index] == 47 && units[index + 1] == 47) {
                while index < units.count && units[index] != 10 { index += 1 }; blank(start, index)
            } else if index + 1 < units.count && units[index] == 47 && units[index + 1] == 42 && ![LanguageMode.python, .ruby, .shell].contains(language) {
                index += 2
                while index + 1 < units.count && !(units[index] == 42 && units[index + 1] == 47) { index += 1 }
                index = min(units.count, index + 2); blank(start, index)
            } else if [UInt16(34), 39, 96].contains(units[index]) && !(language == .rust && units[index] == 39) {
                let quote = units[index]
                let triple = index + 2 < units.count && units[index + 1] == quote && units[index + 2] == quote && [.python, .swift].contains(language)
                let width = triple ? 3 : 1
                index += width
                while index < units.count {
                    if units[index] == 92 { index = min(units.count, index + 2); continue }
                    if index + width <= units.count && units[index..<index + width].allSatisfy({ $0 == quote }) { index += width; break }
                    index += 1
                }
                blank(start, index)
            } else { index += 1 }
        }
        return String(decoding: result, as: UTF16.self)
    }
}
