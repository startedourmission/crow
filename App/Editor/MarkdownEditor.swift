import CrowCore
import SwiftUI
import WebKit

struct MarkdownPreviewView: View {
    @Binding var text: String
    let fontSize: Double
    var onSave: () -> Void = {}
    @State private var failure: String?
    var body: some View {
        VStack(spacing: 0) {
            if let failure {
                Text("Markdown editor: \(failure)").font(.system(size: 12)).foregroundStyle(.red).padding(12)
                NativeEditor(text: $text, fontSize: fontSize, indentWidth: 4, lineNumbers: false,
                    findRequest: 0, onSave: onSave)
            } else {
                MarkdownWebView(text: $text, fontSize: fontSize, onSave: onSave, failure: $failure)
            }
        }
    }
}

@MainActor private final class MarkdownNavigation: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var source: String?
    var fontSize: Double?
    var text: Binding<String> = .constant("")
    var onSave: () -> Void = {}
    var failure: Binding<String?> = .constant(nil)
    var loaded = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true; render(webView)
    }
    func render(_ webView: WKWebView) {
        guard loaded else { return }
        let value = text.wrappedValue
        source = value
        let blocks = MarkdownPreview.editingBlocks(value).map { ["source": $0.source, "html": $0.html] }
        webView.callAsyncJavaScript("window.crowMarkdown.receive(source, blocks, fontSize)",
            arguments: ["source": value, "blocks": blocks, "fontSize": fontSize ?? 15],
            in: nil, in: .defaultClient) { [weak self] result in
                if case .failure(let error) = result { self?.failure.wrappedValue = error.localizedDescription }
            }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let view = message.webView,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "error": failure.wrappedValue = body["message"] as? String ?? "Unable to initialize the editor."
        case "change":
            guard let value = body["source"] as? String, let base = body["base"] as? String else { return }
            // A second pane or reload may have replaced the document since this edit began.
            guard text.wrappedValue == base else { render(view); return }
            source = value; text.wrappedValue = value
        case "render": render(view)
        case "save": onSave()
        case "openLink":
            guard let value = body["url"] as? String, let url = URL(string: value), MarkdownPreview.isExternalLink(url) else { return }
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url, MarkdownPreview.isExternalLink(url) {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
            }
            decisionHandler(.cancel)
        } else { decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel) }
    }
}

@MainActor private struct MarkdownWebView {
    @Binding var text: String
    let fontSize: Double
    var onSave: () -> Void
    @Binding var failure: String?
    func makeCoordinator() -> MarkdownNavigation { MarkdownNavigation() }
    func makeView(_ coordinator: MarkdownNavigation) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        // Only our isolated script can edit the buffer. Notes still cannot run scripts,
        // fetch resources, or reach the native message handler in the page world.
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "markdown")
        configuration.userContentController.addUserScript(WKUserScript(source: MarkdownLiveEditing.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        coordinator.text = $text; coordinator.onSave = onSave; coordinator.fontSize = fontSize; coordinator.failure = $failure
        view.loadHTMLString(MarkdownPreview.document("", fontSize: fontSize), baseURL: nil)
        return view
    }
    func update(_ view: WKWebView, coordinator: MarkdownNavigation) {
        coordinator.text = $text; coordinator.onSave = onSave; coordinator.failure = $failure
        guard coordinator.source != text || coordinator.fontSize != fontSize else { return }
        coordinator.fontSize = fontSize
        coordinator.render(view)
    }
}
#if os(macOS)
extension MarkdownWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
}
#else
extension MarkdownWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
}
#endif

/// The bundled editor runs offline in WebKit's isolated client world.
private enum MarkdownLiveEditing {
    static let script: String = {
        guard let url = Bundle.main.url(forResource: "markdown-editor", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            return "window.webkit.messageHandlers.markdown.postMessage({action:'error',message:'Missing bundled Markdown editor. Rebuild the application.'});"
        }
        return """
        try {
        \(script)
        } catch (error) {
          window.webkit.messageHandlers.markdown.postMessage({action:'error',message:String(error.stack || error)});
        }
        """
    }()
}
