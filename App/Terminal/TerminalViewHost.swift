import CrowCore
import SwiftTerm
import SwiftUI

#if os(iOS)
import UIKit
private typealias PlatformTerminalViewRepresentable = UIViewRepresentable
#elseif os(macOS)
import AppKit
private typealias PlatformTerminalViewRepresentable = NSViewRepresentable
#endif

struct TerminalViewHost: PlatformTerminalViewRepresentable {
    let session: TerminalSession
    let fontSize: Double
    #if os(iOS)
    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        session.view
    }
    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        session.setFontSize(fontSize)
    }
    #else
    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        session.view
    }
    func updateNSView(_ view: SwiftTerm.TerminalView, context: Context) {
        session.setFontSize(fontSize)
    }
    #endif
}

@MainActor
final class TerminalCoordinator: NSObject, @preconcurrency TerminalViewDelegate {
    var workspaceID: WorkspaceID?
    var onBytes: (([UInt8]) -> Void)?
    private var echo = LocalEcho()

    func reset(on view: SwiftTerm.TerminalView, workspace: Workspace) {
        workspaceID = workspace.id
        echo = LocalEcho()
        view.feed(text: "\u{001b}[2J\u{001b}[H" + Self.bannerText(workspace))
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        onBytes?(Array(data))
        for action in echo.receive(data) {
            switch action {
            case .write(let text):
                source.feed(text: text)
            case .erase(let columns):
                erase(columns: columns, on: source)
            }
        }
    }

    private func erase(columns: Int, on view: SwiftTerm.TerminalView) {
        let terminal = view.getTerminal()
        var cursor = terminal.getCursorLocation()
        // Use absolute positions: BS alone neither erases nor crosses a wrapped row.
        // SwiftTerm may report x == cols while a right-margin wrap is pending.
        for _ in 0..<columns {
            if cursor.x > 0 {
                cursor.x -= 1
            } else if cursor.y > 0 {
                cursor.y -= 1
                cursor.x = terminal.cols - 1
            } else {
                break
            }
            view.feed(text: "\u{001b}[\(cursor.y + 1);\(cursor.x + 1)H\u{001b}[X")
        }
        // A two-cell glyph wraps early if only one cell remained. Return to that
        // unused cell after deleting it, so the next keystroke does not leave a gap.
        if cursor.x == 0, cursor.y > 0,
           let lastCell = terminal.getCharData(col: terminal.cols - 1, row: cursor.y - 1),
           lastCell.width == 1, terminal.getCharacter(for: lastCell) == "\0" {
            view.feed(text: "\u{001b}[\(cursor.y);\(terminal.cols)H")
        }
    }

    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    func bell(source: SwiftTerm.TerminalView) {}

    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        #if os(iOS)
        if let text = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = text
        }
        #else
        if let text = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        #endif
    }

    func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

    static func bannerText(_ workspace: Workspace) -> String {
        switch workspace.kind {
        case .imeLab:
            return "Crow IME Lab\r\nHangul composition must not reach the PTY.\r\nInspector shows committed UTF-8 only.\r\n\r\n> "
        case .local:
            return "Crow · local echo\r\n\r\n$ "
        case .remote:
            return "\(workspace.name) · input echo\r\n\r\n$ "
        }
    }
}
