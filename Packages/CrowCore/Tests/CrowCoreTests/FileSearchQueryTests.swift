import XCTest
@testable import CrowCore

final class FileSearchQueryTests: XCTestCase {
    func testPrefixSwitchingAndCompletion() {
        XCTAssertEqual(FileSearchQuery("note").switchingToContents(true), "contents: note")
        XCTAssertEqual(FileSearchQuery("contents: note").switchingToContents(true), "contents: note")
        XCTAssertEqual(FileSearchQuery("contents: note").switchingToContents(false), "note")
        XCTAssertEqual(FileSearchQuery.prefixCompletion(for: "con"), "contents: ")
        XCTAssertEqual(FileSearchQuery.prefixCompletion(for: "CONTENTS"), "contents: ")
        XCTAssertNil(FileSearchQuery.prefixCompletion(for: "contents: note"))
        XCTAssertNil(FileSearchQuery.prefixCompletion(for: "config.swift"))
    }
    func testDocumentSearchCaseMatchingAndReplacement() throws {
        let text = "Foo foo FOO\n한글 Foo"
        let exact = DocumentSearch.matches(in: text, query: "Foo", matchCase: true)
        let insensitive = DocumentSearch.matches(in: text, query: "Foo", matchCase: false)
        XCTAssertEqual(exact.ranges.count, 2)
        XCTAssertEqual(insensitive.ranges.count, 4)
        XCTAssertEqual(try DocumentSearch.replacing(text, ranges: exact.ranges, with: "Bar"), "Bar foo FOO\n한글 Bar")
        XCTAssertEqual(try DocumentSearch.replacing(text, ranges: insensitive.ranges, with: ""), "  \n한글 ")
        XCTAssertTrue(DocumentSearch.matches(in: text, query: "Foo", matchCase: false, limit: 2).truncated)
        XCTAssertTrue(DocumentSearch.matches(in: text, query: "", matchCase: false).ranges.isEmpty)
        XCTAssertEqual(DocumentSearch.matches(in: "a.* aBC", query: "a.*", matchCase: false).ranges.count, 1)
    }
    func testExplicitPrefixAndLiteralText() {
        XCTAssertFalse(FileSearchQuery("notes.md").contents)
        XCTAssertFalse(FileSearchQuery("src/contents: notes").contents)
        let query = FileSearchQuery("  contents: 한글.*  ")
        XCTAssertTrue(query.contents)
        XCTAssertEqual(query.text, "한글.*")
        XCTAssertEqual(query.firstMatch(in: "first\r\n👋 한글.* value\r\n")?.line, 2)
        XCTAssertEqual(query.firstMatch(in: "first\r\n👋 한글.* value\r\n")?.excerpt, "👋 한글.* value")
        XCTAssertNil(query.firstMatch(in: "한글 hello"))
        XCTAssertNil(FileSearchQuery("contents:").firstMatch(in: "anything"))
        XCTAssertEqual(FileSearchQuery("contents: HELLO").firstMatch(in: "hello")?.line, 1)
    }
    func testBoundedTextReadPreservesFullFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let text = String(repeating: "한글\n", count: 30_000)
        try Data(text.utf8).write(to: url)
        XCTAssertEqual(try TextFiles.read(url), text)
        XCTAssertThrowsError(try TextFiles.read(url, maximumSize: 100))
    }
}
