import XCTest
import SwiftUI
@testable import Crow
#if os(macOS)
import AppKit

final class EditorIntegrationTests: XCTestCase {
    @MainActor func testNativeIndentOutdentAndUndo() {
        let editor = CodeTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.makeFirstResponder(editor)
        defer { window.close() }
        editor.isRichText = false; editor.allowsUndo = true; editor.indentWidth = 2
        editor.string = "hello"
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "  hello")
        editor.insertBacktab(nil)
        XCTAssertEqual(editor.string, "hello")
        editor.string = "  hello"
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "  hello\n  ")
        XCTAssertTrue(editor.undoManager?.canUndo ?? false)
    }

    @MainActor func testWorkspaceRendersAndProducesPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-render-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let hosting = NSHostingView(rootView: CrowRootView().environment(model).preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(500))
        let terminalID = try XCTUnwrap(model.current.snapshot.selectedTerminalID)
        let terminal = model.terminal(terminalID, in: model.current).view
        // NSView bitmap snapshots cannot capture a Metal layer's drawable.
        try terminal.setUseMetal(false)
        let background = try XCTUnwrap(terminal.nativeBackgroundColor.usingColorSpace(.sRGB))
        XCTAssertEqual(background.redComponent, 1, accuracy: 0.001)
        let layerBackground = try XCTUnwrap(terminal.layer?.backgroundColor)
        XCTAssertEqual(try XCTUnwrap(NSColor(cgColor: layerBackground)?.usingColorSpace(.sRGB)).redComponent,
            1, accuracy: 0.001)
        hosting.layoutSubtreeIfNeeded()
        // SwiftTerm draws default cells transparently over its white layer.
        // A bitmap of draw() alone therefore has transparent, not white, cells.
        let terminalBitmap = try XCTUnwrap(terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: terminalBitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        terminal.draw(terminal.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(terminalBitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/crow-macos-terminal.png"))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/crow-macos-workspace.png"))
        XCTAssertEqual(Int(hosting.bounds.width), 1280)
    }
}
#endif
