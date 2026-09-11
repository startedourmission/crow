import XCTest
import CrowCore
import SwiftTerm
@testable import Crow
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class InputToolsTests: XCTestCase {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1cAAAAASUVORK5CYII=")!

    func testKeyboardSettingsMigrationAndCustomizedRoundTrip() throws {
        let old = try JSONEncoder().encode(EditorSettings())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        json.removeValue(forKey: "keyboardBarItems"); json.removeValue(forKey: "textSnippets")
        var settings = try JSONDecoder().decode(EditorSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(settings.effectiveKeyboardBarItems.map(\.key), ["Escape", "Tab", "Control", "Shift", "ArrowLeft", "ArrowUp", "ArrowDown", "ArrowRight"])
        settings.keyboardBarItems = [KeyboardBarKey(key: "Tab", shift: true), KeyboardBarKey(key: "c", control: true)]
        settings.textSnippets = [TextSnippet(name: "한글", text: "arbitrary ' text\nnext line")]
        let restored = try JSONDecoder().decode(EditorSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.keyboardBarItems, settings.keyboardBarItems)
        XCTAssertEqual(restored.textSnippets, settings.textSnippets)
        XCTAssertEqual(restored.effectiveKeyboardBarItems[0].terminalText(applicationCursor: false), "\u{1b}[Z")
        XCTAssertEqual(restored.effectiveKeyboardBarItems[1].terminalText(applicationCursor: false), "\u{03}")
        XCTAssertEqual(KeyboardBarKey(key: "ArrowLeft", control: true, shift: true).terminalText(applicationCursor: true), "\u{1b}[1;6D")
    }

    @MainActor func testImagePasteInsertsPathWithoutReturnAndRejectsChangedConnection() async throws {
        let workspace = Workspace(name: "Test", kind: .remote(hostID: HostID(), path: "/tmp"), connection: .connected)
        let session = TerminalSession(id: UUID(), workspace: workspace, directory: "/tmp", remote: nil, fontSize: 14)
        defer { session.stop() }
        session.running = true
        var context = "server-one"
        var sent: [UInt8] = []
        session.onBytes = { sent += $0 }
        session.imagePasteContext = { context }
        session.uploadImage = { data, destination in
            XCTAssertEqual(data, Self.png); XCTAssertEqual(destination, "server-one")
            return "/tmp/crow-clipboard-test/image.png"
        }
        XCTAssertTrue(session.pasteImage(Self.png))
        for _ in 0..<100 where session.imagePasteInProgress { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.imagePasteInProgress)
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), "/tmp/crow-clipboard-test/image.png ")
        sent = []
        session.uploadImage = { _, _ in context = "server-two"; return "/tmp/old-server.png" }
        XCTAssertTrue(session.pasteImage(Self.png))
        for _ in 0..<100 where session.imagePasteInProgress { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(session.imagePasteMessage?.contains("Connection changed") == true)
        XCTAssertThrowsError(try ClipboardImage.validate(Data("not an image".utf8)))
    }

    #if os(macOS)
    @MainActor func testFloatingWindowRestoresFrameAndBehavior() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.minSize = NSSize(width: 640, height: 400)
        let original = window.frame, behavior = window.collectionBehavior
        let controller = FloatingWindowController()
        controller.apply(true, to: window)
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]))
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertLessThanOrEqual(window.frame.width, 420)
        controller.apply(true, to: window)
        controller.apply(false, to: window)
        XCTAssertEqual(window.frame, original)
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.collectionBehavior, behavior)
        XCTAssertEqual(window.minSize, NSSize(width: 640, height: 400))
    }
    #else
    @MainActor func testSnippetsInsertAtDocumentCursorAndTerminalSendsNoReturn() throws {
        let editor = NumberedTextView(usingTextLayoutManager: false)
        editor.text = "before after"; editor.selectedRange = NSRange(location: 7, length: 0)
        let accessory = CrowKeyboardAccessory(); editor.inputAccessoryView = accessory
        accessory.onKey = { [weak editor] in editor?.performKeyboardKey($0) }
        accessory.press(KeyboardBarKey(key: "Control"))
        editor.insertSnippet("한글 snippet ")
        XCTAssertEqual(editor.text, "before 한글 snippet after")
        XCTAssertEqual(editor.selectedRange.location, 18)
        XCTAssertFalse(accessory.control)
        accessory.press(KeyboardBarKey(key: "Shift")); editor.insertText("a")
        XCTAssertEqual(editor.text, "before 한글 snippet Aafter")
        XCTAssertFalse(accessory.shift)
        let view = CrowIOSTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        let delegate = TerminalCoordinator(); var sent: [UInt8] = []
        delegate.onBytes = { sent += $0 }; view.terminalDelegate = delegate
        view.insertSnippet("한글 text")
        XCTAssertEqual(sent, Array("한글 text".utf8))
        sent = []; view.feed(text: "\u{1b}[?2004h")
        view.insertSnippet("line1\nline2")
        XCTAssertEqual(sent, Array("\u{1b}[200~line1\nline2\u{1b}[201~".utf8))
    }
    #endif
}
