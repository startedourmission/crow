import CrowCore
import SwiftUI
import WebKit

struct ObsidianDocumentView: View {
    @Environment(AppModel.self) private var model
    let buffer: OpenBuffer
    var isActive = false
    @State private var source = false
    @State private var refresh = 0
    @State private var find = 0
    private var kind: String { (buffer.path as NSString).pathExtension.lowercased() }
    private var text: Binding<String> {
        Binding(get: { model.locate(buffer.id).map { $0.0.snapshot.buffers[$0.1].text } ?? buffer.text },
                set: { model.updateBufferText(buffer.id, $0) })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(kind == "canvas" ? "Canvas" : "Bases").font(.system(size: 11, weight: .semibold))
                Spacer()
                if !source { Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }.help("Refresh Preview") }
                Button { source.toggle() } label: { Image(systemName: source ? "rectangle.grid.2x2" : "chevron.left.forwardslash.chevron.right") }
                    .help(source ? "Rendered Preview" : "Edit Source").accessibilityIdentifier("crow.obsidian.source-toggle")
                Button { source = true; find += 1 } label: { Image(systemName: "magnifyingglass") }.help("Find in Source")
                EditorFileMenu(buffer: buffer)
            }.buttonStyle(CrowButtonStyle()).padding(.horizontal, 12).padding(.vertical, 6)
                .background(CrowTheme.bg0).windowDragExcluded()
            if source {
                NativeEditor(text: text, fontSize: model.settings.fontSize, indentWidth: model.settings.indentWidth,
                    lineNumbers: model.settings.lineNumbers, findRequest: find,
                    onSave: { Task { await model.saveBuffer(buffer.id) } }, focused: isActive)
            } else {
                ObsidianWebView(model: model, bufferID: buffer.id, source: text.wrappedValue, kind: kind, refresh: refresh)
            }
        }
        .task(id: buffer.path) { await model.observeBuffer(buffer.id) }
        .onChange(of: model.documentFindRequest) { _, _ in if isActive { source = true; find += 1 } }
    }
}

/// Every path is scoped to the workspace that owns the document, even after a tab switch.
@MainActor enum ObsidianFiles {
    static func resolve(_ relative: String, in state: WorkspaceState) async throws -> String {
        guard !relative.isEmpty, !relative.contains("\0"), !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), !relative.contains("://") else {
            throw CommandError("Choose a file inside this workspace.")
        }
        let root: String, path: String
        if let remote = state.remote, state.snapshot.workspace.isRemote {
            root = try await remote.realPath(state.snapshot.rootPath)
            path = try await remote.realPath((root as NSString).appendingPathComponent(relative))
            guard state.remote === remote else { throw FileFailure.disconnected }
        } else if !state.snapshot.workspace.isRemote {
            root = URL(fileURLWithPath: state.snapshot.rootPath).resolvingSymlinksInPath().path
            let candidate = URL(fileURLWithPath: root).appendingPathComponent(relative)
            path = candidate.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(candidate.lastPathComponent).resolvingSymlinksInPath().path
        } else { throw FileFailure.disconnected }
        guard path != root, path.hasPrefix(root == "/" ? "/" : root + "/") else { throw CommandError("The linked file is outside this workspace.") }
        return path
    }
    static func bytes(_ path: String, in state: WorkspaceState, limit: Int) async throws -> Data {
        if state.snapshot.workspace.isRemote {
            guard let remote = state.remote else { throw FileFailure.disconnected }
            return try await remote.readData(path, maximumSize: limit)
        }
        return try await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path)
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= limit else { throw FileFailure.tooLarge }
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            let data = try file.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { throw FileFailure.tooLarge }; return data
        }.value
    }
    static func asset(_ relative: String, in state: WorkspaceState) async throws -> [String: String] {
        let path = try await resolve(relative, in: state)
        let ext = (path as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "tiff"].contains(ext) {
            let data = try await bytes(path, in: state, limit: 8 * 1024 * 1024)
            let preview = try await Task.detached(priority: .utility) { try ImagePreview.decode(data) }.value
            #if os(macOS)
            guard let png = NSBitmapImageRep(cgImage: preview.image).representation(using: .png, properties: [:]) else { throw FileFailure.unsupportedText }
            #else
            guard let png = UIImage(cgImage: preview.image).pngData() else { throw FileFailure.unsupportedText }
            #endif
            return ["image": "data:image/png;base64," + png.base64EncodedString()]
        }
        guard ["md", "markdown", "txt"].contains(ext) else { return ["error": "Open this attachment to view it."] }
        let data = try await bytes(path, in: state, limit: 1024 * 1024)
        let html = try await Task.detached(priority: .utility) { MarkdownPreview.body(try TextFiles.decode(data)) }.value
        return ["html": html]
    }
    static func inventory(in state: WorkspaceState) async throws -> ([[String: Any]], String?) {
        let root = state.snapshot.workspace.isRemote ? state.snapshot.rootPath : URL(fileURLWithPath: state.snapshot.rootPath).resolvingSymlinksInPath().path
        var queue = [root], files: [[String: Any]] = [], warnings = Set<String>(), total = 0
        var visited = 0
        while let folder = queue.popLast() {
            try Task.checkCancellation()
            visited += 1
            if visited > 3000 || files.count >= 2000 { warnings.insert("Preview limited to 2,000 files / 3,000 folders."); break }
            let entries: [FileEntry]
            do {
                if state.snapshot.workspace.isRemote {
                    guard let remote = state.remote else { throw FileFailure.disconnected }
                    entries = try await remote.list(folder)
                } else {
                    entries = try await Task.detached(priority: .utility) {
                        try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).compactMap { url in
                            let attrs = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                            guard attrs.isSymbolicLink != true else { return nil }
                            return FileEntry(name: url.lastPathComponent, path: (folder as NSString).appendingPathComponent(url.lastPathComponent), isDirectory: attrs.isDirectory == true)
                        }
                    }.value
                }
            } catch { warnings.insert("Some folders could not be read."); continue }
            for entry in entries.sorted(by: { $0.path < $1.path }) where !entry.isHidden && entry.name != "node_modules" {
                if entry.isDirectory { queue.append(entry.path); continue }
                if files.count >= 2000 { warnings.insert("Preview limited to 2,000 files."); break }
                let relative = String(entry.path.dropFirst(root == "/" ? 1 : root.count + 1))
                var item: [String: Any] = ["path": relative]
                do {
                    let path = try await resolve(relative, in: state)
                    if state.snapshot.workspace.isRemote {
                        if let revision = try await state.remote?.revision(path) {
                            if let size = revision.size { item["size"] = size }
                            if let modified = revision.modified { item["modified"] = modified.timeIntervalSince1970 }
                        }
                    } else {
                        let attrs = try FileManager.default.attributesOfItem(atPath: path)
                        item["size"] = attrs[.size]
                        item["modified"] = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
                        item["created"] = (attrs[.creationDate] as? Date)?.timeIntervalSince1970
                    }
                    if ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) {
                        if total >= 20 * 1024 * 1024 { throw FileFailure.tooLarge }
                        let bytes = try await bytes(path, in: state, limit: 512 * 1024)
                        total += bytes.count; item["text"] = try TextFiles.decode(bytes)
                    }
                    files.append(item)
                } catch { warnings.insert("Unreadable or oversized notes were omitted (512 KB per note, 20 MB total).") }
            }
        }
        return (files, warnings.isEmpty ? nil : warnings.sorted().joined(separator: " "))
    }
}

@MainActor private struct ObsidianWebView {
    let model: AppModel
    let bufferID: BufferID
    let source: String
    let kind: String
    let refresh: Int
    func makeCoordinator() -> Coordinator { Coordinator(model: model, bufferID: bufferID) }
    func makeView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.add(coordinator, contentWorld: .defaultClient, name: "obsidian")
        let script = Bundle.main.url(forResource: "obsidian-preview", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let style = Bundle.main.url(forResource: "obsidian-preview", withExtension: "css").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = coordinator
        view.loadHTMLString("<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:;\"><style>\(style)</style></head><body><main>Loading preview…</main></body></html>", baseURL: nil)
        update(view, coordinator: coordinator)
        return view
    }
    func update(_ view: WKWebView, coordinator: Coordinator) {
        guard coordinator.source != source || coordinator.refresh != refresh else { return }
        coordinator.source = source; coordinator.kind = kind; coordinator.refresh = refresh
        coordinator.render(view)
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: AppModel
        let bufferID: BufferID
        var source = "", kind = "", refresh = -1, ready = false
        var task: Task<Void, Never>?
        var assets: [String: Task<Void, Never>] = [:]
        var assetTail: Task<Void, Never>?
        var assetBytes = 0
        init(model: AppModel, bufferID: BufferID) { self.model = model; self.bufferID = bufferID }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; render(webView) }
        func render(_ view: WKWebView) {
            guard ready, let (state, index) = model.locate(bufferID) else { return }
            task?.cancel(); assets.values.forEach { $0.cancel() }; assets.removeAll(); assetTail = nil; assetBytes = 0
            let value = source, format = kind, path = state.snapshot.buffers[index].path
            task = Task { [weak self, weak view] in
                guard let self, let view else { return }
                var payload: [String: Any] = ["source": value, "kind": format, "path": String(path.dropFirst(state.snapshot.rootPath == "/" ? 1 : state.snapshot.rootPath.count + 1))]
                do {
                    if format == "base" {
                        let (files, warning) = try await ObsidianFiles.inventory(in: state)
                        payload["files"] = files; payload["warning"] = warning
                    } else {
                        let html = await Task.detached(priority: .utility) {
                            var result: [String: String] = [:]
                            if let doc = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any], let nodes = doc["nodes"] as? [[String: Any]], nodes.count <= 2000 {
                                for node in nodes { if let id = node["id"] as? String, let text = node["text"] as? String { result[id] = MarkdownPreview.body(text) } }
                            }
                            return result
                        }.value
                        payload["html"] = html
                    }
                    try Task.checkCancellation()
                    _ = try await view.callAsyncJavaScript("window.crowObsidian.receive(payload)", arguments: ["payload": payload], in: nil, contentWorld: .defaultClient)
                } catch is CancellationError {} catch {
                    _ = try? await view.callAsyncJavaScript("document.querySelector('main').textContent = message", arguments: ["message": error.localizedDescription], in: nil, contentWorld: .defaultClient)
                }
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: String], let action = body["action"],
                  let path = body["path"], let (state, _) = model.locate(bufferID) else { return }
            if action == "asset", let id = body["id"], let view = message.webView {
                guard assets.count < 2000 else { return }
                let previous = assetTail
                let request = Task { [weak view] in
                    await previous?.value
                    guard !Task.isCancelled else { return }
                    var result: [String: String]
                    do {
                        guard self.assetBytes < 24 * 1024 * 1024 else { throw CommandError("Canvas attachment preview limit reached (24 MB). Open the file to view it.") }
                        result = try await ObsidianFiles.asset(path, in: state)
                        self.assetBytes += result.values.reduce(0) { $0 + $1.utf8.count }
                    }
                    catch { result = ["error": error.localizedDescription] }
                    guard !Task.isCancelled else { return }
                    _ = try? await view?.callAsyncJavaScript("window.crowObsidian.asset(id, value)", arguments: ["id": id, "value": result], in: nil, contentWorld: .defaultClient)
                }
                assets[id] = request; assetTail = request
            } else if action == "open" {
                if let url = URL(string: path), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    UIApplication.shared.open(url)
                    #endif
                    return
                }
                Task {
                    do {
                        let relative = String(path.split(separator: "#", maxSplits: 1).first ?? "")
                        let resolved = try await ObsidianFiles.resolve((relative as NSString).pathExtension.isEmpty ? relative + ".md" : relative, in: state)
                        guard model.states.contains(where: { $0 === state }) else { return }
                        model.activateWorkspace(state.id, reconnect: false)
                        model.openFile(FileEntry(name: (resolved as NSString).lastPathComponent, path: resolved, isDirectory: false))
                    } catch { model.report(error) }
                }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType != .linkActivated && action.request.url?.scheme == "about" ? .allow : .cancel)
        }
        func stop() { task?.cancel(); assets.values.forEach { $0.cancel() }; assets.removeAll(); assetTail = nil; assetBytes = 0 }
    }
}
#if os(macOS)
extension ObsidianWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop(); view.configuration.userContentController.removeScriptMessageHandler(forName: "obsidian", contentWorld: .defaultClient) }
}
#else
extension ObsidianWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop(); view.configuration.userContentController.removeScriptMessageHandler(forName: "obsidian", contentWorld: .defaultClient) }
}
#endif
