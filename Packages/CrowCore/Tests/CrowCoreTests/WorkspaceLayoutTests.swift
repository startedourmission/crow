import XCTest
@testable import CrowCore

final class WorkspaceLayoutTests: XCTestCase {
    func testLastFileCloseLeavesOnlyTerminalPane() throws {
        let file = BufferID(), terminal = UUID()
        var layout = WorkspaceLayout(files: [file], selectedFile: file, terminals: [terminal], selectedTerminal: terminal)
        XCTAssertEqual(layout.panes.count, 2)
        layout.remove(.file(file))
        XCTAssertEqual(layout.panes.count, 1)
        XCTAssertEqual(layout.root, .pane(try XCTUnwrap(layout.panes.first).id))
        XCTAssertEqual(layout.allTabs, [.terminal(terminal)])
        layout.remove(.terminal(terminal))
        XCTAssertNil(layout.root)
        XCTAssertTrue(layout.panes.isEmpty)
    }
    func testMoveAcrossPanesPrunesEmptySourceAndReordersTabs() throws {
        let a = BufferID(), b = BufferID(), terminal = UUID()
        var layout = WorkspaceLayout(files: [a, b], selectedFile: a, terminals: [terminal], selectedTerminal: terminal)
        let source = layout.panes[0].id, target = layout.panes[1].id
        XCTAssertTrue(layout.move(.file(a), from: source, to: target))
        XCTAssertTrue(layout.move(.file(b), from: source, to: target, before: .terminal(terminal)))
        XCTAssertEqual(layout.panes.count, 1)
        XCTAssertEqual(layout.panes[0].tabs, [.file(b), .terminal(terminal), .file(a)])
        XCTAssertTrue(layout.move(.file(a), from: target, to: target, before: .file(b)))
        XCTAssertEqual(layout.panes[0].tabs.first, .file(a))
    }
    func testNestedSplitsMergeAndRoundTrip() throws {
        let file = BufferID(), terminal = UUID()
        var layout = WorkspaceLayout(files: [file], selectedFile: file, terminals: [terminal], selectedTerminal: terminal)
        let filePane = layout.panes[0].id, terminalPane = layout.panes[1].id
        XCTAssertTrue(layout.move(.file(file), from: filePane, to: filePane, placement: .right, copy: true))
        let copyPane = try XCTUnwrap(layout.activePaneID)
        XCTAssertTrue(layout.move(.terminal(terminal), from: terminalPane, to: copyPane, placement: .bottom))
        XCTAssertEqual(layout.panes.count, 3)
        XCTAssertEqual(Set(layout.root?.paneIDs ?? []), Set(layout.panes.map(\.id)))
        let restored = try JSONDecoder().decode(WorkspaceLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(restored, layout)
        layout.remove(.file(file), from: filePane)
        XCTAssertEqual(layout.allTabs.filter { $0 == .file(file) }.count, 1)
        XCTAssertEqual(layout.panes.count, 2)
    }
    func testTerminalCannotBeDuplicatedAndInvalidMovesAreNonMutating() {
        let id = UUID()
        var layout = WorkspaceLayout(files: [], selectedFile: nil, terminals: [id], selectedTerminal: id)
        let pane = layout.panes[0].id, original = layout
        XCTAssertFalse(layout.move(.terminal(id), from: pane, to: pane, placement: .right, copy: true))
        XCTAssertFalse(layout.move(.terminal(id), from: pane, to: pane, placement: .right))
        XCTAssertFalse(layout.move(.terminal(id), from: pane, to: UUID()))
        XCTAssertEqual(layout, original)
    }
    func testLegacySnapshotWithoutLayoutStillDecodes() throws {
        let snapshot = WorkspaceSnapshot(workspace: Workspace(name: "Vault", kind: .local, connection: .local), rootPath: "/vault")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object.removeValue(forKey: "layout")
        let restored = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.layout)
        XCTAssertEqual(restored.terminalIDs, snapshot.terminalIDs)
    }
}
