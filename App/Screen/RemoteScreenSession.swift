import CrowCore
import SwiftUI
import WebKit
#if os(macOS)
import AppKit

private final class ScreenBrowserView: WKWebView {
    weak var screen: RemoteScreenSession?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let screen, screen.connected, screen.clipboardSync, !screen.viewOnly,
              let responder = window?.firstResponder as? NSView,
              responder === self || responder.isDescendant(of: self),
              event.modifierFlags.contains(.command),
              event.modifierFlags.intersection([.shift, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(), ["c", "v"].contains(key) else {
            return super.performKeyEquivalent(with: event)
        }
        screen.nativeClipboardShortcut(key)
        return true
    }
}
#endif

@MainActor private final class ScreenMessages: NSObject, WKScriptMessageHandler {
    weak var owner: RemoteScreenSession?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

@MainActor @Observable final class RemoteScreenSession: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private(set) var ready = false
    private(set) var active = false
    private(set) var connected = false
    private(set) var name = "Server Screen"
    private(set) var error: String?
    private(set) var credentialTypes: [String] = []
    var viewOnly = false { didSet { configureViewer() } }
    var fitToWindow = true { didSet { configureViewer() } }
    #if os(macOS)
    var clipboardSync = false {
        didSet { resetClipboard(); configureViewer(); monitorClipboard() }
    }
    var includeClipboardImages = false { didSet { resetClipboard(); configureViewer() } }
    private(set) var clipboardError: String?
    var pasteboard: NSPasteboard = .general
    var remotePasteboardName: String?
    private var clipboardChangeCount: Int?
    private var clipboardTask: Task<Void, Never>?
    private weak var clipboardWorkspace: WorkspaceState?
    private var remoteClipboardRevision: Int?
    private var nextClipboardPoll = Date.distantPast
    private var transferringClipboard = false
    #endif
    private var identifier = UUID().uuidString
    private var transport: ScreenTransport?
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var writing: Task<Void, Never>?
    private var configuring: Task<Void, Never>?
    private var pendingBytes = 0

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let messages = ScreenMessages()
        configuration.userContentController.add(messages, name: "screen")
        #if os(macOS)
        webView = ScreenBrowserView(frame: .zero, configuration: configuration)
        #else
        webView = WKWebView(frame: .zero, configuration: configuration)
        #endif
        super.init()
        #if os(macOS)
        (webView as? ScreenBrowserView)?.screen = self
        #endif
        messages.owner = self; webView.navigationDelegate = self
        #if os(iOS)
        webView.scrollView.isScrollEnabled = false
        #endif
        guard let url = Bundle.main.url(forResource: "screen", withExtension: "html") else {
            error = "The screen viewer is missing from this build."; return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func connect(in state: WorkspaceState, port: Int) {
        guard ready else { return }
        stop()
        identifier = UUID().uuidString
        let id = identifier, stream = ScreenTransport()
        transport = stream; active = true; error = nil; name = state.snapshot.workspace.name
        #if os(macOS)
        clipboardWorkspace = state
        #endif
        setDeadline(id)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let inbound = try await stream.open(in: state, port: port)
                try Task.checkCancellation()
                try await javascript("window.crowScreen.start(id)", ["id": id])
                for try await data in inbound {
                    try Task.checkCancellation()
                    guard identifier == id else { return }
                    try await javascript("window.crowScreen.receive(data, id)", ["data": data.base64EncodedString(), "id": id])
                }
                if identifier == id && !Task.isCancelled {
                    fail("The screen connection closed. Check that screen sharing is enabled on the SSH server.")
                }
            } catch is CancellationError { }
            catch { if identifier == id && !Task.isCancelled { fail(error.localizedDescription) } }
            stream.close()
        }
    }

    func authenticate(username: String, password: String) {
        let id = identifier
        credentialTypes = []; setDeadline(id)
        Task { [weak self] in
            do { try await self?.javascript("window.crowScreen.credentials(username, password, id)",
                ["username": username, "password": password, "id": id]) }
            catch { if self?.identifier == id { self?.fail(error.localizedDescription) } }
        }
    }

    func stop() {
        let old = identifier
        identifier = UUID().uuidString
        task?.cancel(); task = nil; deadline?.cancel(); deadline = nil
        writing?.cancel(); writing = nil; pendingBytes = 0
        transport?.close(); transport = nil
        active = false; connected = false; credentialTypes = []
        #if os(macOS)
        clipboardTask?.cancel(); clipboardTask = nil; clipboardChangeCount = nil
        clipboardWorkspace = nil; resetClipboard()
        #endif
        webView.callAsyncJavaScript("window.crowScreen?.stop(id)", arguments: ["id": old], in: nil, in: .page) { _ in }
    }

    private func setDeadline(_ id: String) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, identifier == id, !connected else { return }
            fail("Screen sharing did not respond. Enable it on the SSH server and check its VNC port and SSH forwarding permissions.")
        }
    }
    private func fail(_ message: String) { stop(); error = String(message.prefix(2000)) }
    private func javascript(_ script: String, _ arguments: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { value in
                switch value {
                case .success: result.resume()
                case .failure(let error): result.resume(throwing: error)
                }
            }
        }
    }

    private func configureViewer() {
        guard ready else { return }
        #if os(macOS)
        let desktop = true
        let clipboard = clipboardSync && !viewOnly
        let vncClipboard = clipboard && !includeClipboardImages
        #else
        let desktop = false
        let clipboard = false
        let vncClipboard = false
        #endif
        configuring = Task { [weak self] in
            guard let self else { return }
            do {
                try await javascript("window.crowScreen.configure(viewOnly, fit, desktop, clipboard, vncClipboard)",
                    ["viewOnly": viewOnly, "fit": fitToWindow, "desktop": desktop, "clipboard": clipboard, "vncClipboard": vncClipboard])
            } catch { fail(error.localizedDescription) }
        }
    }
    #if os(macOS)
    private func resetClipboard() {
        clipboardChangeCount = nil; remoteClipboardRevision = nil
        nextClipboardPoll = .distantPast; clipboardError = nil
    }
    private func monitorClipboard() {
        clipboardTask?.cancel(); clipboardTask = nil
        guard connected, clipboardSync else { return }
        clipboardTask = Task { [weak self] in
            while !Task.isCancelled {
                if NSApp.isActive, self?.webView.window?.isKeyWindow == true { await self?.syncClipboardIfNeeded() }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    func syncClipboardIfNeeded() async {
        await configuring?.value
        if includeClipboardImages { await syncNativeClipboard(); return }
        guard connected, clipboardSync, !viewOnly, pasteboard.changeCount != clipboardChangeCount else { return }
        clipboardChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), text.utf8.count <= 1_000_000 else { return }
        let id = identifier
        do { try await javascript("window.crowScreen.clipboard(text, id)", ["text": text, "id": id]) }
        catch { if identifier == id { fail(error.localizedDescription) } }
    }

    private func receiveClipboard(_ text: String) {
        guard clipboardSync, !includeClipboardImages, !viewOnly, connected, text.utf8.count <= 1_000_000 else { return }
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        clipboardChangeCount = pasteboard.changeCount
    }

    func syncNativeClipboard(pullOnly: Bool = false) async {
        guard connected, clipboardSync, includeClipboardImages, !viewOnly,
              clipboardError == nil, !transferringClipboard, let state = clipboardWorkspace else { return }
        let id = identifier, localRevision = pasteboard.changeCount
        var request = MacScreenClipboard.Packet(revision: remoteClipboardRevision)
        do {
            if !pullOnly, clipboardChangeCount != localRevision {
                if let png = try ClipboardImage.png(from: pasteboard) { request.png = png.base64EncodedString() }
                else if let text = pasteboard.string(forType: .string), text.utf8.count <= 1_000_000 { request.text = text }
            } else if !pullOnly, Date() < nextClipboardPoll { return }
            transferringClipboard = true
            defer { transferringClipboard = false }
            let response = try await MacScreenClipboard.exchange(request, in: state, pasteboardName: remotePasteboardName)
            guard identifier == id, connected, clipboardSync, includeClipboardImages, !viewOnly else { return }
            nextClipboardPoll = Date().addingTimeInterval(1.5)
            guard pasteboard.changeCount == localRevision else { return }
            if let encoded = response.png {
                guard let data = Data(base64Encoded: encoded) else { throw CommandError("Invalid clipboard image.") }
                try ClipboardImage.validate(data)
                // Decode and normalize before exposing data received from the server.
                let scratch = NSPasteboard(name: .init("crow-image-decode-" + UUID().uuidString))
                defer { scratch.releaseGlobally() }
                scratch.setData(data, forType: .png)
                guard let png = try ClipboardImage.png(from: scratch) else { throw CommandError("Invalid clipboard image.") }
                pasteboard.clearContents(); pasteboard.setData(png, forType: .png)
                if let image = NSImage(data: png), let tiff = image.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
            } else if let text = response.text, text.utf8.count <= 1_000_000 {
                pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
            }
            remoteClipboardRevision = response.revision
            clipboardChangeCount = pasteboard.changeCount
        } catch { if identifier == id { clipboardError = error.localizedDescription } }
    }

    private func pasteFromClient(_ modifiers: [String: Bool]) {
        let id = identifier
        Task { [weak self] in
            guard let self else { return }
            // Complete any earlier image transfer before reading the latest clipboard.
            while transferringClipboard, identifier == id {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
            guard identifier == id, connected, clipboardSync, !viewOnly else { return }
            clipboardChangeCount = nil
            await syncClipboardIfNeeded()
            guard identifier == id, connected, clipboardSync, !viewOnly, clipboardError == nil else { return }
            do { try await javascript("window.crowScreen.finishPaste(modifiers, id)", ["modifiers": modifiers, "id": id]) }
            catch { if identifier == id { fail(error.localizedDescription) } }
        }
    }

    fileprivate func nativeClipboardShortcut(_ key: String) {
        let id = identifier
        Task { [weak self] in
            guard let self else { return }
            do { try await javascript("window.crowScreen.nativeShortcut(key, id)", ["key": key, "id": id]) }
            catch { if identifier == id { fail(error.localizedDescription) } }
        }
    }

    private func copiedOnServer() {
        guard includeClipboardImages else { return }
        let id = identifier
        Task { [weak self] in
            // Remote applications update their pasteboard after the key event.
            for delay in [100, 300, 600] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard let self, identifier == id else { return }
                await syncNativeClipboard(pullOnly: true)
            }
        }
    }
    #endif
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === webView,
              message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        if action == "ready" { ready = true; configureViewer(); return }
        if action == "loaderror" { ready = false; fail(body["message"] as? String ?? "Unable to load the screen viewer."); return }
        guard active, body["session"] as? String == identifier else { return }
        switch action {
        case "connected":
            connected = true; deadline?.cancel(); deadline = nil
            #if os(macOS)
            monitorClipboard()
            #endif
        case "clipboard":
            #if os(macOS)
            if let text = body["text"] as? String { receiveClipboard(text) }
            #else
            break
            #endif
        case "paste":
            #if os(macOS)
            pasteFromClient(body["modifiers"] as? [String: Bool] ?? [:])
            #else
            break
            #endif
        case "copy":
            #if os(macOS)
            copiedOnServer()
            #else
            break
            #endif
        case "name": name = String((body["name"] as? String ?? name).prefix(200))
        case "credentials":
            credentialTypes = body["types"] as? [String] ?? ["password"]
            guard !credentialTypes.isEmpty, credentialTypes.allSatisfy({ ["username", "password"].contains($0) }) else {
                fail("This server requires an unsupported screen sharing login method."); return
            }
            deadline?.cancel(); deadline = nil
        case "error": fail(body["message"] as? String ?? "Screen connection failed.")
        case "disconnected": fail("Screen sharing disconnected. You can reconnect without closing the terminal.")
        case "send":
            guard let encoded = body["data"] as? String, encoded.utf8.count <= 1_500_000,
                  let data = Data(base64Encoded: encoded), let transport else { fail("Invalid screen input."); return }
            pendingBytes += data.count
            guard pendingBytes <= 2 * 1024 * 1024 else { fail("Screen input is queued faster than the connection can send it."); return }
            let prior = writing, id = identifier
            writing = Task { [weak self] in
                await prior?.value
                guard let self, identifier == id, !Task.isCancelled else { return }
                defer { if identifier == id { pendingBytes -= data.count } }
                do { try await transport.send(data) }
                catch { if identifier == id && !Task.isCancelled { fail(error.localizedDescription) } }
            }
        default: break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.isFileURL == true && url?.lastPathComponent == "screen.html" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; fail("The screen viewer stopped. Close and reopen Server Screen.") }
}
