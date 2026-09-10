import XCTest
@testable import CrowCore

final class MarkdownPreviewTests: XCTestCase {
    func testCodeBlockFenceTerminatorIsNotAnEditableTrailingLine() {
        XCTAssertEqual(MarkdownPreview.body("```\nlast line\n```"), "<pre><code>last line</code></pre>")
        XCTAssertEqual(MarkdownPreview.body("```\nlast line\n\n```"), "<pre><code>last line\n</code></pre>")
        XCTAssertEqual(MarkdownPreview.body("```\nlast line\n\n\n```"), "<pre><code>last line\n\n</code></pre>")
        XCTAssertFalse(MarkdownPreview.body("```\n```").contains("\n"))
        let source = "```swift\nlet x = 1\n```\n"
        let block = MarkdownPreview.editingBlocks(source)[0]
        XCTAssertEqual(block.source, source)
        XCTAssertFalse(block.html.contains("1\n"))
        XCTAssertTrue(block.html.contains("let x = 1</span>"))
        XCTAssertTrue(block.html.contains("class=\"language-swift\""))
        XCTAssertTrue(block.html.contains("data-source-start=\"9\" data-source-end=\"18\""))
    }
    func testCodeSourceMappingSkipsLanguageHintAndHandlesUnicode() {
        let source = "# 한글🙂\n\n~~~~swift\nswift\n~~~~\n"
        let block = MarkdownPreview.editingBlocks(source).last!
        let content = (source as NSString).range(of: "\nswift\n")
        XCTAssertTrue(block.html.contains("data-source-start=\"\(content.location + 1)\" data-source-end=\"\(content.location + 6)\""))
        let unicode = MarkdownPreview.editingBlocks("```text\n한글🙂\n```\n")[0]
        XCTAssertTrue(unicode.html.contains("data-source-start=\"8\" data-source-end=\"12\""))
    }
    func testParserSentinelAndOutOfBoundsSourceRangesAreRejected() {
        // Exact NSRange reported by Crow's preview-toggle crash on a 12,953-unit note.
        XCTAssertFalse(MarkdownPreview.isValidSourceRange(NSRange(location: NSNotFound, length: NSNotFound), utf16Length: 12953))
        XCTAssertFalse(MarkdownPreview.isValidSourceRange(NSRange(location: 3, length: NSNotFound), utf16Length: 8))
        XCTAssertFalse(MarkdownPreview.isValidSourceRange(NSRange(location: 9, length: 0), utf16Length: 8))
        XCTAssertFalse(MarkdownPreview.isValidSourceRange(NSRange(location: 7, length: 2), utf16Length: 8))
        XCTAssertTrue(MarkdownPreview.isValidSourceRange(NSRange(location: 8, length: 0), utf16Length: 8))
        XCTAssertTrue(MarkdownPreview.isValidSourceRange(NSRange(location: 1, length: 7), utf16Length: 8))
    }
    func testLiveBlocksPreserveExactSourceAndNestedStructures() {
        let fixtures = ["", "\n\n", "# 한글 👨‍👩‍👧‍👦\r\n\r\n**원문**\r\n",
            "# Heading\n\n```swift\nlet x = 1\n\n---\n```\n\n- one\n\n  - nested\n- two\n\n---\n\n[ref]: https://example.com\n\nA [link][ref]\n",
            "Title\n=====\n\n| A | B |\n|---|---|\n|한글|🙂|\n\n<!-- keep -->\n",
            "<script>alert(1)</script>\n\n[ref]: https://example.com"]
        for source in fixtures {
            let blocks = MarkdownPreview.editingBlocks(source)
            XCTAssertEqual(blocks.map(\.source).joined(), source)
            XCTAssertFalse(blocks.map(\.html).joined().contains("<script>"))
        }
        let source = "# 제목\n\nA **bold** paragraph\n\n```swift\n\nlet x = 1\n```\n\n- one\n\n- two\n"
        let blocks = MarkdownPreview.editingBlocks(source)
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks[2].source, "```swift\n\nlet x = 1\n```\n\n")
        XCTAssertEqual(blocks[3].source, "- one\n\n- two\n")
        XCTAssertTrue(blocks[0].html.contains("data-source-start=\"2\""))
        var edited = blocks.map(\.source)
        edited[1] = "A **수정** paragraph\n\n"
        XCTAssertEqual(edited.joined(), source.replacingOccurrences(of: "bold", with: "수정"))
        let references = MarkdownPreview.editingBlocks("[link][ref]\n\n[ref]: https://example.com")
        XCTAssertTrue(references.map(\.html).joined().contains("href=\"https://example.com\""))
    }
    func testBlockAndInlineMarkdownRenderWithoutSourceMarkers() {
        let html = MarkdownPreview.body("# 제목\n\nA **bold** and *italic* paragraph with `code`.\n\n- one\n  - nested\n- two\n\n> quote\n\n```swift\nlet x = 1 < 2\n```\n\n---")
        XCTAssertTrue(html.contains("<h1>제목</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
        XCTAssertTrue(html.contains("<ul><li"))
        XCTAssertTrue(html.contains("<blockquote><p>quote</p></blockquote>"))
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let x = 1 &lt; 2</code></pre>"))
        XCTAssertTrue(html.contains("<hr>"))
        XCTAssertFalse(html.contains("```"))
        XCTAssertFalse(html.contains("# 제목"))
    }
    func testTablesOrderedListsAndParagraphSeparation() {
        let html = MarkdownPreview.body("First\n\nSecond\n\n3. three\n4. four\n\n| A | B |\n| --- | --- |\n| x | y |")
        XCTAssertTrue(html.contains("<p>First</p><p>Second</p>"))
        XCTAssertTrue(html.contains("<ol><li value=\"3\">"))
        XCTAssertTrue(html.contains("<table><tr class=\"table-header\"><td>A</td><td>B</td></tr><tr><td>x</td><td>y</td></tr></table>"))
    }
    func testUntrustedNotesCannotExecuteHTMLOrLoadRemoteResources() {
        let html = MarkdownPreview.document("<script>alert(1)</script>\n\n[bad](javascript:alert)\n\n![tracker](https://example.com/pixel)\n\n[safe](https://example.com)")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("href=\"javascript:"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertTrue(html.contains("href=\"https://example.com\""))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertFalse(MarkdownPreview.isExternalLink(URL(string: "file:///etc/passwd")!))
    }
}
