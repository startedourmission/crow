import XCTest
import CrowCore
import SwiftTerm
@testable import Crow
#if os(macOS)
import AppKit
import SwiftUI

@MainActor @Observable private final class FloatingSceneFixture {
    var floating = false
    let controller = FloatingWindowController()
}

private struct FloatingSceneTestView: View {
    let model: AppModel
    @Bindable var state: FloatingSceneFixture
    var body: some View {
        CrowRootView().environment(model).environment(\.crowFloatingMode, state.controller.modeBinding($state.floating))
            .frame(minWidth: state.floating ? FloatingWindowController.minimumSize.width : 640,
                   minHeight: state.floating ? FloatingWindowController.minimumSize.height : 400)
            .background(WindowCloseGuard(model: model, floating: state.floating, floatingController: state.controller))
    }
}

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
    @MainActor func testFinderDropRoutesIntoLocalAndRemoteTerminalsWithoutSubmitting() throws {
        let urls = [URL(fileURLWithPath: "/tmp/한글 폴더/a's $(touch nope).md"), URL(fileURLWithPath: "/tmp/Folder")]
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.writeObjects(urls.map { $0 as NSURL })
        // Finder can include a preview: actual file URLs must win.
        board.setData(Self.png, forType: .png)
        for remote in [false, true] {
            let session = TerminalSession(id: UUID(), workspace: .init(name: "Drop", kind: remote ? .remote(hostID: HostID(), path: "/tmp") : .local, connection: .connected), directory: "/tmp", remote: nil, fontSize: 14)
            defer { session.stop() }
            session.running = true; session.view.feed(text: "\u{1b}[?2004h")
            var sent: [UInt8] = []; session.onBytes = { sent += $0 }
            var focused = false; session.onFileDropFocus = { focused = true }
            let drag = FileDropDraggingInfo(board)
            XCTAssertTrue(session.view.registeredDraggedTypes.contains(.fileURL))
            XCTAssertEqual(session.view.draggingEntered(drag), .copy)
            XCTAssertTrue(session.view.prepareForDragOperation(drag))
            XCTAssertTrue(session.view.performDragOperation(drag))
            XCTAssertTrue(focused)
            XCTAssertEqual(String(decoding: sent, as: UTF8.self), "\u{1b}[200~" + urls.map { ClipboardImage.pastedPath($0.path) }.joined() + "\u{1b}[201~")
            XCTAssertFalse(sent.contains(13)); XCTAssertFalse(sent.contains(10))
            sent = []; session.running = false
            XCTAssertFalse(session.view.performDragOperation(drag)); XCTAssertTrue(sent.isEmpty)
        }
    }

    @MainActor func testMixedImageDropUploadsEveryImageInOrderAndRejectsChangedTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-drop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("첫 이미지.png"), second = root.appendingPathComponent("Second.png"), note = root.appendingPathComponent("Note.md")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try image.write(to: first); try image.write(to: second)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.writeObjects([first, note, second].map { $0 as NSURL })
        let session = TerminalSession(id: UUID(), workspace: .init(name: "Remote", kind: .remote(hostID: HostID(), path: "/tmp"), connection: .connected), directory: "/tmp", remote: nil, fontSize: 14)
        defer { session.stop() }; session.running = true
        var context = "server-one", uploads = 0, sent: [UInt8] = []
        session.imagePasteContext = { context }; session.onBytes = { sent += $0 }
        session.uploadImage = { data, target in
            try ClipboardImage.validate(data); XCTAssertEqual(target, "server-one")
            uploads += 1; return "/remote/image \(uploads).png"
        }
        XCTAssertTrue(session.view.performDragOperation(FileDropDraggingInfo(board)))
        for _ in 0..<200 where session.imagePasteInProgress { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(uploads, 2)
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), ["/remote/image 1.png", note.path, "/remote/image 2.png"].map(ClipboardImage.pastedPath).joined())
        XCTAssertFalse(sent.contains(13)); XCTAssertFalse(sent.contains(10))
        sent = []; session.uploadImage = { _, _ in context = "server-two"; return "/old/image.png" }
        XCTAssertTrue(session.dropFiles(from: board))
        for _ in 0..<200 where session.imagePasteInProgress { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(session.imagePasteMessage?.contains("changed") == true)
        try Data("invalid PNG".utf8).write(to: first)
        XCTAssertTrue(session.dropFiles(from: board))
        for _ in 0..<200 where session.imagePasteInProgress { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(session.imagePasteMessage?.contains("failed") == true)
    }

    @MainActor func testLocalTmuxImagePasteSavesReadableImageAndUsesBracketedPaste() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-local-image-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.newTerminal()
        let id = try XCTUnwrap(model.current.snapshot.selectedTerminalID)
        let session = model.terminal(id, in: model.current)
        session.tmuxLocation = .init(sessionID: "$0", windowID: "@0", paneID: "%0")
        session.running = true
        session.view.feed(text: "\u{1b}[?2004h")
        var sent: [UInt8] = []
        session.onBytes = { sent += $0 }
        XCTAssertNotNil(session.imagePasteContext?(), "Local tmux must have an image destination")
        XCTAssertTrue(session.pasteImage(Self.png))
        for _ in 0..<100 where session.imagePasteInProgress { try await Task.sleep(for: .milliseconds(10)) }
        let text = String(decoding: sent, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("\u{1b}[200~")); XCTAssertTrue(text.hasSuffix(" \u{1b}[201~"))
        let path = String(text.dropFirst(6).dropLast(7))
        let file = URL(fileURLWithPath: path)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: file), Self.png)
        XCTAssertFalse(sent.contains(13)); XCTAssertFalse(sent.contains(10))
    }

    @MainActor func testReverseAgentImagePasteUploadsToReverseHostNotClientWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-image-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var agent = AgentTerminal(provider: .codex, directory: model.current.snapshot.rootPath)
        agent.reverseHostID = HostID(rawValue: UUID())
        model.current.snapshot.agentTerminals.append(agent)
        model.current.snapshot.terminalIDs.append(agent.id)
        model.current.snapshot.selectedTerminalID = agent.id
        let session = model.terminal(agent.id, in: model.current)
        session.running = true
        var sent: [UInt8] = []
        session.onBytes = { sent += $0 }
        XCTAssertEqual(session.imagePasteContext?(), "reverse:" + agent.reverseHostID!.rawValue.uuidString)
        XCTAssertTrue(session.pasteImage(Self.png))
        for _ in 0..<100 where session.imagePasteInProgress { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(session.imagePasteMessage?.contains("Connect Reverse SSH") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent.directory + "/.crow/clipboard"))
    }

    @MainActor func testDedicatedReverseAgentSessionWiresImagePasteOntoDirectSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-direct-image-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var agent = AgentTerminal(provider: .codex, directory: model.current.snapshot.rootPath)
        agent.reverseHostID = HostID(rawValue: UUID())
        model.current.snapshot.agentTerminals.append(agent)
        model.current.snapshot.terminalIDs.append(agent.id)
        let execution = Workspace(name: "Server", kind: .remote(hostID: agent.reverseHostID!, path: "/server"), connection: .connected)
        let session = TerminalSession(id: agent.id, workspace: execution, directory: "/server", remote: nil, fontSize: 14)
        session.running = true
        XCTAssertNil(session.imagePasteContext?())
        XCTAssertNil(session.uploadImage)
        model.configureTerminalImagePaste(session, id: agent.id, in: model.current)
        model.current.terminals[agent.id] = session
        var sent: [UInt8] = []
        session.onBytes = { sent += $0 }
        XCTAssertEqual(session.imagePasteContext?(), "reverse:" + agent.reverseHostID!.rawValue.uuidString)
        XCTAssertTrue(session.pasteImage(Self.png))
        for _ in 0..<100 where session.imagePasteInProgress { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(session.imagePasteMessage?.contains("Connect Reverse SSH") == true)
    }

    @MainActor func testTmuxReverseAgentImagePasteUsesReverseHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-tmux-reverse-image-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.newTerminal()
        let id = try XCTUnwrap(model.current.snapshot.selectedTerminalID)
        let session = model.terminal(id, in: model.current)
        session.running = true
        session.tmuxLocation = .init(sessionID: "$0", windowID: "@0", paneID: "%9")
        var agent = AgentTerminal(provider: .codex, directory: model.current.snapshot.rootPath)
        agent.reverseHostID = HostID(rawValue: UUID())
        session.tmuxReverseAgents["%9"] = agent
        var sent: [UInt8] = []
        session.onBytes = { sent += $0 }
        XCTAssertEqual(session.imagePasteContext?(), "reverse:" + agent.reverseHostID!.rawValue.uuidString)
        XCTAssertTrue(session.pasteImage(Self.png))
        for _ in 0..<100 where session.imagePasteInProgress { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(session.imagePasteMessage?.contains("Connect Reverse SSH") == true)
    }

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

    @MainActor func testFloatingSceneRestoresRegularFrameAfterLayoutChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-floating-restore-" + UUID().uuidString)
        let model = AppModel(vaultURL: root), state = FloatingSceneFixture()
        let hosting = NSHostingView(rootView: FloatingSceneTestView(model: model, state: state))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 750),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderBack(nil)
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let original = window.frame
        for _ in 0..<2 {
            state.controller.modeBinding(Binding(get: { state.floating }, set: { state.floating = $0 })).wrappedValue = true
            try await Task.sleep(for: .milliseconds(150))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.level, .floating)
            window.setFrame(NSRect(x: 200, y: 200, width: 360, height: 300), display: true)
            (window.delegate as? WindowCloseGuard.GuardView)?.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
            state.controller.modeBinding(Binding(get: { state.floating }, set: { state.floating = $0 })).wrappedValue = false
            try await Task.sleep(for: .milliseconds(150))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.level, .normal)
            XCTAssertEqual(window.frame, original, "Restoration must survive the SwiftUI content replacement")
        }
    }

    @MainActor func testFloatingCapturesFrameBeforeContentResizesAndSurvivesGuardReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-floating-recreate-" + UUID().uuidString)
        let model = AppModel(vaultURL: root), controller = FloatingWindowController()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        window.contentView = WindowCloseGuard.GuardView(model: model, floatingController: controller)
        let original = window.frame
        var floating = false
        let binding = controller.modeBinding(Binding(get: { floating }, set: { floating = $0 }))
        binding.wrappedValue = true
        // SwiftUI can apply the smaller content's size before updating its guard.
        window.setFrame(NSRect(x: 300, y: 300, width: 420, height: 560), display: false)
        let compactGuard = WindowCloseGuard.GuardView(model: model, floatingController: controller)
        compactGuard.floating = true; window.contentView = compactGuard
        binding.wrappedValue = false
        window.contentView = WindowCloseGuard.GuardView(model: model, floatingController: controller)
        // A trailing hosting-layout resize must not win over restoration.
        window.setFrame(NSRect(x: 300, y: 300, width: 640, height: 400), display: false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(window.frame, original)
        XCTAssertEqual(window.level, .normal)
    }

    @MainActor func testHoverResizeNotifiesGuardWithoutUnrecognizedSelector() throws {
        final class ResizeSpy: NSObject, NSWindowDelegate {
            var resized = false
            func windowDidResize(_ notification: Notification) { resized = true }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-hover-resize-" + UUID().uuidString)
        let model = AppModel(vaultURL: root), controller = FloatingWindowController()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let spy = ResizeSpy()
        window.delegate = spy
        let guardView = WindowCloseGuard.GuardView(model: model, floatingController: controller)
        window.contentView = guardView
        guardView.floating = true
        controller.apply(true, to: window)
        window.setFrame(NSRect(x: 80, y: 80, width: 420, height: 320), display: true)
        XCTAssertTrue(spy.resized)
        guardView.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        XCTAssertTrue(spy.resized)
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

    @MainActor func testTerminalViewLeavesWindowResizeBorderToAppKit() {
        let session = TerminalSession(id: UUID(), workspace: Workspace(name: "Resize", kind: .local, connection: .local), directory: "/tmp", remote: nil, fontSize: 14)
        defer { session.stop() }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 420, height: 300),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        session.view.frame = NSRect(origin: .zero, size: window.contentView!.bounds.size)
        window.contentView = session.view
        defer { window.close() }
        XCTAssertEqual(session.view.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertNil(session.view.hitTest(NSPoint(x: 1, y: session.view.bounds.midY)))
        XCTAssertNil(session.view.hitTest(NSPoint(x: session.view.bounds.maxX - 1, y: session.view.bounds.midY)))
        XCTAssertNotNil(session.view.hitTest(NSPoint(x: session.view.bounds.midX, y: session.view.bounds.midY)))
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

#if os(macOS)
@MainActor private final class FileDropDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow? = nil
    let draggingLocation = NSPoint.zero
    let draggingSourceOperationMask: NSDragOperation = .copy
    let draggedImageLocation = NSPoint.zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none
    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
#endif
