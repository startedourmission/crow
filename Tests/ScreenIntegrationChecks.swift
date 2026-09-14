import XCTest
import CrowCore
import WebKit
@testable import Crow
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Used with real Citadel and OpenSSH connections, and the loopback RFB fixture.
@MainActor enum ScreenIntegrationChecks {
    static func verify(in state: WorkspaceState, port: Int, events: String) async throws {
        let previousEvents = try await XCTUnwrap(state.remote).read(events)
        let viewer = RemoteScreenSession()
        #if os(macOS)
        let pasteboard = NSPasteboard(name: .init("crow-screen-test-" + UUID().uuidString))
        viewer.pasteboard = pasteboard
        defer { pasteboard.releaseGlobally() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = viewer.webView; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        #else
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view = viewer.webView
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        #endif
        defer { viewer.stop() }
        func wait(_ label: String, _ condition: () async throws -> Bool) async throws {
            for _ in 0..<200 {
                if try await condition() { return }
                if let error = viewer.error { throw CommandError(label + ": " + error) }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw CommandError("Timed out: " + label)
        }
        func js(_ source: String) async throws -> String {
            try await withCheckedThrowingContinuation { result in
                viewer.webView.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { response in
                    switch response {
                    case .success(let value): result.resume(returning: value as? String ?? "")
                    case .failure(let error): result.resume(throwing: error)
                    }
                }
            }
        }
        func recorded() async throws -> String {
            String(try await XCTUnwrap(state.remote).read(events).dropFirst(previousEvents.count))
        }
        func closedCount() async throws -> Int { try await recorded().components(separatedBy: "\"type\": \"closed\"").count - 1 }
        try await wait("Load bundled screen client") { viewer.ready }
        #if os(macOS)
        try await wait("Hide mobile keyboard controls on Mac") {
            try await js("return getComputedStyle(document.getElementById('controls')).display;") == "none"
        }
        viewer.fitToWindow = false
        try await wait("Apply native Fit control") {
            try await js("return String(document.getElementById('fit').checked);") == "false"
        }
        viewer.fitToWindow = true
        #else
        let controlsDisplay = try await js("return getComputedStyle(document.getElementById('controls')).display;")
        XCTAssertEqual(controlsDisplay, "flex")
        #endif
        viewer.connect(in: state, port: port)
        try await wait("Request screen credentials") { !viewer.credentialTypes.isEmpty }
        XCTAssertFalse(viewer.connected)
        XCTAssertEqual(viewer.credentialTypes, ["password"])
        viewer.authenticate(username: "", password: "incorrect")
        for _ in 0..<200 where viewer.error == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(viewer.error, "Authentication or authorization failure")
        XCTAssertFalse(viewer.connected)
        viewer.connect(in: state, port: port)
        try await wait("Retry VNC password after rejected credentials") { !viewer.credentialTypes.isEmpty }
        XCTAssertEqual(viewer.credentialTypes, ["password"], "Prefer configured VNC password over Apple account authentication")
        viewer.authenticate(username: "", password: "fixture")
        try await wait("Complete RFB negotiation") { viewer.connected }
        XCTAssertEqual(viewer.name, "Crow Screen Fixture")
        try await wait("Render fragmented framebuffer") {
            try await js("const c = document.querySelector('canvas'); return c ? Array.from(c.getContext('2d').getImageData(0,0,1,1).data).join(',') : '';") == "255,0,0,255"
        }
        #if os(macOS)
        try await wait("Visible cursor after server sends an empty cursor") {
            try await js("return document.querySelector('#display canvas').style.cursor;").contains("data:image/png")
        }
        XCTAssertFalse(viewer.clipboardSync)
        pasteboard.clearContents(); pasteboard.setString("local clipboard", forType: .string)
        viewer.clipboardSync = true
        await viewer.syncClipboardIfNeeded()
        try await wait("Send native clipboard to server") {
            try await recorded().contains("\"type\": \"clipboard\", \"text\": \"local clipboard\"")
        }
        _ = try await js("document.getElementById('text').value = 'c'; document.getElementById('type').click();")
        try await wait("Receive server clipboard on Mac") { pasteboard.string(forType: .string) == "remote clipboard" }
        await viewer.syncClipboardIfNeeded()
        pasteboard.clearContents(); pasteboard.setString("shortcut clipboard", forType: .string)
        _ = try await js("""
            const target = document.querySelector('#display canvas');
            target.dispatchEvent(new KeyboardEvent('keydown', {code:'KeyV', key:'v', ctrlKey:true, bubbles:true, cancelable:true}));
            target.dispatchEvent(new KeyboardEvent('keyup', {code:'KeyV', key:'v', bubbles:true, cancelable:true}));
            """)
        try await wait("Paste shortcut sends client clipboard before remote paste") {
            let log = try await recorded()
            guard let clipboard = log.range(of: "\"text\": \"shortcut clipboard\""),
                  let paste = log.range(of: "\"down\": 1, \"key\": 118") else { return false }
            return clipboard.lowerBound < paste.lowerBound
        }
        let beforeNativePaste = try await recorded().count
        pasteboard.clearContents(); pasteboard.setString("native shortcut clipboard", forType: .string)
        window.makeFirstResponder(viewer.webView)
        let pasteEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "v",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        XCTAssertTrue(viewer.webView.performKeyEquivalent(with: pasteEvent))
        try await wait("Native Command-V uses the client clipboard") {
            let log = String(try await recorded().dropFirst(beforeNativePaste))
            guard let clipboard = log.range(of: "\"text\": \"native shortcut clipboard\""),
                  let paste = log.range(of: "\"down\": 1, \"key\": 118") else { return false }
            return clipboard.lowerBound < paste.lowerBound && log.contains("\"down\": 1, \"key\": 65515")
        }
        viewer.clipboardSync = false
        pasteboard.clearContents(); pasteboard.setString("sync disabled", forType: .string)
        await viewer.syncClipboardIfNeeded()
        _ = try await js("document.getElementById('text').value = 'c'; document.getElementById('type').click();")
        #endif
        _ = try await js("""
            document.querySelector('[data-key="65293"]').click();
            document.getElementById('text').value = '한'; document.getElementById('type').click();
            const canvas = document.querySelector('canvas'), rect = canvas.getBoundingClientRect();
            for (const type of ['mousedown', 'mouseup']) canvas.dispatchEvent(new MouseEvent(type,
                {bubbles:true, button:0, buttons:type === 'mousedown' ? 1 : 0, clientX:rect.x+10, clientY:rect.y+10}));
            """)
        try await wait("Forward keyboard, Unicode, and pointer input") {
            let log = try await recorded()
            return log.contains("\"key\": 65293") && log.contains("\"key\": 16831836") && log.contains("\"buttons\": 1") && log.contains("\"buttons\": 0")
        }
        #if os(macOS)
        viewer.viewOnly = true
        try await wait("Apply native View Only control") {
            try await js("return String(document.getElementById('view-only').checked);") == "true"
        }
        _ = try await js(#"document.querySelector('[data-key="65307"]').click();"#)
        #else
        _ = try await js(#"const box = document.getElementById('view-only'); box.checked = true; box.dispatchEvent(new Event('change')); document.querySelector('[data-key="65307"]').click();"#)
        #endif
        // An SSH/SFTP round trip gives pending input writes an opportunity to arrive.
        try await Task.sleep(for: .milliseconds(150))
        let log = try await recorded()
        XCTAssertFalse(log.contains("\"key\": 65307"), "View only must suppress remote input")
        XCTAssertFalse(log.contains("\"type\": \"error\""), log)
        XCTAssertTrue(log.contains("\"value\": 1"), "Allow concurrent VNC clients")
        #if os(macOS)
        XCTAssertFalse(log.contains("\"type\": \"clipboard\", \"text\": \"remote clipboard\""), "Do not echo remote clipboard updates")
        XCTAssertFalse(log.contains("\"type\": \"clipboard\", \"text\": \"sync disabled\""))
        XCTAssertEqual(pasteboard.string(forType: .string), "sync disabled", "Disabling sync must stop both directions")
        viewer.viewOnly = false
        let remoteBoard = NSPasteboard(name: .init("crow-remote-image-test-" + UUID().uuidString))
        defer { remoteBoard.releaseGlobally() }
        viewer.remotePasteboardName = remoteBoard.name.rawValue
        viewer.includeClipboardImages = true; viewer.clipboardSync = true
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=")!
        pasteboard.clearContents(); pasteboard.setData(png, forType: .png)
        try await wait("Upload image into remote Mac pasteboard over SSH") {
            await viewer.syncNativeClipboard()
            if let error = viewer.clipboardError { throw CommandError(error) }
            return remoteBoard.data(forType: .png) != nil && remoteBoard.data(forType: .tiff) != nil
        }
        remoteBoard.clearContents(); remoteBoard.setString("한글 클립보드", forType: .string)
        try await wait("Receive Unicode clipboard over Mac SSH helper") {
            await viewer.syncNativeClipboard(pullOnly: true)
            if let error = viewer.clipboardError { throw CommandError(error) }
            return pasteboard.string(forType: .string) == "한글 클립보드"
        }
        remoteBoard.clearContents(); remoteBoard.setData(png, forType: .png)
        try await wait("Download image from remote Mac pasteboard over SSH") {
            await viewer.syncNativeClipboard(pullOnly: true)
            if let error = viewer.clipboardError { throw CommandError(error) }
            guard let data = pasteboard.data(forType: .png), let image = NSBitmapImageRep(data: data) else { return false }
            return image.pixelsWide == 2 && image.pixelsHigh == 2 && pasteboard.data(forType: .tiff) != nil
        }
        viewer.clipboardSync = false
        #endif
        let closedBefore = try await closedCount()
        viewer.stop()
        try await wait("Close only the screen channel") { try await closedCount() > closedBefore }
        viewer.connect(in: state, port: port)
        try await wait("Prompt on reconnect") { !viewer.credentialTypes.isEmpty }
        viewer.stop() // Cancelling authentication must leave SSH usable too.
        try await wait("Close a pending authentication channel") { try await closedCount() > closedBefore + 1 }
        #if os(macOS)
        XCTAssertTrue(state.systemSSH != nil || state.remote?.isConnected == true)
        #else
        XCTAssertTrue(state.remote?.isConnected == true)
        #endif
    }
}
