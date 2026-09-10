import AppKit
import SwiftUI
import CrowCore
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
        window.setContentSize(NSSize(width: 1280, height: 800))
        try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
        try verify("resize")
        model.sidebarVisible = false
        try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
        try verify("sidebar hidden")
        model.sidebarVisible = true
        try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
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
        try require(!NSApp.isActive, "Fixture stole app focus")
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "CrowWindowSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
