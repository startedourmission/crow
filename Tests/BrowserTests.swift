import XCTest
import WebKit
import SwiftUI
import CrowCore
@testable import Crow

@MainActor final class BrowserTests: XCTestCase {
    func testAddressesAndBrowserTabPersistence() throws {
        XCTAssertEqual(try BrowserAddress.parse("localhost:3000/a?q=1#part").absoluteString, "http://localhost:3000/a?q=1#part")
        XCTAssertEqual(try BrowserAddress.parse("127.0.0.1:5173").scheme, "http")
        XCTAssertEqual(try BrowserAddress.parse("[::1]:8080").scheme, "http")
        XCTAssertEqual(try BrowserAddress.parse("example.com").scheme, "https")
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "http://user:password@localhost", "http://localhost:99999", "", "https://bad address"] {
            XCTAssertThrowsError(try BrowserAddress.parse(bad), bad)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-browser-model-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.newBrowser(address: "http://localhost:3000")
        let pane = try XCTUnwrap(model.current.snapshot.layout?.activePane)
        guard case .browser(let id) = pane.selected else { return XCTFail("Browser must be selected") }
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(model.current.snapshot))
        XCTAssertEqual(snapshot.browserAddresses[id], "http://localhost:3000")
        XCTAssertEqual(snapshot.layout?.activePane?.selected, .browser(id))
        let session = model.browser(id, in: model.current)
        model.newTab(); XCTAssertTrue(model.browser(id, in: model.current) === session)
        model.closeTab(.browser(id), in: pane.id)
        XCTAssertNil(model.current.browsers[id]); XCTAssertNil(model.current.snapshot.browserAddresses[id])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        legacy.removeValue(forKey: "browserAddresses")
        let restored = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(restored.browserAddresses.isEmpty)
    }

    #if os(macOS)
    func testWebPagesAndSocketsThroughBothSSHTransports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-browser-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func process(_ executable: String, _ arguments: [String]) throws -> Process {
            let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            try task.run(); return task
        }
        func run(_ executable: String, _ arguments: [String]) throws {
            let task = try process(executable, arguments); task.waitUntilExit(); XCTAssertEqual(task.terminationStatus, 0)
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/Browser/fixture.py")
        let portFile = root.appendingPathComponent("http-port")
        let http = try process("/usr/bin/python3", [fixture.path, portFile.path])
        defer { if http.isRunning { http.terminate(); http.waitUntilExit() } }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: portFile.path) { try await Task.sleep(for: .milliseconds(50)) }
        let httpPort = try String(contentsOf: portFile, encoding: .utf8)
        let local = WorkspaceState(.init(workspace: Workspace(name: "Local", kind: .local, connection: .local), rootPath: root.path))
        try await verifyPage(in: local, port: httpPort, forwarded: false)

        let hostKey = root.appendingPathComponent("host-key").path, userKey = root.appendingPathComponent("user-key").path
        for path in [hostKey, userKey] { try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path]) }
        let sshPort = Int.random(in: 23000...45000)
        let config = root.appendingPathComponent("sshd_config")
        try Data("""
        Port \(sshPort)
        ListenAddress 127.0.0.1
        HostKey \(hostKey)
        PidFile \(root.path)/sshd.pid
        AuthorizedKeysFile \(userKey).pub
        StrictModes no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        AllowUsers \(NSUserName())
        Subsystem sftp /usr/libexec/sftp-server
        """.utf8).write(to: config)
        let sshd = try process("/usr/sbin/sshd", ["-D", "-e", "-f", config.path])
        defer { if sshd.isRunning { sshd.terminate(); sshd.waitUntilExit() } }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(sshd.isRunning)
        let knownHosts = root.appendingPathComponent("known_hosts")
        try Data("[127.0.0.1]:\(sshPort) \(try String(contentsOfFile: hostKey + ".pub", encoding: .utf8))".utf8).write(to: knownHosts)
        let socket = "/tmp/crow-browser-" + String(UUID().uuidString.prefix(10))
        let master = try process("/usr/bin/ssh", ["-F", "/dev/null", "-M", "-S", socket, "-N", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(knownHosts.path)", "-i", userKey, "-p", String(sshPort), NSUserName() + "@127.0.0.1"])
        defer { if master.isRunning { master.terminate(); master.waitUntilExit() }; try? FileManager.default.removeItem(atPath: socket) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) { try await Task.sleep(for: .milliseconds(50)) }
        var host = SSHHost(name: "Browser fixture", hostname: "127.0.0.1", port: sshPort, username: NSUserName(), remotePath: root.path)
        host.authentication = .ed25519
        let remote = WorkspaceState(.init(workspace: Workspace(name: "Remote", kind: .remote(hostID: host.id, path: root.path), connection: .connected), rootPath: root.path))
        remote.systemSSH = SystemSSHSpec(host: host, socket: socket, arguments: [], directory: root.path)
        try await verifyPage(in: remote, port: httpPort, forwarded: true)
        let noteFolder = root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: noteFolder, withIntermediateDirectories: true)
        for index in 0..<32 { try Data("---\nnumber: \(index)\n---\nBody\n".utf8).write(to: noteFolder.appendingPathComponent("Note-\(index).md")) }
        let systemFiles = RemoteConnection()
        try systemFiles.attach(try XCTUnwrap(remote.systemSSH)); remote.remote = systemFiles
        try await verifyInventory(in: remote)
        await systemFiles.disconnect(); remote.remote = nil
        remote.systemSSH = nil

        let credential = HostCredential(privateKey: try String(contentsOfFile: userKey, encoding: .utf8))
        let account = "host-key:127.0.0.1:\(sshPort)", prior = try SecureStore.data(for: "host-key:127.0.0.1:\(sshPort)")
        defer { if let prior { try? SecureStore.set(prior, for: account) } else { try? SecureStore.remove(account) } }
        try SecureStore.remove(account)
        do { try await RemoteConnection().connect(host, credential: credential); XCTFail("Untrusted fixture must fail") }
        catch let challenge as HostKeyChallenge { try SecureStore.set(Data(challenge.key.utf8), for: account) }
        let connection = RemoteConnection()
        try await connection.connect(host, credential: credential); remote.remote = connection
        defer { Task { await connection.disconnect() } }
        try await verifyPage(in: remote, port: httpPort, forwarded: true)
        XCTAssertTrue(connection.isConnected, "Closing a browser must preserve SSH/SFTP")
        try await verifyInventory(in: remote)

        remote.remote = nil
        let blocked = BrowserSession(workspace: remote, address: "")
        defer { blocked.close() }
        blocked.open("http://localhost:\(httpPort)/page")
        for _ in 0..<100 where blocked.error == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNotNil(blocked.error, "Disconnected SSH must never fall back to this device's localhost")
        XCTAssertGreaterThan(blocked.tunnel.acceptedConnections, 0)
    }

    private func verifyInventory(in state: WorkspaceState) async throws {
        let (files, warning) = try await ObsidianFiles.inventory(in: state)
        let notes = files.filter { ($0["path"] as? String)?.hasPrefix("Notes/Note-") == true }
        XCTAssertEqual(notes.count, 32, warning ?? "")
        XCTAssertTrue(notes.allSatisfy { ($0["text"] as? String)?.contains("number:") == true })
    }

    private func verifyPage(in state: WorkspaceState, port: String, forwarded: Bool) async throws {
        let session = BrowserSession(workspace: state, address: "")
        defer { session.close() }
        try await session.prepare()
        let web = try XCTUnwrap(session.webView)
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
        defer { window.close() }
        session.open("http://localhost:\(port)/redirect")
        var result = ""
        for _ in 0..<150 {
            result = (try? await web.evaluateJavaScript("document.body?.dataset.result || ''")) as? String ?? ""
            if result == "asset-ok,socket-ok" || session.error != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(result, "asset-ok,socket-ok", "Forwarded=\(forwarded): \(session.error ?? "No error")")
        XCTAssertTrue(session.address.contains("localhost:\(port)/page"), session.address)
        if forwarded {
            XCTAssertGreaterThanOrEqual(session.tunnel.acceptedConnections, 2, "Document and WebSocket must use SSH")
            let blocked = try await web.callAsyncJavaScript("try { await fetch(url); return false; } catch { return true; }",
                arguments: ["url": "http://localhost:\(port)/asset"], in: nil, contentWorld: .page) as? Bool
            XCTAssertEqual(blocked, true, "Hard-coded loopback subresources must not reach this device")
        }
        else { XCTAssertEqual(session.tunnel.acceptedConnections, 0) }
        XCTAssertTrue(web.configuration.websiteDataStore.isPersistent, "Authentication cookies must survive browser recreation")
        let openerURL = web.url
        let opened = try await web.evaluateJavaScript("""
            window.addEventListener('message', e => document.body.dataset.popupMessage = e.data);
            window.fixturePopup = window.open('about:blank', '_blank');
            !!window.fixturePopup;
            """) as? Bool
        XCTAssertEqual(opened, true, "window.open must return a real browsing context")
        let popup = try XCTUnwrap(session.popups.last)
        let popupWeb = try XCTUnwrap(popup.webView)
        XCTAssertTrue(popup.tunnel === session.tunnel)
        XCTAssertEqual(web.url, openerURL, "Opening a popup must preserve the original page")
        _ = try await popupWeb.evaluateJavaScript("window.opener.postMessage('popup-ok', '*')")
        var message = ""
        for _ in 0..<50 {
            message = (try? await web.evaluateJavaScript("document.body.dataset.popupMessage || ''")) as? String ?? ""
            if message == "popup-ok" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(message, "popup-ok")
        _ = try await web.evaluateJavaScript("""
            const form = document.createElement('form');
            form.method = 'POST'; form.action = '/popup'; form.target = 'post-popup';
            const field = document.createElement('input'); field.name = 'token'; field.value = 'popup-token';
            form.append(field); document.body.append(form); form.submit();
            """)
        for _ in 0..<100 where session.popups.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        let postPopup = try XCTUnwrap(session.popups.last)
        let postWeb = try XCTUnwrap(postPopup.webView)
        var posted = ""
        for _ in 0..<100 {
            posted = (try? await postWeb.evaluateJavaScript("document.body?.textContent || ''")) as? String ?? ""
            if posted.contains("token=popup-token") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(posted.contains("token=popup-token"), "Popup POST body must be preserved: \(posted)")
        postPopup.onClose?()
        _ = try await popupWeb.evaluateJavaScript("window.close()")
        for _ in 0..<50 where !session.popups.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(session.popups.isEmpty)
        if forwarded { XCTAssertFalse(session.tunnel.localPorts.isEmpty, "Closing a popup must preserve its opener's SSH tunnels") }
        let reviewRoot = FileManager.default.temporaryDirectory.appendingPathComponent("crow-browser-ui-" + UUID().uuidString)
        let model = AppModel(vaultURL: reviewRoot)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: reviewRoot) }
        let hosting = NSHostingView(rootView: BrowserView(session: session, workspace: state).environment(model))
        window.contentView = hosting; hosting.frame = .init(x: 0, y: 0, width: 700, height: 500)
        hosting.layoutSubtreeIfNeeded()
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/crow-browser-review.png"))
        }
        session.close(); XCTAssertNil(session.webView); XCTAssertTrue(session.tunnel.localPorts.isEmpty)
    }
    #endif
}
