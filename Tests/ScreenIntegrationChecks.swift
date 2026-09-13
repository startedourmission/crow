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
        viewer.connect(in: state, port: port)
        try await wait("Request screen credentials") { !viewer.credentialTypes.isEmpty }
        XCTAssertFalse(viewer.connected)
        XCTAssertEqual(viewer.credentialTypes, ["password"])
        viewer.authenticate(username: "", password: "fixture")
        try await wait("Complete RFB negotiation") { viewer.connected }
        XCTAssertEqual(viewer.name, "Crow Screen Fixture")
        try await wait("Render fragmented framebuffer") {
            try await js("const c = document.querySelector('canvas'); return c ? Array.from(c.getContext('2d').getImageData(0,0,1,1).data).join(',') : '';") == "255,0,0,255"
        }
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
        _ = try await js(#"const box = document.getElementById('view-only'); box.checked = true; box.dispatchEvent(new Event('change')); document.querySelector('[data-key="65307"]').click();"#)
        // An SSH/SFTP round trip gives pending input writes an opportunity to arrive.
        try await Task.sleep(for: .milliseconds(150))
        let log = try await recorded()
        XCTAssertFalse(log.contains("\"key\": 65307"), "View only must suppress remote input")
        XCTAssertFalse(log.contains("\"type\": \"error\""), log)
        XCTAssertTrue(log.contains("\"value\": 1"), "Allow concurrent VNC clients")
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
