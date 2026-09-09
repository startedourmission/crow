import XCTest
@testable import CrowCore

final class LocalEchoTests: XCTestCase {
    func testBackspaceDeletesASCIIAndProtectsPrompt() {
        var echo = LocalEcho()
        _ = echo.receive(Array("abc".utf8)[...])
        XCTAssertEqual(echo.receive([0x7f]), [.erase(columns: 1)])
        XCTAssertEqual(echo.line, "ab")
        XCTAssertEqual(echo.receive([0x08, 0x7f, 0x7f]), [.erase(columns: 1), .erase(columns: 1)])
        XCTAssertEqual(echo.line, "")
    }

    func testHangulDeletionErasesWholeSyllable() {
        var echo = LocalEcho()
        _ = echo.receive(Array("한글".utf8)[...])
        XCTAssertEqual(echo.receive([0x7f]), [.erase(columns: 2)])
        XCTAssertEqual(echo.line, "한")
        _ = echo.receive(Array("국".utf8)[...])
        XCTAssertEqual(echo.line, "한국")
    }

    func testCombiningAccentIsOneDeletion() {
        var echo = LocalEcho()
        _ = echo.receive(Array("e\u{301}".utf8)[...])
        XCTAssertEqual(echo.receive([0x7f]), [.erase(columns: 1)])
        XCTAssertEqual(echo.line, "")
    }

    func testEmojiClusterIsOneDeletion() {
        var echo = LocalEcho()
        _ = echo.receive(Array("👩‍💻".utf8)[...])
        XCTAssertEqual(echo.receive([0x7f]), [.erase(columns: 2)])
        XCTAssertEqual(echo.line, "")
    }

    func testUTF8CanArriveAcrossCallbacks() {
        var echo = LocalEcho()
        let bytes = Array("한".utf8)
        XCTAssertEqual(echo.receive(bytes[0..<1]), [])
        XCTAssertEqual(echo.receive(bytes[1..<2]), [])
        XCTAssertEqual(echo.receive(bytes[2..<3]), [.write("한")])
        XCTAssertEqual(echo.receive([0x7f]), [.erase(columns: 2)])
    }

    func testEnterStartsNewLineAndCannotDeletePreviousLine() {
        var echo = LocalEcho()
        _ = echo.receive(Array("first".utf8)[...])
        XCTAssertEqual(echo.receive([0x0d]), [.write("\r\n")])
        XCTAssertEqual(echo.receive([0x0a, 0x7f]), [])
        XCTAssertEqual(echo.line, "")
        XCTAssertEqual(echo.receive([0x0a]), [.write("\r\n")])
    }

    func testArrowKeysDoNotMoveIntoPrompt() {
        var echo = LocalEcho()
        _ = echo.receive(Array("ab".utf8)[...])
        XCTAssertEqual(echo.receive([0x1b, 0x5b]), [])
        XCTAssertEqual(echo.receive([0x44, 0x7f]), [.erase(columns: 1)])
        XCTAssertEqual(echo.line, "a")
    }

    func testMixedPasteAndDeleteInSameCallback() {
        var echo = LocalEcho()
        let output = echo.receive(Array("ab\u{7f}한\u{8}c".utf8)[...])
        XCTAssertEqual(output, [.write("a"), .write("b"), .erase(columns: 1), .write("한"), .erase(columns: 2), .write("c")])
        XCTAssertEqual(echo.line, "ac")
    }
}
