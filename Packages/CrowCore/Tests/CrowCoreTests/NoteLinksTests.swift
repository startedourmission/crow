import XCTest
@testable import CrowCore

final class NoteLinksTests: XCTestCase {
    func testNoteLinksAreOptInAndPersist() throws {
        let old = try JSONDecoder().decode(EditorSettings.self, from: JSONEncoder().encode(EditorSettings()))
        XCTAssertFalse(old.effectiveNoteLinksEnabled)
        var enabled = old; enabled.noteLinksEnabled = true
        XCTAssertTrue(try JSONDecoder().decode(EditorSettings.self, from: JSONEncoder().encode(enabled)).effectiveNoteLinksEnabled)
    }
    func testLinksExcludeFrontmatterCodeAndExternalLinks() {
        let text = "---\nproperty: '[[Not a backlink]]'\n---\n[[Project|label]] [Sibling](../Sibling.md) `[[Code]]` ![[Image]] [Web](https://example.com)\n```\n[[Fenced]]\n```"
        XCTAssertEqual(NoteLinks.targets(in: text), ["Project", "../Sibling.md"])
        let paths: Set<String> = ["Folder/Project.md", "Other/Project.md", "Sibling.md", "Folder/Current.md"]
        XCTAssertEqual(NoteLinks.resolve("Project#Heading", from: "Folder/Current.md", paths: paths), "Folder/Project.md")
        XCTAssertEqual(NoteLinks.resolve("../Sibling.md", from: "Folder/Current.md", paths: paths), "Sibling.md")
        XCTAssertNil(NoteLinks.resolve("Project", from: "Elsewhere/Current.md", paths: paths))
        XCTAssertNil(NoteLinks.resolve("../../outside.md", from: "Folder/Current.md", paths: paths))
        XCTAssertNil(NoteLinks.resolve("file:///etc/passwd", from: "Folder/Current.md", paths: paths))
    }
    func testBacklinkIndexCostOnTwoThousandNotes() {
        var notes = Dictionary(uniqueKeysWithValues: (0..<1999).map { ("Folder/Note\($0).md", "# Note\n" + String(repeating: "Normal note text. ", count: 200) + "\n[[Unknown]] [[Target]]") })
        notes["Folder/Target.md"] = "# Target"
        let start = Date()
        let result = NoteLinks.backlinks(to: "Folder/Target.md", notes: notes)
        print("BACKLINK_BENCHMARK notes=2000 bytes=\(notes.values.reduce(0) { $0 + $1.utf8.count }) seconds=\(Date().timeIntervalSince(start))")
        XCTAssertEqual(result.count, 1999)
    }
    func testFrontmatterBlockPreservesSourceAndBodyPositions() {
        let prefix = "\u{FEFF}---\r\n# comment\r\ntags: [one, two]\r\n---\r\n"
        let source = prefix + "# Title\n\nBody text\n"
        let blocks = MarkdownPreview.editingBlocks(source)
        XCTAssertEqual(blocks.first?.source, prefix)
        XCTAssertTrue(blocks.first?.html.contains("data-crow-frontmatter") == true)
        XCTAssertEqual(blocks.map(\.source).joined(), source)
        XCTAssertTrue(blocks.dropFirst().map(\.html).joined().contains("data-source-start=\"\((prefix as NSString).length + 2)\""))
    }
}

extension NoteLinksTests {
    func testVaultFlagDefaultsOffAndCatalogTracksRenamedTags() throws {
        let workspace = Workspace(name: "Notes", kind: .local, connection: .local)
        var snapshot = WorkspaceSnapshot(workspace: workspace, rootPath: "/notes")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        old.removeValue(forKey: "isNoteVault")
        XCTAssertFalse(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: old)).isNoteVault)
        snapshot.isNoteVault = true
        XCTAssertTrue(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot)).isNoteVault)
        var catalog = NoteLinks.Catalog(notes: ["Folder/Note.md": "---\ntags: [work, '한글/태그']\n---\n#inline `#ignored`\n```\n#ignoredToo\n```\n"], paths: ["image.png"])
        XCTAssertEqual(Set(catalog.tags), ["work", "한글/태그", "inline"])
        XCTAssertEqual(catalog.paths, ["Folder/Note.md", "image.png"])
        catalog.update(path: "Folder/Note.md", text: "---\ntags:\n - changed\n - nested/tag\n---\n")
        XCTAssertEqual(catalog.tags, ["changed", "nested/tag"])
    }
}
