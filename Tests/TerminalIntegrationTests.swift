import XCTest
import CrowCore
import SwiftTerm
@testable import Crow
#if os(macOS)
import AppKit

final class TerminalIntegrationTests: XCTestCase {
    @MainActor func testRealShellInputResizeAndWorkspaceRetention() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crow-pty-" + UUID().uuidString)
        let model = AppModel(vaultURL: directory)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let workspaceID = model.selectedWorkspaceID
        let terminalID = model.current.snapshot.selectedTerminalID!
        let session = model.terminal(terminalID, in: model.current)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(session.running)
        let view = session.view
        func type(_ text: String) { view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        // Use terminal key callbacks, not direct output injection.
        type("printf '__CROW_%s__\\n' PTY; pwd\n")
        try await waitUntil { self.screen(view).contains("__CROW_PTY__") }
        try await waitUntil {
            self.screen(view).replacingOccurrences(of: "\n", with: "").contains(directory.resolvingSymlinksInPath().path)
        }
        type("printf '__DELETE_%s__\\n' abX")
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        type("c\n")
        try await waitUntil { self.screen(view).contains("__DELETE_abc__") }
        type("printf '__KOREAN_%s__\\n' 한글")
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        type("국\n")
        try await waitUntil { self.screen(view).contains("__KOREAN_한국__") }
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 350)
        let dimensions = view.getTerminal().getDims()
        type("printf '__SIZE__'; stty size\n")
        try await waitUntil { self.screen(view).contains("__SIZE__\(dimensions.rows) \(dimensions.cols)") }
        let other = WorkspaceState(.init(workspace: Workspace(name: "Other", kind: .local, connection: .local), rootPath: model.vaultURL.path))
        model.states.append(other)
        model.selectWorkspace(other.id)
        model.selectWorkspace(workspaceID)
        XCTAssertTrue(model.terminal(terminalID, in: model.current) === session)
        type("sleep 20\n")
        try await Task.sleep(for: .milliseconds(100))
        view.terminalDelegate?.send(source: view, data: [0x03])
        type("printf '__AFTER_%s__\\n' INTERRUPT\n")
        try await waitUntil { self.screen(view).contains("__AFTER_INTERRUPT__") }
        model.newTerminal()
        let second = model.terminal(model.current.snapshot.selectedTerminalID!, in: model.current)
        XCTAssertFalse(second === session)
    }

    @MainActor func testIMECommitOnlySendsCommittedBytes() {
        let workspace = Workspace(name: "Local", kind: .local, connection: .local)
        let session = TerminalSession(id: UUID(), workspace: workspace, directory: "/tmp", remote: nil, fontSize: 16)
        var sent: [UInt8] = []
        session.onBytes = { sent += $0 }
        session.view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(sent.isEmpty)
        session.view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(sent, Array("한".utf8))
        session.view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(sent, Array("한".utf8) + [0x7f])
    }

    @MainActor private func screen(_ view: TerminalView) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).compactMap { row in
            terminal.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
                characterProvider: terminal.getCharacter(for:))
        }.joined(separator: "\n")
    }

    @MainActor private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Terminal output did not arrive within 7.5 seconds")
    }
}
#endif
