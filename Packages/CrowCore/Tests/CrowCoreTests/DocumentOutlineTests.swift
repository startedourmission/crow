import XCTest
@testable import CrowCore

final class DocumentOutlineTests: XCTestCase {
    func testMarkdownStructureAndUnicodeOffsets() {
        let text = "# 제목 **강조**\n\n```md\n# Not a heading\n```\n\nSecond\n------\n\n### Third\n"
        let items = DocumentOutline.items(text, language: .markdown)
        XCTAssertEqual(items.map(\.title), ["제목 강조", "Second", "Third"])
        XCTAssertEqual(items.map(\.depth), [0, 1, 2])
        XCTAssertEqual(items.map(\.line), [1, 7, 10])
        XCTAssertEqual(items.map(\.headingIndex), [0, 1, 2])
        XCTAssertEqual(items[1].offset, (text as NSString).range(of: "Second").location)
    }
    func testDeclarationsNotCommentsOrStrings() {
        let text = "// func fake() {}\nlet s = \"func nope() {}\"\nstruct Test {\n    func 한글(\n      x: Int\n    ) {}\n}\n"
        let items = DocumentOutline.items(text, language: .swift)
        XCTAssertEqual(items.map(\.title), ["한글"])
        XCTAssertEqual(items[0].offset, (text as NSString).range(of: "한글").location)
        XCTAssertEqual(items[0].line, 4)
    }
    func testCommonCodeLanguages() {
        let fixtures: [(LanguageMode, String, [String])] = [
            (.python, "\"\"\"\ndef fake(): pass\n\"\"\"\nclass A:\n    async def run(self):\n        pass\n", ["run"]),
            (.javascript, "function first() {}\nconst next = (x) => x;\nclass A {\n  async method(a) {\n    if (a) {}\n  }\n}", ["first", "next", "method"]),
            (.typescript, "export const run = async (x: string): Promise<void> => {};\nclass A {\n public method(x: number): string { return ''; }\n}", ["run", "method"]),
            (.go, "func (s *Server) Serve(x int) {}\nfunc Main() {}", ["Serve", "Main"]),
            (.rust, "pub async fn run<T>(x: T) {}", ["run"]),
            (.c, "// void fake() {}\nstatic int run(\n int x\n) { return x; }", ["run"]),
            (.shell, "hello() { echo ok; }\nfunction next { true; }", ["hello", "next"]),
            (.ruby, "class A\n  def self.run(x)\n  end\nend", ["run"])
        ]
        for (language, source, expected) in fixtures {
            XCTAssertEqual(DocumentOutline.items(source, language: language).map(\.title), expected, language.rawValue)
        }
        XCTAssertTrue(DocumentOutline.items("{\"function\": 1}", language: .json).isEmpty)
    }
    func testGitPorcelainPathsAndRenames() {
        let data = Data("## main...origin/main [ahead 1]\0 M 한글 file.md\0R  new\nname.swift\0old.swift\0?? new.txt\0 D removed.md\0".utf8)
        let status = GitStatus(porcelain: data)
        XCTAssertEqual(status.branch, "main...origin/main [ahead 1]")
        XCTAssertEqual(status.changes.map(\.path), ["한글 file.md", "new\nname.swift", "new.txt", "removed.md"])
        XCTAssertEqual(status.changes[1].previousPath, "old.swift")
        XCTAssertTrue(status.changes[3].isDeleted)
    }
}
