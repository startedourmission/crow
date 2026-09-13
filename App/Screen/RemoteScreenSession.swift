import CrowCore
import SwiftUI
import WebKit

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
    private var identifier = UUID().uuidString
    private var transport: ScreenTransport?
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var writing: Task<Void, Never>?
    private var pendingBytes = 0

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let messages = ScreenMessages()
        configuration.userContentController.add(messages, name: "screen")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
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
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === webView,
              message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        if action == "ready" { ready = true; return }
        if action == "loaderror" { ready = false; fail(body["message"] as? String ?? "Unable to load the screen viewer."); return }
        guard active, body["session"] as? String == identifier else { return }
        switch action {
        case "connected": connected = true; deadline?.cancel(); deadline = nil
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
