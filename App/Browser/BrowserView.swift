import SwiftUI
import WebKit
import CrowCore

enum BrowserAddress {
    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "localhost.", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }
    static func parse(_ input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0.isNewline }), text.utf8.count <= 8192 else {
            throw CommandError("Enter a web address, such as localhost:3000 or https://example.com.")
        }
        if !text.contains("://") {
            let local = isLoopback(URLComponents(string: "http://" + text)?.host ?? "")
            text = (local ? "http://" : "https://") + text
        }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw CommandError("Use an HTTP or HTTPS address without a username or password.")
        }
        // Normalize equivalent loopback names for consistent forwarding.
        if host.lowercased() == "localhost." { components.host = "localhost" }
        guard let url = components.url else { throw CommandError("This web address is invalid.") }
        return url
    }
}

@MainActor @Observable final class BrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    var address = ""
    var title = "Browser"
    var error: String?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var webView: WKWebView?
    @ObservationIgnored let tunnel = BrowserTunnel()
    @ObservationIgnored private weak var workspace: WorkspaceState?
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored var onAddress: ((String) -> Void)?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private let ruleID = "crow-browser-" + UUID().uuidString
    init(workspace: WorkspaceState, address: String) {
        self.workspace = workspace; self.address = address
        super.init()
    }
    func prepare() async throws {
        guard webView == nil, workspace != nil, !closed else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = true
        webView = view
        observations = [view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.sync() }
        }, view.observe(\.title, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.sync() }
        }, view.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.sync() }
        }]
    }
    func open(_ input: String) {
        let url: URL
        do { url = try BrowserAddress.parse(input) } catch { self.error = error.localizedDescription; return }
        address = url.absoluteString; onAddress?(address); error = nil
        opening?.cancel()
        let requestID = UUID(); generation = requestID
        opening = Task { [weak self] in
            guard let self else { return }
            defer { if generation == requestID { opening = nil } }
            do {
                try await prepare(); try Task.checkCancellation()
                let latest = try BrowserAddress.parse(address)
                let destination = try await destination(latest)
                try Task.checkCancellation()
                webView?.load(URLRequest(url: destination)); isLoading = true
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; isLoading = false } }
        }
    }
    func resume() { if webView == nil, !address.isEmpty { open(address) } }
    func reload() { if webView?.url == nil { open(address) } else { error = nil; webView?.reload() } }
    func stopLoading() { opening?.cancel(); webView?.stopLoading(); isLoading = false }
    private func sync() {
        guard let view = webView else { return }
        isLoading = view.isLoading; canGoBack = view.canGoBack; canGoForward = view.canGoForward
        title = view.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Browser"
        if opening == nil, let loaded = view.url, ["http", "https"].contains(loaded.scheme?.lowercased() ?? "") {
            let url = tunnel.original(loaded)
            guard address != url.absoluteString else { return }
            address = url.absoluteString; onAddress?(address)
        }
    }
    private func destination(_ url: URL) async throws -> URL {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard let workspace, workspace.snapshot.workspace.isRemote else { return url }
        let destination = try await tunnel.forward(url, in: workspace)
        // A page's hard-coded localhost URL must never accidentally reach this device.
        var rules: [[String: Any]] = ["^[a-z]+://localhost[.]?[:/]", "^[a-z]+://127[.][0-9]+[.][0-9]+[.][0-9]+[:/]", "^[a-z]+://\\[::1\\][:/]"].map {
            ["trigger": ["url-filter": $0], "action": ["type": "block"]]
        }
        rules += tunnel.localPorts.map { port in
            ["trigger": ["url-filter": "^[a-z]+://127[.]0[.]0[.]1:\(port)/"], "action": ["type": "ignore-previous-rules"]]
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: ruleID, encodedContentRuleList: json) { list, error in
                if let error { continuation.resume(throwing: error) }
                else if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: CommandError("Could not configure remote browser routing.")) }
            }
        }
        try Task.checkCancellation()
        webView?.configuration.userContentController.removeAllContentRuleLists()
        webView?.configuration.userContentController.add(list)
        return destination
    }
    func disconnect() {
        generation = UUID()
        opening?.cancel(); opening = nil; webView?.stopLoading(); tunnel.stop()
        observations.removeAll(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil; webView = nil
        isLoading = false; canGoBack = false; canGoForward = false
        error = "SSH disconnected. Reconnect this workspace, then reload the page."
    }
    func close() {
        disconnect(); closed = true; onAddress = nil
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: ruleID) { _ in }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { error = nil; sync() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error = "The web page stopped. Reload to try again."; isLoading = false }
    private func failed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        self.error = error.localizedDescription; sync()
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if workspace?.snapshot.workspace.isRemote == true, BrowserAddress.isLoopback(url.host ?? ""),
           tunnel.original(url) == url, ["http", "https"].contains(scheme), url.user == nil, url.password == nil {
            decisionHandler(.cancel)
            if action.targetFrame?.isMainFrame != false {
                opening?.cancel()
                let requestID = UUID(); generation = requestID
                opening = Task { [weak self, weak webView] in
                    guard let self else { return }
                    defer { if generation == requestID { opening = nil } }
                    do {
                        var request = action.request
                        request.url = try await destination(url)
                        try Task.checkCancellation()
                        guard !closed, generation == requestID, self.webView === webView else { return }
                        webView?.load(request)
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
            }
            return
        }
        if ["http", "https", "about", "blob"].contains(scheme), url.user == nil, url.password == nil {
            decisionHandler(.allow)
        } else {
            if action.targetFrame?.isMainFrame != false { error = "This viewer supports HTTP and HTTPS pages." }
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { open(url.absoluteString) }
        return nil
    }
}

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    let session: BrowserSession
    let workspace: WorkspaceState
    @State private var input = ""
    @FocusState private var editing: Bool
    private var hostLabel: String {
        if let host = model.hosts.first(where: { $0.id == workspace.snapshot.workspace.hostID }) { return host.userAtHost }
        return workspace.snapshot.workspace.isRemote ? workspace.snapshot.workspace.name : "This device"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { session.webView?.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!session.canGoBack).help("Back")
                Button { session.webView?.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!session.canGoForward).help("Forward")
                Button { if session.isLoading { session.stopLoading() } else { session.reload() } } label: {
                    Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
                }.disabled(session.address.isEmpty).help(session.isLoading ? "Stop" : "Reload")
                TextField("URL or localhost:3000", text: $input)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($editing)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    #endif
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(CrowTheme.bg0, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(CrowTheme.border) }
                    .onSubmit { session.open(input); editing = false }
                    .accessibilityIdentifier("crow.browser.address")
                Button { session.open(input); editing = false } label: { Image(systemName: "arrow.right") }.help("Open Address")
            }.buttonStyle(CrowButtonStyle()).padding(10).background(CrowTheme.bg1).windowDragExcluded()
            HStack(spacing: 6) {
                Image(systemName: workspace.snapshot.workspace.isRemote ? "network" : "desktopcomputer")
                Text(workspace.snapshot.workspace.isRemote ? "localhost → \(hostLabel) via SSH" : "localhost → This device")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    #if os(macOS)
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.address, forType: .string)
                    #else
                    UIPasteboard.general.string = session.address
                    #endif
                } label: { Image(systemName: "doc.on.doc") }
                    .disabled(session.address.isEmpty).help("Copy URL")
            }.font(.system(size: 11)).foregroundStyle(CrowTheme.textDim).buttonStyle(CrowButtonStyle())
                .padding(.horizontal, 12).padding(.vertical, 5).windowDragExcluded()
            CrowDivider()
            if let error = session.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry") { session.reload() }.disabled(session.address.isEmpty)
                }.font(.system(size: 12)).foregroundStyle(CrowTheme.textDim).padding(12)
            }
            if let web = session.webView { BrowserWebView(web: web).id(ObjectIdentifier(web)) }
            else {
                VStack(spacing: 16) {
                    Image(systemName: "globe").font(.system(size: 32)).foregroundStyle(CrowTheme.textDim)
                    Text("Open a website or development server").font(.system(size: 16, weight: .medium))
                    Text(workspace.snapshot.workspace.isRemote ? "Localhost addresses open on \(hostLabel)." : "Enter an address above to browse here.")
                        .font(.system(size: 12)).foregroundStyle(CrowTheme.textDim)
                    HStack(spacing: 12) {
                        ForEach([3000, 5173, 8080], id: \.self) { port in
                            Button("localhost:\(port)") { session.open("localhost:\(port)") }
                        }
                    }.font(.system(size: 12)).buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
            }
        }.background(CrowTheme.bg0).foregroundStyle(CrowTheme.text)
            .onAppear { input = session.address; session.resume() }
            .onChange(of: session.address) { _, value in if !editing { input = value } }
            .accessibilityIdentifier("crow.browser")
    }
}

private struct BrowserWebView {
    let web: WKWebView
}
#if os(macOS)
extension BrowserWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension BrowserWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

extension AppModel {
    func browser(_ id: UUID, in state: WorkspaceState) -> BrowserSession {
        if let existing = state.browsers[id] { return existing }
        let session = BrowserSession(workspace: state, address: state.snapshot.browserAddresses[id] ?? "")
        session.onAddress = { [weak self, weak state] value in
            state?.snapshot.browserAddresses[id] = value; self?.schedulePersist()
        }
        state.browsers[id] = session
        return session
    }
    func newBrowser(in paneID: UUID? = nil, address: String = "") {
        let id = UUID()
        current.snapshot.browserAddresses[id] = address
        ensureLayout(current); current.snapshot.layout?.open(.browser(id), in: paneID)
        compactSurface = .editor
        schedulePersist()
    }
}
