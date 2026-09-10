import AppKit
import SwiftUI
import WebKit
import CrowCore

@MainActor final class OffscreenWindow: NSWindow {
    var nativeDragRequests = 0
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    // Do not enter Window Server's mouse-tracking loop on the user's desktop.
    override func performDrag(with event: NSEvent) { nativeDragRequests += 1 }
}

@MainActor final class Document {
    var text: String
    var saves = 0
    init(_ text: String) { self.text = text }
}

@MainActor func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
    if let found = view as? T { return [found] }
    return view.subviews.flatMap { descendants($0, type) }
}

@MainActor func check(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "CrowNativeSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@MainActor func windowMovement() async throws {
    let content = NSHostingView(rootView: HStack(spacing: 0) {
        VStack(spacing: 0) {
            Button("Vault") {}.frame(height: 40)
            HStack {
                Button("New") {}.frame(width: 40)
                Spacer().frame(maxHeight: .infinity).overlay { WindowDragRegion() }
                Button("Find") {}.frame(width: 40)
            }.frame(height: 40)
            Text("File list").frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(width: 250)
        Text("Editor and terminal").frame(maxWidth: .infinity, maxHeight: .infinity)
    }.frame(width: 1000, height: 700))
    let window = OffscreenWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 700),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.isMovable = true; window.contentView = content
    defer { window.close() }
    content.layoutSubtreeIfNeeded(); window.setFrameOrigin(NSPoint(x: -20000, y: -20000)); window.orderBack(nil)
    try await Task.sleep(for: .milliseconds(250))
    content.layoutSubtreeIfNeeded(); window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    guard let anchor = descendants(content, WindowMoveAnchorView.self).first,
          let surface = content.superview?.subviews.compactMap({ $0 as? WindowMoveSurface }).first else {
        try check(false, "Missing native window movement surface"); return
    }
    let rect = anchor.convert(anchor.activeRect, to: surface)
    try check(rect.width < 250 && rect.height <= 40 && !rect.isEmpty, "Drag geometry escaped its spacer")
    let point = NSPoint(x: rect.midX, y: rect.midY)
    try check(surface.containsRegion(point), "Blank space cannot move window")
    for excluded in [NSPoint(x: 500, y: 300), NSPoint(x: 20, y: point.y), NSPoint(x: 120, y: 300)] {
        try check(!surface.containsRegion(excluded), "Editor, button or file row was intercepted")
        try check(surface.hitTest(surface.convert(excluded, to: surface.superview)) == nil, "Non-drag input was swallowed")
    }
    let hit = content.superview!.hitTest(surface.convert(point, to: content.superview!.superview))
    try check(hit === surface, "Window hit testing did not reach the native drag view")
    let press = surface.convert(point, to: nil)
    func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    window.sendEvent(event(.leftMouseDown, press))
    window.sendEvent(event(.leftMouseDragged, NSPoint(x: press.x + 60, y: press.y + 30)))
    window.sendEvent(event(.leftMouseUp, press))
    try check(window.nativeDragRequests == 1 && window.isMovable,
              "Blank-area drag was not handed to AppKit with OS movement enabled")
    print("PASS window drag handoff: AppKit requested; OS movement enabled; controls excluded")
}

@MainActor func markdown(_ root: URL) async throws {
    let original = "# 제목\n\nA **bold** paragraph\n\n```swift\nlet x = 1\n```\n\n| A | B |\n|---|---|\n| x | y |\n"
    let fixtures = [original, try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8),
        "", "```\n```\n", "# 👨‍👩‍👧‍👦 한글\r\n\r\n**강조**와 `코드`\r\n",
        "---\ntitle: Test\n---\n\n# Title\n\n[link][ref]\n\n[ref]: https://example.com\n",
        "# Inline\n\nA \\*literal\\* &amp; **bold** 🙂\n\n<!-- comment -->\n\n- one\n  - two\n\n> quote\n",
        "~~~~swift\nswift\n\n~~~~\n"]
    let window = OffscreenWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 650),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    for (index, source) in fixtures.enumerated() {
        let document = Document(source)
        let host = NSHostingView(rootView: MarkdownPreviewView(
            text: Binding(get: { document.text }, set: { document.text = $0 }),
            fontSize: 15, onSave: { document.saves += 1 }))
        window.contentView = host; host.layoutSubtreeIfNeeded()
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000)); window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(300))
        guard let web = descendants(host, WKWebView.self).first else {
            try check(false, "Preview did not initialize for fixture \(index)"); return
        }
        func js(_ script: String) async throws -> Any? {
            try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
        }
        var ready = false
        for _ in 0..<100 {
            ready = (try? await js("return !!document.querySelector('.tiptap')")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try check(ready, "Rich editor did not load for fixture \(index)")
        try check(document.text == source, "Opening preview mutated fixture \(index)")
        try check((try await js("return document.querySelector('textarea') === null")) as? Bool == true, "Preview introduced a source textarea")
        if index == 0 {
            _ = try await js("""
                window.beforeBody = document.body; window.beforeEditor = document.querySelector('.tiptap');
                window.beforeEditor.focus();
                const range = document.createRange(); range.selectNodeContents(document.querySelector('strong'));
                const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                document.execCommand('insertText', false, '한글'); return true;
                """)
            try await Task.sleep(for: .milliseconds(150))
            try check(document.text == original.replacingOccurrences(of: "bold", with: "한글"), "Direct rich edit corrupted Markdown: \(document.text)")
            try check((try await js("return document.body === window.beforeBody && document.querySelector('.tiptap') === window.beforeEditor")) as? Bool == true, "Editing reloaded the document")
            _ = try await js("document.querySelector('.tiptap').dispatchEvent(new KeyboardEvent('keydown',{key:'z',code:'KeyZ',keyCode:90,metaKey:true,bubbles:true})); return true")
            try await Task.sleep(for: .milliseconds(100))
            try check(document.text == original, "Rich-text undo failed: \(document.text.debugDescription); DOM: \(String(describing: try await js("return document.querySelector('.tiptap').innerHTML")))")
            _ = try await js("document.querySelector('.tiptap').dispatchEvent(new KeyboardEvent('keydown',{key:'z',code:'KeyZ',keyCode:90,metaKey:true,shiftKey:true,bubbles:true})); return true")
            try await Task.sleep(for: .milliseconds(100))
            try check(document.text == original.replacingOccurrences(of: "bold", with: "한글"), "Rich-text redo failed")
            _ = try await js("document.querySelector('.tiptap').dispatchEvent(new KeyboardEvent('keydown',{key:'s',code:'KeyS',keyCode:83,metaKey:true,bubbles:true})); return true")
            try await Task.sleep(for: .milliseconds(100))
            try check(document.saves == 1, "Save shortcut did not reach the document")
            print("PASS rich edit, Markdown preservation, undo/redo, save, no reload")
            // Exercise the same NSTextInputClient methods used by macOS IMEs, without
            // changing the user's input source, sending keystrokes or activating a window.
            func inputClients(_ view: NSView) -> [any NSTextInputClient] {
                let found = (view as? any NSTextInputClient).map { [$0] } ?? []
                return found + view.subviews.flatMap(inputClients)
            }
            guard let client = inputClients(web).first else { try check(false, "WebKit has no native text input client"); return }
            _ = try await js("""
                const range = document.createRange(); range.selectNodeContents(document.querySelector('strong'));
                const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                document.querySelector('.tiptap').focus(); return true;
                """)
            client.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(80))
            client.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(80))
            client.setMarkedText("한글입력", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(80))
            client.insertText("한글입력", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(150))
            try check(document.text == original.replacingOccurrences(of: "bold", with: "한글입력"), "Native IME composition corrupted Markdown: \(document.text)")
            print("PASS native Korean IME composition and commit")
            try check((try await js("return document.querySelector('pre code').textContent")) as? String == "let x = 1", "Code block gained a trailing editable line")
            _ = try await js("""
                const range = document.createRange(); range.selectNodeContents(document.querySelector('pre code')); range.collapse(false);
                const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                document.querySelector('.tiptap').focus(); document.execCommand('insertText', false, '!'); return true;
                """)
            try await Task.sleep(for: .milliseconds(100))
            try check(document.text == original.replacingOccurrences(of: "bold", with: "한글입력").replacingOccurrences(of: "let x = 1", with: "let x = 1!"),
                      "Editing the last code line changed its fence separator: \(document.text.debugDescription)")
            print("PASS code block has no synthetic trailing line; last-line edits preserve fences")
        }
        if source.hasPrefix("~~~~swift") {
            try check((try await js("return document.querySelector('pre code').textContent")) as? String == "swift\n",
                      "Code block lost an intentional blank line")
            _ = try await js("""
                document.querySelector('.tiptap').focus();
                const code = document.querySelector('pre code');
                const range = document.createRange(); range.setStart(code.firstChild, 5); range.collapse(true);
                const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                document.execCommand('insertText', false, '!'); return true;
                """)
            try await Task.sleep(for: .milliseconds(100))
            try check(document.text == "~~~~swift\nswift!\n\n~~~~\n", "Code edit changed the language, tilde fence or intentional blank line")
        }
        print("PASS markdown fixture \(index)")
    }
}

@main struct NativeSmoke {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var activated = false
        let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { notification in
            if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               application.processIdentifier == ProcessInfo.processInfo.processIdentifier { activated = true }
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        Task { @MainActor in
            do {
                try await windowMovement()
                try await sftpFallback()
                try await markdown(root)
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
                try check(!activated && NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                          "Smoke app took foreground focus")
                print("PASS all native checks; no cursor posting or activation")
                exit(0)
            } catch { print("FAIL", error.localizedDescription); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { print("FAIL native smoke timeout"); exit(1) }
        app.run()
    }
}
