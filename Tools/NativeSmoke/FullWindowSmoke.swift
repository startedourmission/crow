import AppKit
import SwiftUI
import CrowCore
import WebKit
@testable import Crow

@MainActor final class FixtureWindow: NSWindow {
    var nativeDragRequests = 0
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func performDrag(with event: NSEvent) { nativeDragRequests += 1 }
}

@MainActor func views<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, type) }
}

@main struct FullWindowSmoke {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await test(); print("PASS full production window, no desktop input"); exit(0) }
            catch { print("FAIL", error.localizedDescription); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { print("FAIL timeout"); exit(1) }
        app.run()
    }

    @MainActor static func test() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-window-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        model.inspectorVisible = false
        model.settings.sidebarVisible = true
        model.current.snapshot.terminalIDs = []
        model.current.snapshot.selectedTerminalID = nil
        model.current.snapshot.layout = WorkspaceLayout(files: model.current.snapshot.buffers.map(\.id),
            selectedFile: model.current.snapshot.selectedBufferID, terminals: [], selectedTerminal: nil, terminalFraction: 0.3)
        let hosting = NSHostingView(rootView: CrowRootView().environment(model).background(WindowCloseGuard(model: model)))
        let window = FixtureWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        let anchors = views(hosting, WindowMoveAnchorView.self)
        try require(!anchors.isEmpty, "No native drag anchors")
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func verifyControlHover(_ rect: NSRect, _ label: String) async throws {
            let localRect = hosting.convert(rect, from: nil)
            func pixels() -> Data {
                hosting.layoutSubtreeIfNeeded()
                let rep = hosting.bitmapImageRepForCachingDisplay(in: localRect)!
                hosting.cacheDisplay(in: localRect, to: rep)
                return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
            }
            NSApp.sendEvent(event(.mouseMoved, NSPoint(x: -10, y: -10)))
            try await Task.sleep(for: .milliseconds(60))
            let before = pixels()
            NSApp.sendEvent(event(.mouseMoved, NSPoint(x: rect.midX, y: rect.midY)))
            try await Task.sleep(for: .milliseconds(60))
            let after = pixels()
            try require(before.count == after.count && zip(before, after).contains { abs(Int($0) - Int($1)) > 35 },
                "No clearly visible hover from window mouse events: \(label)")
            NSApp.sendEvent(event(.mouseMoved, NSPoint(x: -10, y: -10)))
            try await Task.sleep(for: .milliseconds(60))
            try require(pixels() == before, "Hover did not reset: \(label)")
        }
        func clickTopButton(search: Bool) async throws {
            let buttons = views(hosting, WindowMoveAnchorView.self).filter { anchor in
                let rect = anchor.convert(anchor.activeRect, to: nil)
                return anchor.excludesMovement && rect.width == 28 && rect.height == 28 &&
                    abs(rect.midY - (hosting.bounds.height - (search ? 61 : 20))) < 1
            }.sorted { $0.convert($0.activeRect, to: nil).midX < $1.convert($1.activeRect, to: nil).midX }
            try require(buttons.count == (search ? 3 : 1), "Search must be right-aligned beside New Folder; only the sidebar toggle belongs in the top row")
            for button in buttons {
                try await verifyControlHover(button.convert(button.activeRect, to: nil), search ? "explorer toolbar" : "sidebar toggle")
            }
            let button = buttons.last!
            let rect = button.convert(button.activeRect, to: nil)
            if !model.sidebarVisible && !search {
                try require(rect.maxX < 150, "Collapsed sidebar reopen button is not on the left")
            }
            let point = NSPoint(x: rect.midX, y: rect.midY)
            let requests = window.nativeDragRequests
            NSApp.sendEvent(event(.leftMouseDown, point)); NSApp.sendEvent(event(.leftMouseUp, point))
            try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
            try require(window.nativeDragRequests == requests && window.isMovable,
                        "Sidebar top button moved or locked the window")
        }
        func verify(_ label: String) throws {
            try require(window.isMovable, "OS window movement was disabled (\(label))")
            guard let surface = hosting.superview?.subviews.compactMap({ $0 as? WindowMoveSurface }).first else {
                try require(false, "Missing movement surface after \(label)"); return
            }
            let gap = NSPoint(x: hosting.bounds.width - 100, y: hosting.bounds.height - (model.sidebarVisible ? 18 : 58))
            try require(surface.containsRegion(surface.convert(gap, from: nil)), "The empty top tab bar cannot move the window (\(label))")
            try require(WorkspaceDragRouter.shared.source(at: gap, in: window) == nil, "Tab router intercepted blank header")
            let requests = window.nativeDragRequests
            NSApp.sendEvent(event(.leftMouseDown, gap))
            NSApp.sendEvent(event(.leftMouseDragged, NSPoint(x: gap.x + 60, y: gap.y + 30)))
            NSApp.sendEvent(event(.leftMouseUp, gap))
            try require(window.nativeDragRequests == requests + 1 && window.isMovable,
                        "Production window did not request native window dragging (\(label))")
            for source in views(hosting, WorkspaceTabDragView.self) {
                let point = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
                try require(!surface.containsRegion(surface.convert(point, from: nil)), "Tab or file intercepted by window drag")
                try require(!source.mouseDownCanMoveWindow, "Native tab/file control allows title-bar dragging")
                let hover = views(hosting, CrowHoverTrackingView.self).filter {
                    $0.activeRect.contains($0.convert(point, from: nil))
                }
                try require(!hover.isEmpty, "Tab/file drag source has no label hover tracking")
                try require(hover.allSatisfy { $0.hitTest($0.convert(point, from: nil)) == nil }, "Hover tracking intercepted native dragging")
                if source.payload != nil {
                    let requests = window.nativeDragRequests
                    NSApp.sendEvent(event(.leftMouseDown, point))
                    try require(window.isMovable, "Tab press disabled OS movement")
                    NSApp.sendEvent(event(.leftMouseUp, point))
                    try require(window.isMovable && window.nativeDragRequests == requests, "Tab click requested window dragging")
                }
            }
            for anchor in views(hosting, WindowMoveAnchorView.self) where anchor.excludesMovement {
                // Test both tab label and close-button end of the entire tab rectangle.
                for x in [anchor.bounds.midX, anchor.bounds.maxX - 12] {
                    let point = anchor.convert(NSPoint(x: x, y: anchor.bounds.midY), to: surface)
                    try require(!surface.containsRegion(point), "Tab/close button moves the window")
                }
            }
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let view = window.standardWindowButton(button) {
                    let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: surface)
                    try require(!surface.containsRegion(point), "Traffic-light button moves the window")
                }
            }
            let editorPoint = NSPoint(x: hosting.bounds.width - 100, y: 300)
            try require(surface.containsRegion(surface.convert(editorPoint, from: nil)) == model.buffers.isEmpty,
                        "Editor/empty workspace drag boundary is incorrect")
            if model.sidebarVisible {
                let vaultMenu = NSPoint(x: 150, y: 44)
                try require(!surface.containsRegion(surface.convert(vaultMenu, from: nil)), "Bottom vault selector intercepted by window drag")
                let footerExclusions = views(hosting, WindowMoveAnchorView.self).filter { anchor in
                    anchor.excludesMovement && anchor.activeRect.width > 50 &&
                        anchor.convert(anchor.activeRect, to: nil).contains(vaultMenu)
                }
                try require(footerExclusions.count == 1, "Vault selector is missing from the sidebar footer")
                let blankSidebar = NSPoint(x: 150, y: 90)
                try require(surface.containsRegion(surface.convert(blankSidebar, from: nil)), "Blank sidebar cannot move window")
                let requests = window.nativeDragRequests
                NSApp.sendEvent(event(.leftMouseDown, blankSidebar))
                NSApp.sendEvent(event(.leftMouseUp, blankSidebar))
                try require(window.nativeDragRequests == requests + 1, "Blank sidebar did not hand dragging to AppKit")
            }
            let statusGap = NSPoint(x: hosting.bounds.midX, y: 12)
            try require(surface.containsRegion(surface.convert(statusGap, from: nil)), "Status-bar blank space cannot move window")
            print("PASS production window: \(label), native drag handoff + OS movement enabled + input exclusions")
        }
        try verify("initial")
        try await clickTopButton(search: true)
        try require(model.current.explorer.searchVisible, "Top search button did not open file search")
        model.current.explorer.query = "test"
        try await clickTopButton(search: true)
        try require(!model.current.explorer.searchVisible && model.current.explorer.query.isEmpty,
                    "Top search button did not close and clear search")
        window.setContentSize(NSSize(width: 1280, height: 800))
        try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
        try verify("resize")
        try await clickTopButton(search: false)
        try require(!model.sidebarVisible, "Sidebar toggle did not collapse the panel")
        try verify("sidebar hidden")
        try await clickTopButton(search: false)
        try require(model.sidebarVisible, "Sidebar toggle did not restore the panel")
        try verify("sidebar restored")
        if let source = views(hosting, WorkspaceTabDragView.self).first(where: { $0.payload != nil }),
           let tab = views(hosting, WindowMoveAnchorView.self).first(where: { anchor in
               anchor.excludesMovement && anchor.activeRect.height == 36 &&
                   anchor.convert(anchor.activeRect, to: nil).contains(source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil))
           }) {
            let point = tab.convert(NSPoint(x: tab.bounds.maxX - 19, y: tab.bounds.midY), to: nil)
            let origin = window.frame.origin
            let count = model.buffers.count
            NSApp.sendEvent(event(.leftMouseDown, point)); NSApp.sendEvent(event(.leftMouseUp, point))
            try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
            try require(model.buffers.count == count - 1, "Native click on tab close button did not close the file")
            try require(window.frame.origin == origin, "Tab close click moved the window")
            try verify("last tab closed")
        }
        let noteURL = root.appendingPathComponent("outline.md")
        let note = "# First\n\n" + String(repeating: "paragraph\n\n", count: 70) + "## 두번째\n\nend\n"
        try Data(note.utf8).write(to: noteURL)
        model.openFile(FileEntry(name: "outline.md", path: noteURL.path, isDirectory: false))
        model.inspectorVisible = true
        try await Task.sleep(for: .milliseconds(500)); hosting.layoutSubtreeIfNeeded()
        let items = DocumentOutline.items(note, language: .markdown)
        func clickLastOutline() async throws {
            let rows = views(hosting, WindowMoveAnchorView.self).filter { anchor in
                let rect = anchor.convert(anchor.activeRect, to: nil)
                return anchor.excludesMovement && rect.width > 150 && rect.height < 35 &&
                    rect.minX > hosting.bounds.width - 400 && rect.maxY < hosting.bounds.height - 65
            }.sorted { $0.convert($0.activeRect, to: nil).midY > $1.convert($1.activeRect, to: nil).midY }
            try require(rows.count == 2, "Summary did not show both heading buttons")
            for row in rows {
                let frame = row.convert(row.activeRect, to: nil)
                try await verifyControlHover(frame, "summary heading")
                let point = NSPoint(x: frame.midX, y: frame.midY)
                try require(views(hosting, CrowHoverTrackingView.self).contains {
                    $0.activeRect.contains($0.convert(point, from: nil))
                }, "Summary row has no hover tracking")
            }
            let rect = rows[1].convert(rows[1].activeRect, to: nil)
            let point = NSPoint(x: rect.midX, y: rect.midY)
            NSApp.sendEvent(event(.leftMouseDown, point)); NSApp.sendEvent(event(.leftMouseUp, point))
            try await Task.sleep(for: .milliseconds(200)); hosting.layoutSubtreeIfNeeded()
        }
        try await clickLastOutline()
        guard let editor = views(hosting, CodeTextView.self).first else { throw NSError(domain: "Missing editor", code: 1) }
        try require(editor.selectedRange().location == items[1].offset && editor.selectedRange().length == 0,
                    "Summary click did not move the native insertion caret to the heading")
        try require(editor.enclosingScrollView!.contentView.bounds.minY > 0, "Summary jump did not scroll the editor")
        // Click the production Markdown preview button without desktop input.
        let previewPoint = NSPoint(x: hosting.bounds.width - 260 - 6 - 49, y: hosting.bounds.height - 51)
        NSApp.sendEvent(event(.leftMouseDown, previewPoint)); NSApp.sendEvent(event(.leftMouseUp, previewPoint))
        try await Task.sleep(for: .milliseconds(600)); hosting.layoutSubtreeIfNeeded()
        guard let web = views(hosting, WKWebView.self).first else { throw NSError(domain: "Missing rich editor after preview click", code: 1) }
        try await clickLastOutline()
        let heading = try await web.callAsyncJavaScript("return window.getSelection()?.anchorNode?.parentElement?.closest('h2')?.textContent", arguments: [:], in: nil, contentWorld: .defaultClient) as? String
        try require(heading == "두번째", "Summary click did not place the caret inside the rendered heading")
        try require(model.inspectedBuffer?.text == note, "Outline navigation edited the document")
        print("PASS inspector: visible heading hover via window events, native/rich caret navigation, source unchanged")
        let codeURL = root.appendingPathComponent("outline.swift")
        let code = "// 👋 한글\nfunc first() {}\n\nfunc second(\n value: Int\n) {}\n"
        try Data(code.utf8).write(to: codeURL)
        model.openFile(FileEntry(name: "outline.swift", path: codeURL.path, isDirectory: false))
        try await Task.sleep(for: .milliseconds(500)); hosting.layoutSubtreeIfNeeded()
        try await clickLastOutline()
        let functionEditor = views(hosting, CodeTextView.self).first!
        try require(functionEditor.selectedRange().location == (code as NSString).range(of: "second").location,
                    "Function summary did not navigate in the newly selected code file")
        print("PASS inspector: code declarations, Unicode offset, and active-file switching")
        for visible in [false, true] {
            let actions = views(hosting, WindowMoveAnchorView.self).filter { anchor in
                let rect = anchor.convert(anchor.activeRect, to: nil)
                return anchor.excludesMovement && rect.width == 28 && rect.height == 28 &&
                    abs(rect.midY - (hosting.bounds.height - 18)) < 1
            }.sorted { $0.convert($0.activeRect, to: nil).midX < $1.convert($1.activeRect, to: nil).midX }
            try require(actions.count == 2, "Expected equally sized More + one sidebar action, without a duplicate open button")
            let action = actions.last!
            let rect = action.convert(action.activeRect, to: nil)
            let point = NSPoint(x: rect.midX, y: rect.midY)
            NSApp.sendEvent(event(.leftMouseDown, point)); NSApp.sendEvent(event(.leftMouseUp, point))
            try await Task.sleep(for: .milliseconds(250)); hosting.layoutSubtreeIfNeeded()
            try require(model.inspectorVisible == visible && window.isMovable, "Pane header did not hide/reopen the inspector")
        }
        print("PASS pane headers: matching More/close/open geometry, no duplicate open action, sidebar hide/reopen")
        model.sidebarVisible = false
        model.focusFileSearch()
        try await Task.sleep(for: .milliseconds(250)); hosting.layoutSubtreeIfNeeded()
        try require(model.sidebarVisible && model.current.explorer.searchVisible, "Search shortcut did not reveal the explorer")
        try require((window.firstResponder as? NSTextView)?.isFieldEditor == true, "Search shortcut did not focus the file search field")
        model.current.explorer.query = "con"
        try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
        let tabKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        window.sendEvent(tabKey)
        try await Task.sleep(for: .milliseconds(150))
        try require(model.current.explorer.query == "contents: ", "Tab did not complete the contents: prefix")
        let searchQuery = "contents: second"
        model.current.explorer.query = searchQuery
        for _ in 0..<100 where model.current.explorer.isSearching { try await Task.sleep(for: .milliseconds(20)) }
        try require(model.current.explorer.results.map(\.path) == [codeURL.path], "Content search did not find code by its body")
        try require(model.current.explorer.contentMatches[codeURL.path]?.line == 4, "Content search omitted the matching line")
        model.findInCurrentDocument()
        try await Task.sleep(for: .milliseconds(250)); hosting.layoutSubtreeIfNeeded()
        try require(functionEditor.enclosingScrollView?.isFindBarVisible == true, "Document search was routed to the explorer instead of the active editor")
        let caseFixture = "Foo foo FOO\n한글 Foo"
        let codeBufferID = model.buffers.first { $0.path == codeURL.path }!.id
        model.updateBufferText(codeBufferID, caseFixture)
        try await Task.sleep(for: .milliseconds(150))
        let findBar = functionEditor.documentFindBar
        try require(!views(findBar, NSButton.self).contains { $0.toolTip == "Close Find" }, "Redundant close-find button remains")
        try require((findBar.searchField.cell as? NSSearchFieldCell)?.cancelButtonCell == nil, "Search field still has a redundant X")
        try require(findBar.countLabel.superview === findBar.searchField.superview, "Match position is not beside the search field")
        findBar.searchField.stringValue = "Foo"; findBar.replacementField.stringValue = "Bar"
        functionEditor.setSelectedRange(NSRange(location: 0, length: 0))
        findBar.matchCase.performClick(nil)
        try require(findBar.matchCase.state == .on, "Match Case checkbox did not turn on")
        try require(findBar.countLabel.stringValue == "1/2", "Find did not display first match / total")
        findBar.nextMatch()
        try require(findBar.countLabel.stringValue == "2/2", "Next match did not update position")
        findBar.nextMatch()
        try require(findBar.countLabel.stringValue == "1/2", "Match position did not wrap")
        findBar.previousMatch()
        try require(findBar.countLabel.stringValue == "2/2", "Previous match did not wrap")
        functionEditor.setSelectedRange(NSRange(location: 0, length: 0))
        try require(findBar.countLabel.stringValue == "0/2", "Manual selection left a stale match position")
        for button in views(findBar, CrowFindButton.self) {
            if button !== findBar.matchCase { try require(!button.isBordered, "Find action still has a button background") }
            let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
            button.mouseEntered(with: enter)
            try require(button.isHovered && button.contentTintColor == NSColor(CrowTheme.accent), "Find action did not adopt accent on hover")
            let leave = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
            button.mouseExited(with: leave)
            try require(!button.isHovered && button.contentTintColor == NSColor(CrowTheme.textDim), "Find action did not reset hover")
        }
        findBar.replaceAll()
        try await Task.sleep(for: .milliseconds(100))
        try require(model.buffers.first { $0.id == codeBufferID }?.text == "Bar foo FOO\n한글 Bar", "Case-sensitive replacement changed nonmatching case")
        try require(findBar.countLabel.stringValue == "0/0", "Replacement left a stale match total")
        functionEditor.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(100))
        try require(functionEditor.string == caseFixture, "Replace All was not one undoable edit")
        findBar.matchCase.performClick(nil); findBar.replaceAll()
        try await Task.sleep(for: .milliseconds(100))
        try require(functionEditor.string == "Bar Bar Bar\n한글 Bar", "Case-insensitive replacement missed variants")
        functionEditor.undoManager?.undo()
        for visible in [false, true] {
            let point = NSPoint(x: hosting.bounds.width - 260 - 6 - 20, y: hosting.bounds.height - 51)
            NSApp.sendEvent(event(.leftMouseDown, point)); NSApp.sendEvent(event(.leftMouseUp, point))
            try await Task.sleep(for: .milliseconds(150))
            try require(functionEditor.enclosingScrollView?.isFindBarVisible == visible, "Document search button did not toggle the find bar")
        }
        print("PASS search UI: prefix completion, toggle, no X, current/total navigation, borderless hover, Match Case replacement and undo")
        model.focusFileSearch()
        try await Task.sleep(for: .milliseconds(200)); hosting.layoutSubtreeIfNeeded()
        try require(model.current.explorer.query == searchQuery && (window.firstResponder as? NSTextView)?.isFieldEditor == true,
                    "Repeated file-search shortcut changed the query or failed to restore focus")
        let oldSize = model.settings.fontSize
        model.adjustFontSize(by: 1)
        try await Task.sleep(for: .milliseconds(100))
        try require(functionEditor.font?.pointSize == oldSize + 1, "Font shortcut did not resize the active editor")
        model.adjustFontSize(by: -1)
        let leftPane = model.current.snapshot.layout!.activePane!
        let noteID = model.buffers.first { $0.path == noteURL.path }!.id
        model.splitTab(.file(noteID), in: leftPane.id, placement: .right)
        model.newUntitledBuffer()
        for _ in 0..<100 where (model.current.snapshot.layout?.activePane?.tabs.count ?? 0) < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let rightPane = model.current.snapshot.layout!.activePane!
        try require(rightPane.tabs.count == 2, "New tab fixture did not finish creating its file")
        model.selectNumberedTab(1)
        try require(model.current.snapshot.layout!.activePane?.id == rightPane.id &&
                    model.current.snapshot.layout!.activePane?.selected == rightPane.tabs[0], "Numbered tab shortcut used the wrong pane")
        try require(model.current.snapshot.layout!.panes.first { $0.id == leftPane.id }?.selected == leftPane.selected,
                    "Numbered tab shortcut changed an unfocused pane")
        model.selectNumberedTab(2)
        try require(model.current.snapshot.layout!.activePane?.selected == rightPane.tabs[1], "Numbered tab shortcut did not select the second tab")
        print("PASS shortcut actions: explorer focus/query preservation, current-document find, font size, pane-local numbered tabs, contents search")
        try await verifyHover()
        try require(!NSApp.isActive, "Fixture stole app focus")
    }
    @MainActor static func verifyHover() async throws {
        let view = NSHostingView(rootView: HStack(spacing: 20) {
            Button {} label: { Text("Plain").crowForeground(CrowTheme.textDim).frame(width: 100, height: 40) }
                .buttonStyle(CrowButtonStyle())
            Button {} label: { Text("Filled").frame(width: 80, height: 30) }
                .buttonStyle(CrowButtonStyle(kind: .filled))
            Button {} label: { Text("Disabled").frame(width: 100, height: 40) }
                .buttonStyle(CrowButtonStyle()).disabled(true)
        }.padding(20).background(CrowTheme.bg0))
        let window = FixtureWindow(contentRect: NSRect(x: -22000, y: -22000, width: 380, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.acceptsMouseMovedEvents = true; window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        func bitmap() throws -> Data {
            view.layoutSubtreeIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
        }
        func move(_ x: CGFloat) async {
            let point = view.convert(NSPoint(x: x, y: 40), to: nil)
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
            NSApp.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(80))
        }
        await move(5)
        let baseline = try bitmap()
        try require(views(view, CrowHoverTrackingView.self).count == 3, "Not every button registered hover tracking")
        for (x, label) in [(CGFloat(70), "plain foreground"), (190, "filled background")] {
            await move(x)
            let hovered = try bitmap()
            try require(hovered != baseline, "No rendered hover feedback for \(label)")
            await move(5)
            try require(try bitmap() == baseline, "Hover did not reset for \(label)")
        }
        await move(310)
        try require(try bitmap() == baseline, "Disabled button reacted to hover")
        print("PASS hover rendering via window mouse events: plain label, filled background, exit, disabled; no pointer movement")
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "CrowWindowSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
