import XCTest
import CrowCore
import SwiftTerm
@testable import Crow
#if os(macOS)
import AppKit
import SwiftUI

@MainActor private final class FloatingZoomTestWindow: NSWindow {
    var zoomRequests = 0
    var fullScreenRequests = 0
    override func zoom(_ sender: Any?) { zoomRequests += 1 }
    override func toggleFullScreen(_ sender: Any?) { fullScreenRequests += 1 }
}
#else
import UIKit
#endif

final class InputToolsTests: XCTestCase {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1cAAAAASUVORK5CYII=")!

    func testKeyboardButtonsComposeChordsAndStandaloneModifiers() throws {
        var draft = KeyboardBarDraft()
        XCTAssertNil(draft.item)
        draft.tap("Shift")
        XCTAssertEqual(draft.item?.key, "Shift")
        draft.tap("Tab")
        XCTAssertEqual(draft.item?.label, "shift+tab")
        XCTAssertEqual(draft.item?.terminalText(applicationCursor: false), "\u{1b}[Z")
        draft.tap("Control")
        XCTAssertTrue(draft.item?.control == true)
        draft.tap("Shift")
        XCTAssertFalse(draft.item?.shift == true)
        draft.tap("Tab")
        XCTAssertEqual(draft.item?.key, "Control")
        draft.tap("Character")
        XCTAssertNil(draft.item)
        draft.character = "c"
        XCTAssertEqual(draft.item?.terminalText(applicationCursor: false), "\u{03}")
        draft.character = "two"
        XCTAssertNil(draft.item)
    }

    func testWorkspaceDragTypeIsExportedByApplicationBundle() throws {
        let declarations = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let type = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == "dev.chajinwoo.crow.workspace-tab" })
        XCTAssertTrue((type["UTTypeConformsTo"] as? [String])?.contains("public.data") == true)
    }

    func testKeyboardSettingsMigrationAndCustomizedRoundTrip() throws {
        let old = try JSONEncoder().encode(EditorSettings())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        json.removeValue(forKey: "keyboardBarItems"); json.removeValue(forKey: "textSnippets")
        var settings = try JSONDecoder().decode(EditorSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(settings.effectiveKeyboardBarItems.map(\.key), ["Escape", "Tab", "Control", "Shift", "ArrowLeft", "ArrowUp", "ArrowDown", "ArrowRight"])
        settings.keyboardBarItems = [KeyboardBarKey(key: "Tab", shift: true), KeyboardBarKey(key: "c", control: true)]
        settings.textSnippets = [TextSnippet(name: "한글", text: "arbitrary ' text\nnext line", memo: "간단한 메모\n삽입하지 않는 설명")]
        let restored = try JSONDecoder().decode(EditorSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.keyboardBarItems, settings.keyboardBarItems)
        XCTAssertEqual(restored.textSnippets, settings.textSnippets)
        let snippet = try XCTUnwrap(restored.textSnippets?.first)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snippet)) as? [String: Any])
        legacy.removeValue(forKey: "memo")
        let legacySnippet = try JSONDecoder().decode(TextSnippet.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(legacySnippet.memo, "")
        XCTAssertEqual(legacySnippet.id, snippet.id)
        XCTAssertEqual(legacySnippet.text, snippet.text)
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
    @MainActor func testMacSnippetRestoresCapturedSelectionAndSupportsTerminal() throws {
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        editor.isRichText = false; editor.allowsUndo = true; editor.string = "before after"
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        let target = try XCTUnwrap(MacSnippetTarget(responder: editor))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        target.insert("한글 ")
        XCTAssertEqual(editor.string, "before 한글 after")
        let session = TerminalSession(id: UUID(), workspace: Workspace(name: "Test", kind: .local, connection: .local), directory: "/tmp", remote: nil, fontSize: 14)
        defer { session.stop() }
        window.contentView = session.view
        var sent: [UInt8] = []; session.onBytes = { sent += $0 }
        let terminalTarget = try XCTUnwrap(MacSnippetTarget(responder: session.view))
        terminalTarget.insert("snippet")
        XCTAssertEqual(sent, Array("snippet".utf8))
        XCTAssertFalse(target.available, "A detached editor must not receive stale snippet insertions")
    }

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
        XCTAssertEqual(window.minSize, NSSize(width: 280, height: 200))
        window.setFrame(NSRect(x: 100, y: 100, width: 300, height: 220), display: false)
        controller.rememberSize(of: window)
        controller.apply(true, to: window)
        XCTAssertEqual(window.frame.size, NSSize(width: 300, height: 220))
        controller.apply(false, to: window)
        XCTAssertEqual(window.frame, original)
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.collectionBehavior, behavior)
        XCTAssertEqual(window.minSize, NSSize(width: 640, height: 400))
        controller.rememberSize(of: window)
        controller.apply(true, to: window)
        XCTAssertEqual(window.frame.size, NSSize(width: 300, height: 220))
        window.setFrame(NSRect(x: 100, y: 100, width: 760, height: 620), display: false)
        controller.rememberSize(of: window)
        controller.apply(false, to: window)
        controller.apply(true, to: window)
        XCTAssertEqual(window.frame.size, NSSize(width: 760, height: 620))
        controller.apply(false, to: window)
        XCTAssertEqual(window.frame, original)
    }

    @MainActor func testFloatingGreenButtonZoomsWithoutEnteringFullScreen() throws {
        let window = FloatingZoomTestWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let originalTarget = button.target
        let originalAction = button.action
        let controller = FloatingWindowController()
        controller.apply(true, to: window)
        button.performClick(nil)
        button.performClick(nil)
        XCTAssertEqual(window.zoomRequests, 2)
        XCTAssertEqual(window.fullScreenRequests, 0)
        XCTAssertEqual(window.level, .floating)
        controller.apply(false, to: window)
        XCTAssertTrue(button.target === originalTarget)
        XCTAssertEqual(button.action, originalAction)
    }

    @MainActor func testFloatingContentAllowsSmallAndWideWindows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-floating-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let hosting = NSHostingView(rootView: CrowRootView().environment(model)
            .environment(\.crowFloatingMode, .constant(true))
            .frame(minWidth: FloatingWindowController.minimumSize.width, minHeight: FloatingWindowController.minimumSize.height))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 560),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.contentView = hosting
        let controller = FloatingWindowController()
        controller.apply(true, to: window)
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        for surface in [CompactSurface.hosts, .files, .editor, .terminal] {
            model.compactSurface = surface
            // Include the native title-bar inset when requesting the whole frame.
            for size in [NSSize(width: 300, height: 260), NSSize(width: 850, height: 300)] {
                window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
                try await Task.sleep(for: .milliseconds(60))
                hosting.layoutSubtreeIfNeeded()
                XCTAssertEqual(hosting.frame.size, size, "\(surface) must allow independent width/height resizing")
                XCTAssertLessThanOrEqual(window.contentMinSize.width, 300)
                XCTAssertLessThanOrEqual(window.contentMinSize.height, 260)
            }
        }
        controller.apply(false, to: window)
    }
    #else
    @MainActor func testIPadSnippetTargetsFocusedSplitAndRestoresSelection() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let container = try XCTUnwrap(window.rootViewController?.view)
        let first = NumberedTextView(usingTextLayoutManager: false)
        let second = NumberedTextView(usingTextLayoutManager: false)
        first.frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        second.frame = CGRect(x: 210, y: 0, width: 200, height: 150)
        container.addSubview(first); container.addSubview(second)
        first.text = "untouched"; second.text = "before after"
        XCTAssertTrue(second.becomeFirstResponder())
        second.selectedRange = NSRange(location: 7, length: 0)
        let target = try XCTUnwrap(IOSSnippetTarget.capture(in: window))
        XCTAssertTrue(first.becomeFirstResponder())
        second.selectedRange = NSRange(location: 0, length: 0)
        target.insert("snippet ")
        XCTAssertEqual(first.text, "untouched")
        XCTAssertEqual(second.text, "before snippet after")
        target.restoreFocus()
        XCTAssertTrue(second.isFirstResponder)
        second.removeFromSuperview()
        XCTAssertFalse(target.available)
        target.insert("ignored")
        XCTAssertEqual(second.text, "before snippet after")

        let terminal = CrowIOSTerminalView(frame: CGRect(x: 0, y: 160, width: 400, height: 200))
        container.addSubview(terminal)
        let delegate = TerminalCoordinator(); var sent: [UInt8] = []
        delegate.onBytes = { sent += $0 }; terminal.terminalDelegate = delegate
        XCTAssertTrue(terminal.becomeFirstResponder())
        let terminalTarget = try XCTUnwrap(IOSSnippetTarget.capture(in: window))
        terminalTarget.insert("agent prompt")
        XCTAssertEqual(sent, Array("agent prompt".utf8))
    }

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
