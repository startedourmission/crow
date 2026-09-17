import Foundation

/// Workspace-scoped note linking and a lightweight completion catalog.
public enum NoteLinks {
    public struct Catalog: Equatable, Sendable {
        public private(set) var paths: [String] = []
        private var tagsByPath: [String: Set<String>] = [:]
        public var tags: [String] { Set(tagsByPath.values.flatMap { $0 }).sorted() }
        public init() {}
        public init(notes: [String: String], paths: [String] = []) {
            self.paths = Array(Set(paths + Array(notes.keys))).sorted()
            for (path, text) in notes { tagsByPath[path] = NoteLinks.tags(in: text) }
        }
        public mutating func update(path: String, text: String) {
            if !paths.contains(path) { paths.append(path); paths.sort() }
            tagsByPath[path] = NoteLinks.tags(in: text)
        }
    }
    private static let tagPattern = try! NSRegularExpression(pattern: #"(?:^|\s)#([\p{L}\p{N}_/-]+)"#)
    public static func tags(in text: String) -> Set<String> {
        var tags = Set<String>(), frontmatter = false, tagList = false, fence: Character?
        func collect(_ value: String) {
            let tag = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'[]#"))
            if !tag.isEmpty, tag.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_/-")).contains($0) }) { tags.insert(tag) }
        }
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if index == 0 && line.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) == "---" { frontmatter = true; continue }
            if frontmatter {
                if line == "---" { frontmatter = false; continue }
                if line.hasPrefix("tags:") {
                    let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    tagList = value.isEmpty
                    if value.hasPrefix("[") { value.dropFirst().dropLast().split(separator: ",").forEach { collect(String($0)) } }
                    else if !value.hasPrefix("#") { collect(value) }
                } else if tagList && line.hasPrefix("- ") { collect(String(line.dropFirst(2))) }
                else if !line.isEmpty && !line.hasPrefix("#") { tagList = false }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { if fence == line.first { fence = nil } else if fence == nil { fence = line.first }; continue }
            if fence != nil { continue }
            let plain = code.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
            for match in tagPattern.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) { collect((plain as NSString).substring(with: match.range(at: 1))) }
        }
        return tags
    }
    private static let links = try! NSRegularExpression(pattern: #"(?<!!)\[\[([^\]\n]+)\]\]|(?<!!)\[[^\]\n]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)"#)
    private static let code = try! NSRegularExpression(pattern: #"(`+).*?\1"#)
    public static func targets(in source: String) -> [String] {
        var result: [String] = [], fence: Character?, frontmatter = false
        for (index, raw) in source.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if index == 0 && line.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) == "---" { frontmatter = true; continue }
            if frontmatter { if line == "---" { frontmatter = false }; continue }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if fence == line.first { fence = nil } else if fence == nil { fence = line.first }; continue
            }
            if fence != nil { continue }
            let plain = code.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
            for match in links.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
                let value = (plain as NSString).substring(with: range).components(separatedBy: "|")[0]
                if URL(string: value)?.scheme == nil { result.append(value) }
            }
        }
        return result
    }
    public static func resolve(_ link: String, from source: String, paths: Set<String>) -> String? {
        Resolver(paths).resolve(link, from: source)
    }
    private struct Resolver {
        let paths: Set<String>
        let byName: [String: [String]]
        init(_ paths: Set<String>) {
            self.paths = paths
            byName = Dictionary(grouping: paths) { ($0 as NSString).lastPathComponent }
        }
        func resolve(_ link: String, from source: String) -> String? {
            let value = link.components(separatedBy: "#")[0].removingPercentEncoding ?? link
            if value.isEmpty { return source }
            guard URL(string: value)?.scheme == nil, !value.contains("\0") else { return nil }
            func candidates(_ path: String) -> [String] {
                guard !path.hasPrefix("/") else { return [] }
                var parts: [Substring] = []
                for component in path.split(separator: "/") {
                    if component == "." { continue }
                    if component == ".." { guard !parts.isEmpty else { return [] }; parts.removeLast() }
                    else { parts.append(component) }
                }
                let normalized = parts.joined(separator: "/")
                return (normalized as NSString).pathExtension.isEmpty ? [normalized + ".md", normalized + ".markdown", normalized] : [normalized]
            }
            let folder = (source as NSString).deletingLastPathComponent
            let local = folder.isEmpty ? value : (folder as NSString).appendingPathComponent(value)
            for path in candidates(local) + candidates(value) where paths.contains(path) { return path }
            guard !value.contains("/") else { return nil }
            let names = Set(candidates(value))
            let matches = names.flatMap { byName[$0] ?? [] }
            return matches.count == 1 ? matches.first : nil
        }
    }
    public static func backlinks(to target: String, notes: [String: String]) -> [String] {
        let resolver = Resolver(Set(notes.keys))
        return notes.compactMap { path, source in
            guard path != target, !Task.isCancelled else { return nil }
            return targets(in: source).contains { resolver.resolve($0, from: path) == target } ? path : nil
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
