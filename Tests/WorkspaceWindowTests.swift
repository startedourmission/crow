#if os(macOS)
import AppKit
import XCTest
import CrowCore
@testable import Crow

@MainActor final class WorkspaceWindowTests: XCTestCase {
    private var root: URL!
    private var windows: WorkspaceWindowStore!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-windows-test-" + UUID().uuidString)
        windows = WorkspaceWindowStore(directory: root, vaultURL: root.appendingPathComponent("Vault"))
    }
    override func tearDown() async throws {
        windows.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func testWindowsOwnSelectionDraftsTabsAndTerminalViews() throws {
        let first = windows.open(UUID())
        let original = try XCTUnwrap(first.selectedBuffer)
        let another = root.appendingPathComponent("Other Vault")
        try FileManager.default.createDirectory(at: another, withIntermediateDirectories: true)
        first.openFolder(another)
        let selectedBefore = first.selectedWorkspaceID
        let second = windows.open(UUID())
        XCTAssertFalse(first === second)
        XCTAssertNotEqual(first.sessionURL, second.sessionURL)
        XCTAssertEqual(first.workspaces.map(\.id), second.workspaces.map(\.id))
        for (a, b) in zip(first.states, second.states) {
            XCTAssertFalse(a === b)
            XCTAssertFalse(a.explorer === b.explorer)
        }
        XCTAssertTrue(second.buffers.isEmpty, "A new window opens a fresh tab, not another window’s editor")
        second.selectWorkspace(first.states.first!.id)
        XCTAssertEqual(first.selectedWorkspaceID, selectedBefore)
        first.selectWorkspace(first.states.first!.id)
        second.openFile(.init(name: original.title, path: original.path, isDirectory: false))
        let secondBuffer = try XCTUnwrap(second.selectedBuffer)
        XCTAssertNotEqual(original.id, secondBuffer.id)
        first.updateBufferText(original.id, "first window draft")
        second.updateBufferText(secondBuffer.id, "second window draft")
        XCTAssertEqual(first.selectedBuffer?.text, "first window draft")
        XCTAssertEqual(second.selectedBuffer?.text, "second window draft")
        let firstSidebar = first.sidebarVisible
        second.sidebarVisible.toggle()
        XCTAssertEqual(first.sidebarVisible, firstSidebar)
        second.newTerminal()
        let secondTerminal = second.terminal(second.current.snapshot.selectedTerminalID!, in: second.current)
        let firstTerminal = first.terminal(first.current.snapshot.selectedTerminalID!, in: first.current)
        XCTAssertFalse(firstTerminal === secondTerminal)
        XCTAssertFalse(firstTerminal.view === secondTerminal.view)
        let pane = first.current.snapshot.layout
        second.newTab()
        XCTAssertEqual(first.current.snapshot.layout, pane)
        windows.activate(second.windowID)
        XCTAssertTrue(windows.activeModel === second)
        windows.activate(first.windowID)
        XCTAssertTrue(windows.activeModel === first)
        let routeA = ScreenWindowID(windowID: first.windowID, workspaceID: first.selectedWorkspaceID)
        let routeB = ScreenWindowID(windowID: second.windowID, workspaceID: second.selectedWorkspaceID)
        XCTAssertNotEqual(routeA, routeB)
        XCTAssertTrue(windows.model(for: routeA.windowID) === first)
        XCTAssertTrue(windows.model(for: routeB.windowID) === second)
        windows.close(second.windowID)
        XCTAssertEqual(first.selectedBuffer?.text, "first window draft")
        XCTAssertTrue(first.current.terminals[firstTerminal.id] === firstTerminal)
    }

    func testIndependentSessionsRestoreWithoutOverwritingOtherWindows() throws {
        let firstID = UUID(), secondID = UUID()
        let first = windows.open(firstID)
        let original = try XCTUnwrap(first.selectedBuffer)
        let second = windows.open(secondID)
        second.openFile(.init(name: original.title, path: original.path, isDirectory: false))
        let secondBuffer = try XCTUnwrap(second.selectedBuffer)
        first.updateBufferText(original.id, "draft A")
        second.updateBufferText(secondBuffer.id, "draft B")
        first.persist(); second.persist()
        windows.close(firstID); windows.close(secondID)
        let restoredFirst = windows.open(firstID)
        let restoredSecond = windows.open(secondID)
        XCTAssertEqual(restoredFirst.selectedBuffer?.text, "draft A")
        XCTAssertEqual(restoredSecond.selectedBuffer?.text, "draft B")
        XCTAssertTrue(restoredFirst.hasUnsavedChanges)
        XCTAssertTrue(restoredSecond.hasUnsavedChanges)
    }

    func testExistingSessionMigratesWithoutDroppingDrafts() throws {
        let legacy = AppModel(vaultURL: root.appendingPathComponent("Vault"), sessionURL: windows.legacySessionURL)
        legacy.updateBufferText(legacy.selectedBufferID!, "legacy unsaved text")
        legacy.shutdown()
        let restored = windows.open(UUID())
        XCTAssertEqual(restored.selectedBuffer?.text, "legacy unsaved text")
        XCTAssertTrue(restored.hasUnsavedChanges)
        XCTAssertNotEqual(restored.sessionURL, windows.legacySessionURL)
    }
}
#endif
