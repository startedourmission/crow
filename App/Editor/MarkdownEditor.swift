import CrowCore
import SwiftUI
import WebKit

struct MarkdownPreviewView: View {
    @Binding var text: String
    let fontSize: Double
    var onSave: () -> Void = {}
    var locationRequest: EditorLocationRequest?
    var onOpenLink: ((String) -> Void)?
    var noteLinksEnabled = false
    @State private var failure: String?
    var body: some View {
        VStack(spacing: 0) {
            if let failure {
                Text("Markdown editor: \(failure)").font(.system(size: 12)).foregroundStyle(.red).padding(12)
                NativeEditor(text: $text, fontSize: fontSize, indentWidth: 4, lineNumbers: false,
                    findRequest: 0, onSave: onSave, locationRequest: locationRequest)
            } else {
                MarkdownWebView(text: $text, fontSize: fontSize, onSave: onSave, failure: $failure, locationRequest: locationRequest, onOpenLink: onOpenLink, noteLinksEnabled: noteLinksEnabled)
            }
        }
    }
}

@MainActor private final class MarkdownNavigation: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var source: String?
    var onOpenLink: ((String) -> Void)?
    var noteLinksEnabled = false
    var fontSize: Double?
    var text: Binding<String> = .constant("")
    var onSave: () -> Void = {}
    var failure: Binding<String?> = .constant(nil)
    var loaded = false
    var readyForInput = false
    var onReadyForInput: (Bool) -> Void = { _ in }
    var locationRequest: EditorLocationRequest?
    var lastLocation: UUID?
    private var renderTask: Task<Void, Never>?
    private var renderID = UUID()
    private var rendering = false
    func navigate(_ webView: WKWebView) {
        guard loaded, !rendering, let request = locationRequest, lastLocation != request.id, let heading = request.headingIndex else { return }
        lastLocation = request.id
        webView.callAsyncJavaScript("return window.crowMarkdown.jumpHeading(index)", arguments: ["index": heading],
            in: nil, in: .defaultClient) { [weak self] result in
                if case .failure(let error) = result { self?.failure.wrappedValue = error.localizedDescription }
            }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true; render(webView)
    }
    func render(_ webView: WKWebView, force: Bool = false) {
        guard loaded else { return }
        let value = text.wrappedValue
        // Font changes must not reparse or resend the whole document.
        if source == value && !force {
            webView.callAsyncJavaScript("window.crowMarkdown.setFontSize(fontSize)",
                arguments: ["fontSize": fontSize ?? 15], in: nil, in: .defaultClient) { [weak self] result in
                    if case .failure(let error) = result { self?.failure.wrappedValue = error.localizedDescription }
                    else { self?.navigate(webView) }
                }
            return
        }
        source = value
        readyForInput = false; onReadyForInput(false)
        renderTask?.cancel()
        rendering = true
        let id = UUID(); renderID = id
        let cached = MarkdownBlockCache.blocks(for: value)
        renderTask = Task { [weak self, weak webView] in
            let blocks: [MarkdownPreview.EditingBlock]
            if let cached { blocks = cached }
            else {
                // Parsing/source mapping can be expensive; never block AppKit/SwiftUI.
                let worker = Task.detached(priority: .userInitiated) {
                    MarkdownPreview.editingBlocks(value)
                }
                blocks = await withTaskCancellationHandler { await worker.value }
                    onCancel: { worker.cancel() }
            }
            guard !Task.isCancelled, let self, let webView,
                  self.renderID == id, self.text.wrappedValue == value else { return }
            if cached == nil { MarkdownBlockCache.insert(blocks, for: value) }
            webView.callAsyncJavaScript("window.crowMarkdown.receive(source, blocks, fontSize, noteLinksEnabled)",
                arguments: ["source": value, "blocks": blocks.map { ["source": $0.source, "html": $0.html] },
                    "fontSize": self.fontSize ?? 15, "noteLinksEnabled": self.noteLinksEnabled], in: nil, in: .defaultClient) { [weak self] result in
                    guard let self, self.renderID == id else { return }
                    self.rendering = false; self.renderTask = nil
                    if case .failure(let error) = result { self.failure.wrappedValue = error.localizedDescription }
                    else {
                        self.readyForInput = true; self.onReadyForInput(true)
                        self.navigate(webView)
                    }
                }
        }
    }
    func stop() {
        renderTask?.cancel(); renderTask = nil
        renderID = UUID(); loaded = false
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let view = message.webView,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "error": failure.wrappedValue = body["message"] as? String ?? "Unable to initialize the editor."
        case "change":
            guard let value = body["source"] as? String, let base = body["base"] as? String else { return }
            // A second pane or reload may have replaced the document since this edit began.
            guard text.wrappedValue == base else { render(view, force: true); return }
            source = value; text.wrappedValue = value
        case "render": render(view, force: true)
        case "save": onSave()
        #if os(iOS)
        case "keyboardModifiersConsumed": (view as? CrowMarkdownWebView)?.keyboardAccessory.resetModifiers()
        case "keyboardClipboard":
            if body["key"] as? String == "v" {
                if let text = UIPasteboard.general.string { (view as? CrowMarkdownWebView)?.insertSnippet(text) }
            } else if let text = body["text"] as? String { UIPasteboard.general.string = text }
        #endif
        case "openLink":
            guard let value = body["url"] as? String else { return }
            if let onOpenLink { onOpenLink(value); return }
            guard let url = URL(string: value), MarkdownPreview.isExternalLink(url) else { return }
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
            if let url = navigationAction.request.url, let onOpenLink { onOpenLink(url.absoluteString) }
            else if let url = navigationAction.request.url, MarkdownPreview.isExternalLink(url) {
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
    #if os(iOS)
    @Environment(\.phoneKeyboardFocus) private var keyboard
    @Environment(\.editorKeyboardFocus) private var editorKeyboard
    @Environment(\.editorRendererActive) private var rendererActive
    @Environment(\.keyboardBarItems) private var keyboardBarItems
    #endif
    @Binding var text: String
    let fontSize: Double
    var onSave: () -> Void
    @Binding var failure: String?
    var locationRequest: EditorLocationRequest?
    var onOpenLink: ((String) -> Void)?
    var noteLinksEnabled = false
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
        #if os(iOS)
        let view = CrowMarkdownWebView(frame: .zero, configuration: configuration)
        #else
        let view = WKWebView(frame: .zero, configuration: configuration)
        #endif
        view.navigationDelegate = coordinator
        coordinator.text = $text; coordinator.onSave = onSave; coordinator.fontSize = fontSize; coordinator.failure = $failure
        coordinator.locationRequest = locationRequest
        coordinator.onOpenLink = onOpenLink
        coordinator.noteLinksEnabled = noteLinksEnabled
        view.loadHTMLString(MarkdownPreview.document("", fontSize: fontSize), baseURL: nil)
        return view
    }
    func update(_ view: WKWebView, coordinator: MarkdownNavigation) {
        coordinator.text = $text; coordinator.onSave = onSave; coordinator.failure = $failure
        coordinator.locationRequest = locationRequest
        coordinator.onOpenLink = onOpenLink
        let linksChanged = coordinator.noteLinksEnabled != noteLinksEnabled
        coordinator.noteLinksEnabled = noteLinksEnabled
        guard coordinator.source != text || coordinator.fontSize != fontSize || linksChanged else { coordinator.navigate(view); return }
        coordinator.fontSize = fontSize
        coordinator.render(view, force: linksChanged)
    }
}
#if os(macOS)
extension MarkdownWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
    static func dismantleNSView(_ view: WKWebView, coordinator: MarkdownNavigation) {
        coordinator.stop(); view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "markdown", contentWorld: .defaultClient)
    }
}
#else
extension MarkdownWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {
        (view as? CrowMarkdownWebView)?.configureKeyboard(keyboardBarItems)
        let focus: () -> Void = { [weak view] in
            view?.becomeFirstResponder()
            view?.evaluateJavaScript("document.querySelector('[contenteditable=true]')?.focus()", in: nil, in: .defaultClient)
        }
        editorKeyboard?.register(view, preview: true, ready: context.coordinator.readyForInput, focus: focus)
        context.coordinator.onReadyForInput = { [weak editorKeyboard] in editorKeyboard?.renderedReady($0) }
        if rendererActive { keyboard?.register(view, surface: .editor, focus: focus) }
        update(view, coordinator: context.coordinator)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: MarkdownNavigation) {
        coordinator.stop(); view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "markdown", contentWorld: .defaultClient)
    }
}
#endif

/// Reopening the same source reuses its exact source maps; never cache by path alone.
/// Bounded and memory-pressure-evictable, including both source and HTML costs.
@MainActor private enum MarkdownBlockCache {
    private final class Entry {
        let blocks: [MarkdownPreview.EditingBlock]
        init(_ blocks: [MarkdownPreview.EditingBlock]) { self.blocks = blocks }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 8; cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    static func blocks(for source: String) -> [MarkdownPreview.EditingBlock]? {
        cache.object(forKey: source as NSString)?.blocks
    }
    static func insert(_ blocks: [MarkdownPreview.EditingBlock], for source: String) {
        let cost = source.utf8.count + blocks.reduce(0) { $0 + $1.source.utf8.count + $1.html.utf8.count }
        guard cost <= cache.totalCostLimit else { return }
        cache.setObject(Entry(blocks), forKey: source as NSString, cost: cost)
    }
}

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

/// Link indexing is opt-in and starts only when the backlinks section is expanded.
struct WorkspaceMarkdownView: View {
    @Environment(AppModel.self) private var model
    let buffer: OpenBuffer
    @Binding var text: String
    var locationRequest: EditorLocationRequest?
    @State private var expanded = false
    @State private var backlinks: [String] = []
    @State private var loading = false
    @State private var warning: String?
    @State private var refresh = 0
    private var scope: String { "\(buffer.id)-\(buffer.path)-\(model.settings.effectiveNoteLinksEnabled)-\(expanded)-\(refresh)" }
    var body: some View {
        VStack(spacing: 0) {
            MarkdownPreviewView(text: $text, fontSize: model.settings.fontSize,
                onSave: { Task { await model.saveBuffer(buffer.id) } }, locationRequest: locationRequest,
                onOpenLink: { model.openMarkdownLink($0, from: buffer.id) }, noteLinksEnabled: model.settings.effectiveNoteLinksEnabled)
            if model.settings.effectiveNoteLinksEnabled {
                DisclosureGroup(isExpanded: $expanded) {
                    HStack {
                        if loading { ProgressView().controlSize(.small) }
                        Text(warning ?? (backlinks.isEmpty ? "No backlinks in this workspace." : "\(backlinks.count) linked notes"))
                            .font(.caption).foregroundStyle(CrowTheme.textDim)
                        Spacer()
                        Button { refresh += 1 } label: { PanelActionIcon(symbol: "arrow.clockwise") }
                            .buttonStyle(CrowButtonStyle()).disabled(loading).help("Refresh backlinks")
                    }
                    if !backlinks.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(backlinks, id: \.self) { path in
                                    Button(path) { model.openMarkdownWorkspaceFile(path, from: buffer.id) }
                                        .buttonStyle(.plain).font(.system(size: 12)).lineLimit(1)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 110)
                    }
                } label: { Text("Backlinks").font(.system(size: 12)) }
                .padding(10).background(CrowTheme.bg0).windowDragExcluded()
            }
        }
        .task(id: scope) {
            guard expanded, model.settings.effectiveNoteLinksEnabled, let (state, _) = model.locate(buffer.id) else { return }
            backlinks = []; warning = nil; loading = true
            do {
                let root = state.snapshot.rootPath
                let (files, message) = try await ObsidianFiles.inventory(in: state)
                let notes = Dictionary(uniqueKeysWithValues: files.compactMap { item -> (String, String)? in
                    guard let path = item["path"] as? String, let text = item["text"] as? String else { return nil }
                    return (path, text)
                })
                let target = String(buffer.path.dropFirst(root == "/" ? 1 : root.count + 1))
                let worker = Task.detached(priority: .utility) { NoteLinks.backlinks(to: target, notes: notes) }
                let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                backlinks = result; warning = message; loading = false
            } catch { if !Task.isCancelled { warning = error.localizedDescription; loading = false } }
        }
    }
}

extension AppModel {
    func openMarkdownLink(_ value: String, from bufferID: BufferID) {
        guard let (state, index) = locate(bufferID) else { return }
        if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            do { _ = try BrowserAddress.parse(value) } catch { report(error); return }
            activateWorkspace(state.id, reconnect: false); newBrowser(address: value); return
        }
        if let url = URL(string: value), url.scheme?.lowercased() == "mailto" {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
            return
        }
        guard settings.effectiveNoteLinksEnabled, URL(string: value)?.scheme == nil else { return }
        let root = state.snapshot.rootPath, source = state.snapshot.buffers[index].path
        Task {
            do {
                let files: [[String: Any]]
                if let cached = ObsidianFiles.cachedInventory(in: state) { files = cached }
                else { files = try await ObsidianFiles.inventory(in: state).0 }
                let paths = Set(files.compactMap { $0["path"] as? String })
                let relative = String(source.dropFirst(root == "/" ? 1 : root.count + 1))
                guard let target = NoteLinks.resolve(value, from: relative, paths: paths) else {
                    throw CommandError("The linked file was not found or its name is ambiguous. Use a workspace-relative path.")
                }
                try Task.checkCancellation()
                guard locate(bufferID)?.0 === state, state.snapshot.rootPath == root else { return }
                openMarkdownWorkspaceFile(target, from: bufferID)
            } catch { if !Task.isCancelled { report(error) } }
        }
    }
    func openMarkdownWorkspaceFile(_ relative: String, from bufferID: BufferID) {
        guard let (state, _) = locate(bufferID) else { return }
        Task {
            do {
                let path = try await ObsidianFiles.resolve(relative, in: state)
                guard states.contains(where: { $0 === state }) else { return }
                activateWorkspace(state.id, reconnect: false)
                openFile(FileEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: false))
            } catch { report(error) }
        }
    }
}
