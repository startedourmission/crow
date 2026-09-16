import XCTest
import SwiftUI
import CrowCore
@testable import Crow
#if os(iOS)
import UIKit
import WebKit

@MainActor private final class WorkspaceDragSessionFixture: NSObject, UIDragSession, UIDropSession {
    var items: [UIDragItem] = []
    var localContext: Any?
    var point = CGPoint.zero
    var local = true
    var localDragSession: (any UIDragSession)? { local ? self : nil }
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { true }
    nonisolated let progress = Progress(totalUnitCount: 1)
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .none
    func location(in view: UIView) -> CGPoint { point }
    func hasItemsConforming(toTypeIdentifiers identifiers: [String]) -> Bool {
        items.contains { item in identifiers.contains { item.itemProvider.hasItemConformingToTypeIdentifier($0) } }
    }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { false }
    func loadObjects(ofClass aClass: any NSItemProviderReading.Type, completion: @escaping ([any NSItemProviderReading]) -> Void) -> Progress {
        completion([]); return progress
    }
}

final class IOSEditorIntegrationTests: XCTestCase {
    @MainActor func testTabDropRoutesAboveSourceAndRenderedEditorsWithoutInsertingContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-ipad-drag-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let buffer = try XCTUnwrap(model.selectedBuffer)
        model.updateBufferText(buffer.id, "# Drag target\n\nKeep this unsaved document.\n")
        let original = try XCTUnwrap(model.selectedBuffer?.text)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 1100, height: 800)
        window.rootViewController = UIHostingController(rootView: RegularWorkspaceView().environment(model))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; model.shutdown(); try? FileManager.default.removeItem(at: root) }
        func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
        }
        for preview in [false, true] {
            model.markdownPreviewEnabled = preview
            try await Task.sleep(for: .milliseconds(400))
            let source = try XCTUnwrap(descendants(window, of: IOSWorkspaceTabDragView.self).first { $0.payload?.tab == .file(buffer.id) })
            let interaction = try XCTUnwrap(source.interactions.compactMap { $0 as? UIDragInteraction }.first)
            let session = WorkspaceDragSessionFixture()
            session.items = source.dragInteraction(interaction, itemsForBeginning: session)
            XCTAssertEqual(session.items.count, 1)
            XCTAssertNil(model.draggedTab, "A cancelled lift must not leave drop shields active")
            source.dragInteraction(interaction, sessionWillBegin: session)
            try await Task.sleep(for: .milliseconds(100))
            let target = try XCTUnwrap(descendants(window, of: IOSWorkspacePaneDropView.self).first { $0.paneID == source.payload?.paneID })
            let drop = try XCTUnwrap(target.interactions.compactMap { $0 as? UIDropInteraction }.first)
            session.point = CGPoint(x: target.bounds.midX, y: target.bounds.midY)
            XCTAssertTrue(window.hitTest(target.convert(session.point, to: window), with: nil) === target,
                "Workspace drops must be above the native editor's text/attachment destination")
            XCTAssertEqual(target.dropInteraction(drop, sessionDidUpdate: session).operation, .move)
            XCTAssertEqual(target.destination(at: CGPoint(x: target.bounds.midX, y: 10)).0, .center, "Tab strip drops reorder rather than split")
            for (point, edge) in [(CGPoint(x: 1, y: target.bounds.midY), PanePlacement.left),
                (CGPoint(x: target.bounds.width - 1, y: target.bounds.midY), .right),
                (CGPoint(x: target.bounds.midX, y: 40), .top),
                (CGPoint(x: target.bounds.midX, y: target.bounds.height - 1), .bottom)] {
                XCTAssertEqual(target.destination(at: point).0, edge)
            }
            session.local = false
            XCTAssertNil(target.acceptedPayload(session), "External items cannot masquerade as local tabs")
            session.local = true
            source.dragInteraction(interaction, session: session, didEndWith: .cancel)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil(model.draggedTab)
            XCTAssertNil(target.hitTest(session.point, with: nil), "Cancelling must immediately return input to the editor")
            XCTAssertEqual(model.buffers.first { $0.id == buffer.id }?.text, original)
        }
        let source = try XCTUnwrap(descendants(window, of: IOSWorkspaceTabDragView.self).first { $0.payload?.tab == .file(buffer.id) })
        let target = try XCTUnwrap(descendants(window, of: IOSWorkspacePaneDropView.self).first { $0.paneID != source.payload?.paneID })
        let terminalID = try XCTUnwrap(model.current.snapshot.selectedTerminalID)
        let terminal = model.terminal(terminalID, in: model.current)
        let session = WorkspaceDragSessionFixture()
        let drag = try XCTUnwrap(source.interactions.compactMap { $0 as? UIDragInteraction }.first)
        session.items = source.dragInteraction(drag, itemsForBeginning: session)
        source.dragInteraction(drag, sessionWillBegin: session)
        session.point = CGPoint(x: target.bounds.width - 1, y: target.bounds.midY)
        target.dropInteraction(try XCTUnwrap(target.interactions.compactMap { $0 as? UIDropInteraction }.first), performDrop: session)
        XCTAssertNil(model.draggedTab)
        XCTAssertNotEqual(model.current.snapshot.layout?.panes.first { $0.tabs.contains(.file(buffer.id)) }?.id, source.payload?.paneID)
        XCTAssertTrue(model.terminal(terminalID, in: model.current) === terminal)
        XCTAssertEqual(model.buffers.first { $0.id == buffer.id }?.text, original)
        XCTAssertTrue(model.buffers.first { $0.id == buffer.id }?.isDirty == true)
    }

    @MainActor func testPhoneKeyboardRestoresSourceAndMarkdownEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-ios-editor-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let id = try XCTUnwrap(model.selectedBufferID)
        model.updateBufferText(id, "# Keyboard\n\nKeep this text.\n")
        model.compactSurface = .editor
        let keyboard = PhoneKeyboardFocus()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: CompactWorkspaceView(keyboard: keyboard).environment(model))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; model.shutdown(); try? FileManager.default.removeItem(at: root) }
        func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
        }
        try await Task.sleep(for: .milliseconds(300))
        let editor = try XCTUnwrap(descendants(window, of: NumberedTextView.self).first)
        editor.selectedRange = NSRange(location: 5, length: 0)
        for _ in 0..<2 {
            keyboard.show(for: .editor)
            XCTAssertTrue(editor.isFirstResponder)
            XCTAssertEqual(editor.selectedRange.location, 5)
            editor.resignFirstResponder()
            XCTAssertFalse(editor.isFirstResponder)
        }
        keyboard.show(for: .editor)
        try await Task.sleep(for: .milliseconds(400))
        let terminalID = try XCTUnwrap(model.current.snapshot.selectedTerminalID)
        let terminal = try XCTUnwrap(model.current.terminals[terminalID])
        let hidden = expectation(description: "Document/terminal switching must not hide the keyboard")
        hidden.isInverted = true
        let observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in hidden.fulfill() }
        model.compactSurface = .terminal
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(terminal.view.isFirstResponder)
        XCTAssertFalse(editor.isFirstResponder)
        model.compactSurface = .editor
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertEqual(editor.selectedRange.location, 5)
        await fulfillment(of: [hidden], timeout: 0.2)
        NotificationCenter.default.removeObserver(observer)
        editor.resignFirstResponder()
        model.compactSurface = .terminal
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(terminal.view.isFirstResponder, "A hidden keyboard must stay hidden when switching screens")
        model.compactSurface = .editor
        model.markdownPreviewEnabled = true
        try await Task.sleep(for: .milliseconds(300))
        let web = try XCTUnwrap(descendants(window, of: WKWebView.self).first)
        for _ in 0..<100 {
            if (try? await web.callAsyncJavaScript("return !!document.querySelector('[contenteditable=true]')", arguments: [:], in: nil, contentWorld: .defaultClient)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        for _ in 0..<2 {
            keyboard.show(for: .editor)
            let focused = try await web.callAsyncJavaScript("return document.activeElement?.isContentEditable", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
            XCTAssertEqual(focused, true)
            _ = try await web.callAsyncJavaScript("document.activeElement.blur(); return true", arguments: [:], in: nil, contentWorld: .defaultClient)
            window.endEditing(true)
        }
        keyboard.show(for: .editor)
        try await Task.sleep(for: .milliseconds(300))
        let modeHidden = expectation(description: "Switching Markdown render modes must not hide the keyboard")
        modeHidden.isInverted = true
        let modeObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in modeHidden.fulfill() }
        for _ in 0..<2 {
            model.markdownPreviewEnabled = false
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(editor.isFirstResponder, "Source mode must receive the existing keyboard focus")
            model.markdownPreviewEnabled = true
            try await Task.sleep(for: .milliseconds(200))
            let focused = try await web.callAsyncJavaScript("return document.activeElement?.isContentEditable", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
            XCTAssertEqual(focused, true, "Rendered mode must receive the existing keyboard focus")
        }
        await fulfillment(of: [modeHidden], timeout: 0.2)
        NotificationCenter.default.removeObserver(modeObserver)
        window.endEditing(true)
        model.markdownPreviewEnabled = false
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(editor.isFirstResponder, "Switching modes must not summon a keyboard the user hid")
        XCTAssertEqual(model.selectedBuffer?.text, "# Keyboard\n\nKeep this text.\n")
        model.markdownPreviewEnabled = true
        try await Task.sleep(for: .milliseconds(200))
        keyboard.show(for: .editor)
        let markdown = try XCTUnwrap(web as? CrowMarkdownWebView)
        XCTAssertTrue(markdown.inputAccessoryView is CrowKeyboardAccessory)
        _ = try await web.callAsyncJavaScript("window.crowMarkdown.jumpHeading(0); return true", arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertTrue(keyboard.insert("Snippet ", for: .editor))
        for _ in 0..<100 where model.selectedBuffer?.text.contains("Snippet") != true { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.selectedBuffer?.text, "# Snippet Keyboard\n\nKeep this text.\n")
        markdown.keyboardAccessory.press(KeyboardBarKey(key: "Tab"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.selectedBuffer?.text.contains("Snippet     Keyboard") == true)
    }
}
#endif
#if os(macOS)
import AppKit
import WebKit

final class EditorIntegrationTests: XCTestCase {
    @MainActor func testMarkdownFrontmatterWikiLinksAndSingleClickPreserveSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-note-preview-" + UUID().uuidString)
        let model = AppModel(vaultURL: root), id = try XCTUnwrap(model.selectedBufferID)
        let prefix = "---\n# Preserve this comment\ntags: [work, notes]\ncompleted: false\ntitle: '<script>alert(1)</script>'\n---\n"
        let original = prefix + "# Title\n\nSee [[Other|다른 노트]] and [website](https://example.com).\n\nEditable paragraph\n"
        model.updateBufferText(id, original)
        let binding = Binding<String>(get: { model.locate(id)!.0.snapshot.buffers[model.locate(id)!.1].text }, set: { model.updateBufferText(id, $0) })
        var opened: [String] = []
        let hosting = NSHostingView(rootView: MarkdownPreviewView(text: binding, fontSize: 15, onOpenLink: { opened.append($0) }, noteLinksEnabled: true))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderBack(nil)
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        for _ in 0..<100 where descendants(hosting, of: WKWebView.self).isEmpty { try await Task.sleep(for: .milliseconds(30)) }
        let web = try XCTUnwrap(descendants(hosting, of: WKWebView.self).first)
        func js(_ script: String) async throws -> Any? { try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) }
        for _ in 0..<100 {
            if (try? await js("return document.querySelectorAll('.frontmatter tbody tr').length")) as? Int == 3 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let rows = try await js("return document.querySelectorAll('.frontmatter tbody tr').length") as? Int
        XCTAssertEqual(rows, 3)
        let scripts = try await js("return document.querySelectorAll('.frontmatter script').length") as? Int
        XCTAssertEqual(scripts, 0)
        let alias = try await js("return document.querySelector('a[data-wikilink]').textContent") as? String
        XCTAssertEqual(alias, "다른 노트")
        _ = try await js("document.querySelector('a[href=\"https://example.com\"]').click(); document.querySelector('a[data-wikilink]').click()")
        for _ in 0..<30 where opened.count < 2 { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(opened, ["https://example.com", "Other"])
        _ = try await js("""
        const paragraph=[...document.querySelectorAll('.tiptap p')].find(p=>p.textContent==='Editable paragraph');
        const range=document.createRange(); range.selectNodeContents(paragraph); range.collapse(false);
        const selection=window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
        document.querySelector('.tiptap').focus(); window.crowMarkdown.insertText(' edited');
        """)
        for _ in 0..<30 where model.selectedBuffer?.text == original { try await Task.sleep(for: .milliseconds(30)) }
        let edited = try XCTUnwrap(model.selectedBuffer).text
        XCTAssertTrue(edited.hasPrefix(prefix)); XCTAssertTrue(edited.contains("[[Other|다른 노트]]")); XCTAssertTrue(edited.contains("Editable paragraph edited"))
    }

    @MainActor func testLiveMarkdownEditsComposeUndoAndSaveWithoutReloading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-live-markdown-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let id = try XCTUnwrap(model.selectedBufferID)
        let original = "# 제목\n\nA **bold** paragraph\n\n```swift\nlet x = 1\n```\n\n| A | B |\n|---|---|\n| x | y |\n"
        model.updateBufferText(id, original)
        var saves = 0
        let binding = Binding<String>(get: { model.locate(id)!.0.snapshot.buffers[model.locate(id)!.1].text },
            set: { model.updateBufferText(id, $0) })
        let hosting = NSHostingView(rootView: MarkdownPreviewView(text: binding, fontSize: 15, onSave: { saves += 1 }))
        let window = NSWindow(contentRect: NSRect(x: 140, y: 180, width: 800, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(400))
        let web = try XCTUnwrap(descendants(hosting, of: WKWebView.self).first)
        func js(_ script: String) async throws -> Any? {
            try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
        }
        for _ in 0..<100 {
            if (try? await js("return !!document.querySelector('.tiptap strong')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertFalse(web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        _ = try await js("""
            window.originalBody = document.body;
            window.originalEditor = document.querySelector('.tiptap');
            const text = document.querySelector('strong').firstChild;
            const range = document.createRange(); range.selectNodeContents(text);
            const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            window.originalEditor.focus(); document.execCommand('insertText', false, '한글');
            return true;
            """)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(binding.wrappedValue, original.replacingOccurrences(of: "bold", with: "한글"))
        XCTAssertTrue(try XCTUnwrap(model.selectedBuffer).isDirty)
        let stable = try await js("return document.querySelector('.tiptap') === window.originalEditor && document.body === window.originalBody && !document.querySelector('textarea')") as? Bool
        XCTAssertEqual(stable, true, "Rendered text must remain directly editable without a source box or reload")
        let rendered = try await js("return document.querySelector('strong').textContent") as? String
        XCTAssertEqual(rendered, "한글")
        _ = try await js("document.querySelector('.tiptap').dispatchEvent(new KeyboardEvent('keydown', {key:'s', code:'KeyS', keyCode:83, metaKey:true, bubbles:true})); return true")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(saves, 1)
        _ = try await js("window.crowMarkdown.jumpHeading(0); return true")
        window.makeFirstResponder(web)
        let snippetTarget = try XCTUnwrap(MacSnippetTarget(responder: window.firstResponder))
        snippetTarget.insert("Snippet ")
        for _ in 0..<100 where !binding.wrappedValue.contains("Snippet") { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(binding.wrappedValue.hasPrefix("# Snippet 제목\n"))
    }

    @MainActor func testRealMouseDragMovesTabWithoutMovingWindow() async throws {
        guard ProcessInfo.processInfo.environment["CROW_ALLOW_DESKTOP_INPUT"] == "1" else {
            throw XCTSkip("Desktop input is opt-in. Use Tools/run-native-smoke.sh for cursor-safe native checks.")
        }
        let canPost = CGPreflightPostEventAccess()
        guard canPost || FileManager.default.fileExists(atPath: "/tmp/crow-native-drag-enabled") else {
            throw XCTSkip("Mouse event access or the external native-event harness is required")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-real-drag-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let hosting = NSHostingView(rootView: CrowRootView().environment(model).background(WindowCloseGuard(model: model)))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 180, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { WorkspaceDragRouter.shared.endDrag(); window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(400))
        let file = try XCTUnwrap(model.selectedBufferID)
        let source = try XCTUnwrap(descendants(hosting, of: WorkspaceTabDragView.self).first { $0.payload?.tab == .file(file) })
        let sourcePane = try XCTUnwrap(source.payload?.paneID)
        let target = try XCTUnwrap(descendants(hosting, of: WorkspacePaneDropView.self).first { $0.paneID != sourcePane })
        let destinationPane = target.paneID
        func screenPoint(_ point: NSPoint, in view: NSView) -> CGPoint {
            let screen = window.convertPoint(toScreen: view.convert(point, to: nil))
            return CGPoint(x: screen.x, y: CGDisplayBounds(CGMainDisplayID()).height - screen.y)
        }
        let start = screenPoint(NSPoint(x: source.bounds.midX, y: source.bounds.midY), in: source)
        let end = screenPoint(NSPoint(x: target.bounds.midX, y: target.bounds.midY), in: target)
        let originalFrame = window.frame
        let originalMouse = CGEvent(source: nil)?.location
        defer { if let originalMouse { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: originalMouse, mouseButton: .left)?.post(tap: .cghidEventTap) } }
        func post(_ type: CGEventType, at point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        if !canPost {
            let request = URL(fileURLWithPath: "/tmp/crow-native-drag-request.json")
            defer { try? FileManager.default.removeItem(at: request) }
            try JSONSerialization.data(withJSONObject: ["startX": start.x, "startY": start.y,
                "endX": end.x, "endY": end.y, "time": Date().timeIntervalSince1970]).write(to: request, options: .atomic)
            try await Task.sleep(for: .seconds(3))
        } else {
        post(.mouseMoved, at: start)
        try await Task.sleep(for: .milliseconds(80))
        post(.leftMouseDown, at: start)
        try await Task.sleep(for: .milliseconds(100))
        for step in 1...16 {
            let amount = CGFloat(step) / 16
            post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * amount, y: start.y + (end.y - start.y) * amount))
            try await Task.sleep(for: .milliseconds(35))
        }
        post(.leftMouseUp, at: end)
        try await Task.sleep(for: .milliseconds(400))
        }
        XCTAssertEqual(window.frame.origin.x, originalFrame.origin.x, accuracy: 1)
        XCTAssertEqual(window.frame.origin.y, originalFrame.origin.y, accuracy: 1)
        XCTAssertTrue(model.current.snapshot.layout?.panes.first(where: { $0.id == destinationPane })?.tabs.contains(.file(file)) == true,
            "Real mouse dragging must move the tab without moving the window")
        XCTAssertNil(model.draggedTab)
    }
    @MainActor private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }
    @MainActor func testNativeTabAndExplorerDropTargetsReceiveDragAboveEditors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-native-drop-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let folder = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await model.current.explorer.refresh()
        let hosting = NSHostingView(rootView: CrowRootView().environment(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(300))
        let file = try XCTUnwrap(model.selectedBuffer)
        let source = try XCTUnwrap(descendants(hosting, of: WorkspaceTabDragView.self).first { $0.payload?.tab == .file(file.id) })
        let sourcePoint = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: hosting)
        XCTAssertTrue(WorkspaceDragRouter.shared.source(at: hosting.convert(sourcePoint, to: nil), in: window) === source)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: hosting.convert(sourcePoint, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: down.locationInWindow,
            modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        XCTAssertNil(WorkspaceDragRouter.shared.route(down), "The native source must consume the press before SwiftUI's gestures")
        XCTAssertTrue(window.isMovable, "A tab press must not disable OS window movement")
        XCTAssertFalse(source.mouseDownCanMoveWindow, "Tab input belongs to the control, not window movement")
        XCTAssertNil(WorkspaceDragRouter.shared.route(up))
        XCTAssertTrue(window.isMovable, "A click must preserve normal window movement")
        XCTAssertEqual(model.current.snapshot.layout?.activePane?.selected, .file(file.id))
        let drag = try XCTUnwrap(source.payload)
        model.draggedTab = drag
        WorkspaceDragRouter.shared.beginDrag(in: window, model: model)
        XCTAssertTrue(window.isMovable, "A tab drag must not lock the window")
        defer { WorkspaceDragRouter.shared.endDrag() }
        try await Task.sleep(for: .milliseconds(80))
        let target = try XCTUnwrap(descendants(hosting, of: WorkspacePaneDropView.self).first { $0.paneID != drag.paneID })
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(try JSONEncoder().encode(drag), forType: WorkspacePaneDropView.pasteboardType)
        let info = TestDraggingInfo(pasteboard: board, window: window,
            point: target.convert(NSPoint(x: target.bounds.width - 10, y: target.bounds.midY), to: nil))
        XCTAssertFalse(target.isHidden)
        let surface = try XCTUnwrap(WorkspaceDragRouter.shared.dropSurface)
        XCTAssertTrue(surface.superview === hosting.superview)
        XCTAssertTrue(surface.destination(at: info.draggingLocation) === target)
        XCTAssertEqual(surface.draggingEntered(info), .move)
        XCTAssertTrue(surface.prepareForDragOperation(info))
        XCTAssertTrue(surface.performDragOperation(info))
        XCTAssertEqual(model.current.snapshot.layout?.activePane?.selected, .file(file.id))
        model.draggedTab = nil
        WorkspaceDragRouter.shared.endDrag()
        XCTAssertTrue(window.isMovable)
        XCTAssertNil(target.payload(from: board), "Stale or foreign pasteboard payloads must not move tabs")

        try await Task.sleep(for: .milliseconds(80))
        let fileSource = try XCTUnwrap(descendants(hosting, of: WorkspaceTabDragView.self).first { $0.filePayload?.path == file.path })
        let fileSourcePoint = fileSource.convert(NSPoint(x: fileSource.bounds.midX, y: fileSource.bounds.midY), to: hosting)
        XCTAssertTrue(WorkspaceDragRouter.shared.source(at: hosting.convert(fileSourcePoint, to: nil), in: window) === fileSource,
            "File rows must also receive native mouse dragging")
        let fileDrag = ExplorerFileDrag(workspaceID: model.selectedWorkspaceID, path: file.path, isDirectory: false)
        model.draggedFile = fileDrag
        WorkspaceDragRouter.shared.beginDrag(in: window, model: model)
        try await Task.sleep(for: .milliseconds(100))
        let row = try XCTUnwrap(descendants(hosting, of: WorkspaceTabDragView.self).first { $0.filePayload?.path == folder.path })
        let drop = try XCTUnwrap(descendants(hosting, of: ExplorerFileDropView.self).first)
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        board.clearContents()
        board.setData(try JSONEncoder().encode(fileDrag), forType: ExplorerFileDropView.pasteboardType)
        let fileInfo = TestDraggingInfo(pasteboard: board, window: window, point: point)
        XCTAssertEqual(drop.destination(at: drop.convert(point, from: nil)), folder.path)
        let fileSurface = try XCTUnwrap(WorkspaceDragRouter.shared.dropSurface)
        XCTAssertTrue(fileSurface.destination(at: point) === drop)
        XCTAssertEqual(fileSurface.draggingEntered(fileInfo), .move)
        XCTAssertTrue(fileSurface.performDragOperation(fileInfo))
        for _ in 0..<100 where model.selectedBuffer?.path == file.path { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selectedBuffer?.path, folder.appendingPathComponent(file.title).path)
        XCTAssertNil(model.errorMessage)
        model.draggedFile = nil
        XCTAssertNil(drop.payload(from: board))
    }

    @MainActor func testFullHeightWindowChromeAndMarkdownPreviewRender() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-chrome-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let hosting = NSHostingView(rootView: CrowRootView().environment(model).background(WindowCloseGuard(model: model)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertNil(window.toolbar)
        XCTAssertFalse(try XCTUnwrap(window.standardWindowButton(.closeButton)).isHidden)
        let topTab = try XCTUnwrap(descendants(hosting, of: WorkspaceTabDragView.self).first { $0.payload?.tab == model.selectedBufferID.map(WorkspaceTab.file) })
        let top = topTab.convert(topTab.bounds, to: hosting)
        XCTAssertLessThan(top.minY, 40, "Tab strip should reach the top, without a title bar or horizontal vault strip")
        let chrome = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: chrome)
        let scale = CGFloat(chrome.pixelsWide) / hosting.bounds.width
        for x in [CrowTheme.activityWidth + 4, top.minX - 10] {
            let color = try XCTUnwrap(chrome.colorAt(x: Int(x * scale), y: Int(20 * scale))?.usingColorSpace(.sRGB))
            XCTAssertLessThan(color.redComponent, 0.99, "Vault header gutters must not be white")
            XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.015)
            XCTAssertGreaterThan(color.alphaComponent, 0.99)
        }

        let preview = NSHostingView(rootView: MarkdownPreviewView(text: .constant("# Markdown Preview\n\n## 한국어 제목\n\n**Bold**, *italic* and `inline code`.\n\n- First item\n- Second item\n\n> Block quote\n\n```swift\nlet message = \"Hello\"\n```\n\n| Name | Value |\n| --- | --- |\n| Crow | Works |"), fontSize: 15))
        window.contentView = preview
        try await Task.sleep(for: .milliseconds(500))
        let webView = try XCTUnwrap(descendants(preview, of: WKWebView.self).first)
        for _ in 0..<100 where webView.isLoading { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(webView.isLoading)
        XCTAssertEqual(webView.url?.absoluteString, "about:blank")
        XCTAssertFalse(webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let image = try await webView.takeSnapshot(configuration: nil)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/crow-markdown-preview.png"))
    }
    @MainActor func testTerminalFillsWorkspaceAfterLastFileClosesAndSurvivesTabMove() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-unified-tabs-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let hosting = NSHostingView(rootView: CrowRootView().environment(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(300))
        let id = try XCTUnwrap(model.current.snapshot.selectedTerminalID)
        let session = model.terminal(id, in: model.current)
        let initialHeight = session.view.bounds.height
        let layout = try XCTUnwrap(model.current.snapshot.layout)
        let source = try XCTUnwrap(layout.panes.first { $0.tabs.contains(.terminal(id)) })
        let target = try XCTUnwrap(layout.panes.first { $0.id != source.id })
        XCTAssertTrue(model.moveTab(.init(workspaceID: model.selectedWorkspaceID, paneID: source.id, tab: .terminal(id)),
            to: target.id, placement: .right))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.terminal(id, in: model.current) === session)
        XCTAssertTrue(session.running)
        model.discardBuffer(try XCTUnwrap(model.selectedBufferID))
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.current.snapshot.layout?.panes.count, 1)
        XCTAssertGreaterThan(session.view.bounds.height, initialHeight * 1.5)
        // The terminal fills the editor area; the visible explorer and inspector
        // continue to reserve their own width in the 1280-point test window.
        XCTAssertGreaterThan(session.view.bounds.width, 600)
        XCTAssertTrue(session.running)
    }
    @MainActor func testResizeHandlesUseStableCoordinatesAndDirectionalCursors() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let handle = ResizeHandleView(frame: NSRect(x: 100, y: 200, width: 500, height: 6))
        window.contentView?.addSubview(handle)
        var changes: [CGFloat] = []
        var ended = 0
        handle.onDrag = { changes.append($0) }
        handle.onEnd = { ended += 1 }
        func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        handle.mouseDown(with: try event(.leftMouseDown, x: 200, y: 200))
        XCTAssertEqual(NSCursor.current, .resizeUpDown)
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 200, y: 180))
        handle.setFrameOrigin(NSPoint(x: 100, y: 180))
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 200, y: 150))
        XCTAssertEqual(changes, [20, 50])
        handle.mouseUp(with: try event(.leftMouseUp, x: 200, y: 150))
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(NSCursor.current, .arrow)
        handle.axis = .horizontal
        handle.mouseDown(with: try event(.leftMouseDown, x: 200, y: 150))
        XCTAssertEqual(NSCursor.current, .resizeLeftRight)
        handle.setFrameOrigin(NSPoint(x: 130, y: 180))
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 260, y: 150))
        XCTAssertEqual(changes.last, 60)
        handle.mouseUp(with: try event(.leftMouseUp, x: 260, y: 150))
        XCTAssertEqual(ended, 2)
    }

    func testSplitSizingClampsPanelsToAvailableSpace() {
        XCTAssertEqual(SplitSizing.sidebarWidth(260, available: 1280), 260)
        XCTAssertEqual(SplitSizing.sidebarWidth(900, available: 1280), 520)
        XCTAssertEqual(SplitSizing.sidebarWidth(520, available: 640), 266)
        XCTAssertEqual(SplitSizing.terminalHeight(1, available: 700), 160)
        XCTAssertEqual(SplitSizing.terminalHeight(1000, available: 700), 574)
        XCTAssertEqual(SplitSizing.terminalHeight(160, available: 200), 74)
        XCTAssertEqual(SplitSizing.terminalHeight(160, available: 100), 0)
    }

    @MainActor func testPanelDragPreservesTerminalAndCommitsOnlyOnRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-resize-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let hosting = NSHostingView(rootView: CrowRootView().environment(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting; window.orderFront(nil)
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(250))
        func handles(_ view: NSView) -> [ResizeHandleView] {
            (view as? ResizeHandleView).map { [$0] } ?? view.subviews.flatMap { handles($0) }
        }
        let handle = try XCTUnwrap(handles(hosting).first { $0.axis == .vertical })
        // Terminal, explorer, and the default-visible inspector each own a handle.
        XCTAssertEqual(handles(hosting).count, 3)
        let id = try XCTUnwrap(model.current.snapshot.selectedTerminalID)
        let session = model.terminal(id, in: model.current)
        let startingHeight = session.view.bounds.height
        let originalLayout = model.current.snapshot.layout
        let origin = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, offset: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: origin.x, y: origin.y + offset),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        handle.mouseDown(with: try event(.leftMouseDown, offset: 0))
        handle.mouseDragged(with: try event(.leftMouseDragged, offset: 50))
        try await Task.sleep(for: .milliseconds(80))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(session.view.bounds.height, startingHeight + 50, accuracy: 2)
        handle.mouseDragged(with: try event(.leftMouseDragged, offset: 100))
        try await Task.sleep(for: .milliseconds(80))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(session.view.bounds.height, startingHeight + 100, accuracy: 2)
        XCTAssertEqual(model.current.snapshot.layout, originalLayout)
        handle.mouseUp(with: try event(.leftMouseUp, offset: 100))
        XCTAssertNotEqual(model.current.snapshot.layout, originalLayout)
        XCTAssertTrue(model.terminal(id, in: model.current) === session)
        for width in [900, 640, 1100] {
            window.setContentSize(NSSize(width: width, height: 500))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(session.view.bounds.width, 0)
        }
        XCTAssertTrue(model.removeWorkspace(model.selectedWorkspaceID))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(handles(hosting).allSatisfy { $0.axis != .vertical })
        XCTAssertFalse(session.running)
    }

    @MainActor func testFolderImporterPresentsFolderPickerAndCancelsSafely() throws {
        func pump(for seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.02))) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-folder-panel-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let originalWorkspace = model.selectedWorkspaceID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CrowRootView().environment(model))
        window.makeKeyAndOrderFront(nil)
        defer {
            (window.attachedSheet as? NSOpenPanel)?.cancel(nil)
            window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root)
        }
        pump(for: 0.3)
        model.folderImporterVisible = true
        for _ in 0..<60 {
            if window.attachedSheet is NSOpenPanel { break }
            pump(for: 0.05)
        }
        let panel = try XCTUnwrap(window.attachedSheet as? NSOpenPanel)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        // Confirmation in macOS service-backed panels requires real UI events;
        // URL handling and restoration are covered separately in CrowAppTests.
        panel.cancel(nil)
        for _ in 0..<60 {
            if !model.folderImporterVisible && window.attachedSheet == nil { break }
            pump(for: 0.05)
        }
        XCTAssertFalse(model.folderImporterVisible)
        XCTAssertEqual(model.selectedWorkspaceID, originalWorkspace)
        XCTAssertNil(model.errorMessage)
    }

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
        let nested = model.vaultURL.appendingPathComponent("Sources/Views", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("// Tree preview\n".utf8).write(to: nested.appendingPathComponent("ContentView.swift"))
        await model.current.explorer.refresh()
        await model.current.explorer.reveal(.init(name: "ContentView.swift",
            path: nested.appendingPathComponent("ContentView.swift").path, isDirectory: false))
        XCTAssertTrue(model.current.explorer.rows.contains { $0.entry.name == "ContentView.swift" && $0.depth == 2 })
        let hosting = NSHostingView(rootView: CrowRootView().environment(model).preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(500))
        // No manual refresh: changes made outside Crow appear through the sidebar's task.
        try Data("external change\n".utf8).write(to: model.vaultURL.appendingPathComponent("external.txt"))
        for _ in 0..<60 where !model.current.explorer.rows.contains(where: { $0.entry.name == "external.txt" }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(model.current.explorer.rows.contains { $0.entry.name == "external.txt" })
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

@MainActor private final class TestDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingSourceOperationMask: NSDragOperation = .move
    let draggedImageLocation = NSPoint.zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none
    init(pasteboard: NSPasteboard, window: NSWindow, point: NSPoint) {
        draggingPasteboard = pasteboard; draggingDestinationWindow = window; draggingLocation = point
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
#endif
