#if os(macOS)
import AppKit
import CrowCore
import SwiftTerm
import XCTest
@testable import Crow

/// Exercises the actual AppKit input callbacks and SwiftTerm screen buffer.
/// Run with scripts/test-macos-terminal.sh on a Mac with Xcode installed.
final class EchoTerminalTests: XCTestCase {
    @MainActor
    func testEchoInputAgainstTerminalBuffer() {
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let coordinator = TerminalCoordinator()
        view.terminalDelegate = coordinator
        let workspace = Workspace(name: "Test", kind: .local, connection: .local)
        let terminal = view.getTerminal()
        var sent: [UInt8] = []
        coordinator.onBytes = { sent += $0 }

        func reset(columns: Int = 80) {
            terminal.resize(cols: columns, rows: 24)
            coordinator.reset(on: view, workspace: workspace)
            // Keep the prompt on row 2 even when the banner wraps in narrow fixtures.
            view.feed(text: "\u{1b}[2J\u{1b}[3;1H$ ")
            sent = []
        }
        func type(_ text: String) {
            view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        func backspace() {
            view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        }
        func row(_ y: Int) -> String {
            return terminal.getLine(row: y)?.translateToString(
                trimRight: true, skipNullCellsFollowingWide: true,
                characterProvider: terminal.getCharacter(for:)
            ).trimmingCharacters(in: .whitespaces) ?? ""
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            XCTAssertTrue(condition(), "\(message): row2=\(row(2).debugDescription), row3=\(row(3).debugDescription), cursor=\(terminal.getCursorLocation())")
            print("PASS: \(message)")
        }

        reset()
        type("abc")
        backspace()
        expect(row(2) == "$ ab", "ASCII backspace erases the screen")
        expect(sent == Array("abc".utf8) + [0x7f], "Inspector receives original input, including DEL")
        backspace()
        backspace()
        backspace()
        expect(row(2) == "$", "Extra backspace preserves the prompt")
        expect(terminal.getCursorLocation().x == 2, "Cursor stays after prompt")

        reset()
        type("한글")
        backspace()
        expect(row(2) == "$ 한", "Hangul backspace erases both cells")
        expect(terminal.getCursorLocation().x == 4, "Hangul deletion restores cursor by two cells")
        type("국")
        expect(row(2) == "$ 한국", "Typing after deletion has no stale cells")

        reset()
        type("e\u{301}")
        backspace()
        expect(row(2) == "$", "Combining accent deletes as one character")

        reset(columns: 10)
        type("12345678")
        backspace()
        expect(row(2) == "$ 1234567", "Deletion at pending right-margin wrap")
        type("89a")
        backspace()
        backspace()
        backspace()
        expect(row(2) == "$ 1234567" && row(3).isEmpty, "Deletion crosses a wrapped row")

        reset(columns: 10)
        type("1234567한")
        backspace()
        backspace()
        expect(row(2) == "$ 123456" && row(3).isEmpty, "Wide-character wrap preserves deletion position")

        reset()
        type("first")
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        backspace()
        type("next")
        expect(row(2) == "$ first" && row(3) == "next", "Enter moves to column zero and protects prior line")

        reset()
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        expect(sent.isEmpty, "Marked Hangul never reaches echo or inspector")
        type("한")
        backspace()
        expect(row(2) == "$", "Committed IME text can be deleted")

        type("old")
        coordinator.reset(on: view, workspace: workspace)
        backspace()
        expect(row(2) == "$", "Workspace reset discards old editing state")
        print("All macOS terminal smoke tests passed.")
    }
}
#endif
