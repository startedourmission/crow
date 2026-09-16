import Foundation

/// Foundation parses Markdown; presentation intents retain block structure that SwiftUI.Text ignores.
public enum MarkdownPreview {
    public static func body(_ source: String) -> String {
        guard let markdown = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return "<pre>\(escape(source))</pre>"
        }
        return render(markdown)
    }

    /// Each block retains its exact Markdown, including separators and unsupported syntax.
    /// Editing replaces only that slice, never a lossy HTML-to-Markdown serialization.
    public struct EditingBlock: Equatable, Sendable, Codable {
        public let source: String
        public let html: String
    }

    public static func editingBlocks(_ source: String) -> [EditingBlock] {
        let frontmatter = try! NSRegularExpression(pattern: #"\A(?:\uFEFF)?---\r?\n(?:[\s\S]*?\r?\n)?---[ \t]*(?:\r?\n|$)"#)
        if let match = frontmatter.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), let range = Range(match.range, in: source) {
            let prefix = String(source[range]), remainder = String(source[range.upperBound...])
            let offset = (prefix as NSString).length
            let positions = try! NSRegularExpression(pattern: #"data-source-(?:start|end)="([0-9]+)""#)
            let body: [EditingBlock] = remainder.isEmpty ? [] : editingBlocks(remainder).map { block in
                var html = block.html
                for match in positions.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
                    let digits = match.range(at: 1)
                    if let value = Int((html as NSString).substring(with: digits)), let range = Range(digits, in: html) {
                        html.replaceSubrange(range, with: String(value + offset))
                    }
                }
                return EditingBlock(source: block.source, html: html)
            }
            return [EditingBlock(source: prefix, html: "<div data-crow-frontmatter=\"true\"></div>")] + body
        }
        guard let markdown = try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .full, appliesSourcePositionAttributes: true)) else {
            return [EditingBlock(source: source, html: body(source))]
        }
        let lines = source.components(separatedBy: "\n")
        var starts: [String.Index] = [source.startIndex]
        for index in source.utf8.indices where source.utf8[index] == 10 {
            if let next = String.Index(source.utf8.index(after: index), within: source) { starts.append(next) }
        }
        var groups: [(identity: Int, line: Int?, content: AttributedString)] = []
        for run in markdown.runs {
            let identity = run.presentationIntent?.components.last?.identity ?? -1
            if groups.last?.identity != identity { groups.append((identity, nil, AttributedString())) }
            let index = groups.count - 1
            if let line = run.markdownSourcePosition?.startLine {
                groups[index].line = min(groups[index].line ?? line, line)
            }
            groups[index].content.append(AttributedString(markdown[run.range]))
        }
        // Foundation's thematic-break run has no source position. Locate it only between
        // adjacent parsed blocks, so a horizontal rule inside fenced code is never split.
        for index in groups.indices where groups[index].line == nil {
            let lower = index == 0 ? 1 : (groups[index - 1].line ?? 1)
            let upper = groups.dropFirst(index + 1).lazy.compactMap(\.line).first ?? lines.count
            if let line = (lower...max(lower, upper)).first(where: { number in
                guard number <= lines.count else { return false }
                let text = lines[number - 1].trimmingCharacters(in: .whitespaces)
                return text.range(of: #"^(\*\s*){3,}$|^(-\s*){3,}$|^(_\s*){3,}$"#, options: .regularExpression) != nil
            }) { groups[index].line = line }
        }
        let sourceMap = SourceMap(source)
        var blocks: [EditingBlock] = []
        var cursor = source.startIndex
        for (index, group) in groups.enumerated() {
            let nextLine = groups.dropFirst(index + 1).lazy.compactMap(\.line).first
            let end = nextLine.flatMap { $0 > 0 && $0 <= starts.count ? starts[$0 - 1] : nil } ?? source.endIndex
            guard end >= cursor else { continue }
            blocks.append(EditingBlock(source: String(source[cursor..<end]), html: render(group.content, sourceMap: sourceMap)))
            cursor = end
        }
        if blocks.isEmpty { return [EditingBlock(source: source, html: "<pre>\(escape(source))</pre>")] }
        return blocks
    }

    private static func render(_ markdown: AttributedString, sourceMap: SourceMap? = nil) -> String {
        var html = ""
        var stack: [PresentationIntent.IntentType] = []
        let runs = Array(markdown.runs)
        for (index, run) in runs.enumerated() {
            let next = Array((run.presentationIntent?.components ?? []).reversed())
            let common = zip(stack, next).prefix { $0.identity == $1.identity }.count
            for intent in stack.dropFirst(common).reversed() { html += tags(intent.kind).1 }
            for intent in next.dropFirst(common) { html += tags(intent.kind).0 }
            stack = next
            if next.contains(where: { $0.kind == .thematicBreak }) { continue }
            var visible = String(markdown[run.range].characters)
            let codeIntent = next.first { if case .codeBlock = $0.kind { return true }; return false }
            let endsCodeBlock = codeIntent.map { intent in
                index + 1 == runs.count || !(runs[index + 1].presentationIntent?.components.contains { $0.identity == intent.identity } ?? false)
            } ?? false
            // Foundation includes the line terminator before the closing fence. It
            // isn't an extra editable line; strip exactly one, preserving real blank lines.
            if endsCodeBlock, visible.hasSuffix("\n") { visible.removeLast() }
            var text = escape(visible)
            let style = run.inlinePresentationIntent ?? []
            if style.contains(.lineBreak) { text = "<br>" }
            if style.contains(.softBreak) { text = "\n" }
            if style.contains(.code) { text = "<code>\(text)</code>" }
            if style.contains(.stronglyEmphasized) { text = "<strong>\(text)</strong>" }
            if style.contains(.emphasized) { text = "<em>\(text)</em>" }
            if style.contains(.strikethrough) { text = "<del>\(text)</del>" }
            // Never execute raw HTML or fetch remote images merely by opening a note.
            if run.imageURL != nil { text = "<span class=\"image-label\">Image: \(text)</span>" }
            if let url = run.link ?? run.imageURL, isExternalLink(url) || (sourceMap != nil && url.scheme == nil && run.imageURL == nil) {
                text = "<a href=\"\(escape(url.absoluteString))\">\(text)</a>"
            }
            if let sourceMap, let position = run.markdownSourcePosition, let range = sourceMap.range(position),
               isValidSourceRange(range, utf16Length: (sourceMap.source as NSString).length) {
                let raw = (sourceMap.source as NSString).substring(with: range)
                let codeBlock = next.contains { if case .codeBlock = $0.kind { return true }; return false }
                // The language hint can equal the code itself. Never map editable
                // code onto that opening fence (e.g. ```swift followed by swift).
                var search = NSRange(location: 0, length: (raw as NSString).length)
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if codeBlock, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    let newline = (raw as NSString).range(of: "\n")
                    if newline.location != NSNotFound {
                        search.location = newline.location + newline.length
                        search.length -= search.location
                    }
                }
                let inner = (raw as NSString).range(of: visible, range: search)
                if !visible.isEmpty && (raw == visible || (codeBlock && inner.location != NSNotFound)) {
                    let start = range.location + (codeBlock ? inner.location : 0)
                    text = "<span data-source-start=\"\(start)\" data-source-end=\"\(start + (visible as NSString).length)\">\(text)</span>"
                } else { text = "<span data-source-start=\"\(range.location)\">\(text)</span>" }
            }
            html += text
        }
        for intent in stack.reversed() { html += tags(intent.kind).1 }
        return html
    }

    /// Foundation can return a non-nil NSRange whose fields are both NSNotFound.
    /// Never use that sentinel (or add location + length, which can overflow) to slice NSString.
    static func isValidSourceRange(_ range: NSRange, utf16Length: Int) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0 &&
            range.location <= utf16Length && range.length <= utf16Length - range.location
    }

    /// Source columns are inclusive UTF-8 byte offsets. Foundation's NSRange
    /// conversion can return just the first character, even for a whole code block.
    /// Resolve the original line/column positions instead of its cached offsets.
    private struct SourceMap {
        let source: String
        let lines: [String.UTF8View.Index]
        init(_ source: String) {
            self.source = source
            let bytes = source.utf8
            var lines = [bytes.startIndex]
            for index in bytes.indices where bytes[index] == 10 { lines.append(bytes.index(after: index)) }
            self.lines = lines
        }
        func range(_ position: AttributedString.MarkdownSourcePosition) -> NSRange? {
            let bytes = source.utf8
            guard position.startLine > 0, position.endLine >= position.startLine,
                  position.endLine <= lines.count, position.startColumn > 0, position.endColumn > 0 else { return nil }
            let startLimit = position.startLine < lines.count ? lines[position.startLine] : bytes.endIndex
            let endLimit = position.endLine < lines.count ? lines[position.endLine] : bytes.endIndex
            guard let start = bytes.index(lines[position.startLine - 1], offsetBy: position.startColumn - 1, limitedBy: startLimit),
                  let end = bytes.index(lines[position.endLine - 1], offsetBy: position.endColumn, limitedBy: endLimit),
                  start <= end, let lower = String.Index(start, within: source), let upper = String.Index(end, within: source) else { return nil }
            return NSRange(lower..<upper, in: source)
        }
    }

    public static func document(_ source: String, fontSize: Double = 15) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>
        :root { color-scheme: light; } * { box-sizing: border-box; }
        body { margin: 0; padding: 24px 28px 80px; color: #202632; background: white;
          font: \(min(32, max(11, fontSize)))px/1.65 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; }
        main { max-width: 860px; margin: auto; } p { margin: 0 0 1em; }
        h1,h2,h3,h4,h5,h6 { line-height: 1.3; margin: 1.25em 0 .6em; font-weight: 650; }
        main > :first-child { margin-top: 0; } h1 { font-size: 2em; } h2 { font-size: 1.5em; }
        h1,h2 { border-bottom: 1px solid #e4e6e9; padding-bottom: .3em; }
        a { color: #182c48; text-decoration: underline; } ul,ol { padding-left: 1.8em; }
        li > p { margin: .25em 0; } blockquote { margin: 1em 0; padding: .1em 1em;
          border-left: 3px solid #cdd2d9; color: #626976; } blockquote p:last-child { margin-bottom: 0; }
        code,pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9em; }
        code { background: #f0f1f3; border-radius: 4px; padding: .15em .3em; }
        pre { overflow: auto; white-space: pre; padding: 16px; background: #f4f5f7; border-radius: 6px; }
        pre code { padding: 0; background: none; font-size: 1em; }
        table { border-collapse: collapse; display: block; overflow: auto; margin: 1em 0; }
        td { border: 1px solid #dce0e5; padding: 7px 12px; } tr.table-header { background: #f4f5f7; font-weight: 600; }
        hr { border: 0; border-top: 1px solid #dce0e5; margin: 1.5em 0; }
        .image-label { color: #626976; } ::selection { background: #dce1e8; }
        </style></head><body><main>\(body(source))</main></body></html>
        """
    }

    public static func isExternalLink(_ url: URL) -> Bool {
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func tags(_ kind: PresentationIntent.Kind) -> (String, String) {
        switch kind {
        case .paragraph: return ("<p>", "</p>")
        case .header(let level): return ("<h\(level)>", "</h\(level)>")
        case .orderedList: return ("<ol>", "</ol>")
        case .unorderedList: return ("<ul>", "</ul>")
        case .listItem(let ordinal): return ("<li value=\"\(ordinal)\">", "</li>")
        case .codeBlock(let language):
            let attribute = language?.split(whereSeparator: { $0.isWhitespace }).first
                .map { " class=\"language-\(escape(String($0)))\"" } ?? ""
            return ("<pre><code\(attribute)>", "</code></pre>")
        case .blockQuote: return ("<blockquote>", "</blockquote>")
        case .thematicBreak: return ("<hr>", "")
        case .table: return ("<table>", "</table>")
        case .tableHeaderRow: return ("<tr class=\"table-header\">", "</tr>")
        case .tableRow: return ("<tr>", "</tr>")
        case .tableCell: return ("<td>", "</td>")
        @unknown default: return ("<div>", "</div>")
        }
    }
}
