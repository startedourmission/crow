import CrowCore
import CryptoKit
import SwiftUI
import WebKit

@MainActor @Observable final class ObsidianPreviewStatus {
    var message: String?
    var loading = false
    @ObservationIgnored var cancel: (() -> Void)?
}

struct ObsidianDocumentView: View {
    @Environment(AppModel.self) private var model
    let buffer: OpenBuffer
    var isActive = false
    @State private var source = false
    @State private var refresh = 0
    @State private var find = 0
    @State private var status = ObsidianPreviewStatus()
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
                if let message = status.message {
                    HStack(spacing: 8) {
                        if status.loading { ProgressView().controlSize(.small) }
                        Text(message).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        if status.loading { Button("Stop") { status.cancel?() } }
                    }.foregroundStyle(CrowTheme.textDim).padding(10)
                }
                ObsidianWebView(model: model, bufferID: buffer.id, source: text.wrappedValue, kind: kind, refresh: refresh, status: status)
            }
        }
        .task(id: buffer.path) { await model.observeBuffer(buffer.id) }
        .onChange(of: model.documentFindRequest) { _, _ in if isActive { source = true; find += 1 } }
    }
}

/// Every path is scoped to the workspace that owns the document, even after a tab switch.
@MainActor enum ObsidianFiles {
    /// Send only changed records after the first snapshot. Large note bodies must
    /// not cross the WebKit bridge again at every inventory progress update.
    struct InventoryUpdates {
        private var previous: [String: NSDictionary] = [:]
        private var started = false
        mutating func payload(_ files: [[String: Any]]) -> [String: Any] {
            let next = Dictionary(uniqueKeysWithValues: files.compactMap { file in
                (file["path"] as? String).map { ($0, file as NSDictionary) }
            })
            let changed = files.filter { file in
                guard let path = file["path"] as? String, let old = previous[path] else { return true }
                return !old.isEqual(to: file)
            }
            let result: [String: Any] = ["files": changed, "incremental": started,
                "removed": previous.keys.filter { next[$0] == nil }]
            previous = next; started = true
            return result
        }
    }
    private final class InventoryCache {
        var files: [[String: Any]]
        let warning: String?
        init(_ files: [[String: Any]], warning: String? = nil) { self.files = files; self.warning = warning }
    }
    private static let inventories: NSCache<NSString, InventoryCache> = {
        let cache = NSCache<NSString, InventoryCache>()
        cache.countLimit = 4; cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private static func inventoryKey(_ state: WorkspaceState) -> NSString {
        "\(state.id)-\(state.snapshot.rootPath)-\(state.remote.map { String(describing: ObjectIdentifier($0)) } ?? "local")" as NSString
    }
    static func updateCachedNote(_ path: String, text: String, in state: WorkspaceState) {
        let root = state.snapshot.rootPath
        guard path.hasPrefix(root + "/"), ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) else { return }
        let relative = String(path.dropFirst(root.count + 1))
        state.noteCatalog.update(path: relative, text: text)
        guard let cached = inventories.object(forKey: inventoryKey(state)) else { return }
        if let index = cached.files.firstIndex(where: { $0["path"] as? String == relative }) {
            cached.files[index]["text"] = text; cached.files[index].removeValue(forKey: "modified")
        } else { cached.files.append(["path": relative, "text": text]) }
    }
    static func cachedInventory(in state: WorkspaceState) -> [[String: Any]]? {
        inventories.object(forKey: inventoryKey(state))?.files
    }
    static func writeNote(_ relative: String, expected: String, replacement: String, in state: WorkspaceState, model: AppModel) async throws {
        guard ["md", "markdown"].contains((relative as NSString).pathExtension.lowercased()),
              replacement.utf8.count <= TextFiles.sizeLimit else { throw CommandError("Only Markdown note properties can be edited here.") }
        let path = try await resolve(relative, in: state)
        func matches(_ buffer: OpenBuffer) -> Bool {
            state.snapshot.workspace.isRemote ? buffer.path == path : URL(fileURLWithPath: buffer.path).resolvingSymlinksInPath().path == path
        }
        guard model.states.contains(where: { $0 === state }),
              !state.movingPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { throw CommandError("This note moved or its workspace was closed.") }
        if let buffer = state.snapshot.buffers.first(where: matches), buffer.isDirty || buffer.text != expected {
            throw CommandError("This note has changed in an editor. Save it and refresh the Base before editing its properties.")
        }
        if state.snapshot.workspace.isRemote {
            guard let remote = state.remote else { throw FileFailure.disconnected }
            try await remote.write(replacement, path: path, expected: expected)
        } else {
            try TextFiles.write(replacement, to: URL(fileURLWithPath: path), expected: expected)
        }
        if let cached = inventories.object(forKey: inventoryKey(state)),
           let index = cached.files.firstIndex(where: { $0["path"] as? String == relative }) {
            cached.files[index]["text"] = replacement
            cached.files[index].removeValue(forKey: "modified") // Revalidate this note on the next scan.
        }
        updateCachedNote(path, text: replacement, in: state)
        if let index = state.snapshot.buffers.firstIndex(where: matches) {
            if state.snapshot.buffers[index].text == expected && !state.snapshot.buffers[index].isDirty {
                state.snapshot.buffers[index].text = replacement
            }
            state.snapshot.buffers[index].savedText = replacement
            state.snapshot.buffers[index].isDirty = state.snapshot.buffers[index].text != replacement
            model.schedulePersist()
        }
    }

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
    private static let thumbnails: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 600
        return cache
    }()
    static func asset(_ relative: String, in state: WorkspaceState) async throws -> [String: String] {
        let path = try await resolve(relative, in: state)
        let ext = (path as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "tiff"].contains(ext) {
            var cacheKey: NSString?
            if !state.snapshot.workspace.isRemote {
                let metadata = try await Task.detached(priority: .utility) {
                    let url = URL(fileURLWithPath: path)
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey])
                    if values.ubiquitousItemDownloadingStatus == .notDownloaded && values.ubiquitousItemIsDownloading != true {
                        try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    }
                    return (size: values.fileSize ?? 0, modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                            unavailable: values.ubiquitousItemDownloadingStatus == .notDownloaded)
                }.value
                guard !metadata.unavailable else {
                    return ["pending": "true", "error": "Downloading image from iCloud…"]
                }
                cacheKey = "\(path)|\(metadata.size)|\(metadata.modified)" as NSString
                if let cacheKey, let image = thumbnails.object(forKey: cacheKey) { return ["image": image as String] }
            }
            let data = try await bytes(path, in: state, limit: 8 * 1024 * 1024)
            let image = try await Task.detached(priority: .utility) { try ImagePreview.canvasThumbnail(data) }.value
            try Task.checkCancellation()
            if let cacheKey { thumbnails.setObject(image as NSString, forKey: cacheKey, cost: image.utf8.count) }
            return ["image": image]
        }
        guard ["md", "markdown", "txt"].contains(ext) else { return ["error": "Open this attachment to view it."] }
        let data = try await bytes(path, in: state, limit: 1024 * 1024)
        let html = try await Task.detached(priority: .utility) { MarkdownPreview.body(try TextFiles.decode(data)) }.value
        return ["html": html]
    }
    private struct LocalInventoryItem: Sendable, Codable {
        var path: String
        var size: Int?
        var modified: Date?
        var created: Date?
        var text: String?
        var payload: [String: Any] {
            var value: [String: Any] = ["path": path]
            if let size { value["size"] = size }
            if let modified { value["modified"] = modified.timeIntervalSince1970 }
            if let created { value["created"] = created.timeIntervalSince1970 }
            if let text { value["text"] = text }
            return value
        }
        init(_ value: [String: Any]) {
            path = value["path"] as? String ?? ""
            size = (value["size"] as? NSNumber)?.intValue
            modified = (value["modified"] as? Double).map(Date.init(timeIntervalSince1970:))
            created = (value["created"] as? Double).map(Date.init(timeIntervalSince1970:))
            text = value["text"] as? String
        }
        init(path: String, attributes: URLResourceValues) {
            self.path = path; size = attributes.fileSize
            modified = attributes.contentModificationDate; created = attributes.creationDate
        }
    }
    private static func publishLocal(_ items: [LocalInventoryItem], folders: Int,
        progress: @MainActor ([[String: Any]], Int) async -> Void) async {
        await progress(items.map(\.payload), folders)
    }
    // Enumerate names first, then overlap a bounded number of reads. A slow
    // iCloud document must not delay discovering every other note in the vault.
    private nonisolated static func localInventory(root: String, previous: [LocalInventoryItem],
        progress: @Sendable ([LocalInventoryItem], Int) async -> Void) async throws -> ([LocalInventoryItem], String?) {
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var warning = Set<String>()
        guard let entries = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { throw FileFailure.unsupportedText }
        let cached = Dictionary(uniqueKeysWithValues: previous.map { ($0.path, $0) })
        var files: [LocalInventoryItem] = [], jobs: [(Int, URL)] = [], total = 0, folders = 0, cloudNotes = 0
        while let url = entries.nextObject() as? URL {
            try Task.checkCancellation()
            if files.count >= 20000 || folders >= 3000 { warning.insert("Preview limited to 20,000 files / 3,000 folders."); break }
            do {
                let attributes = try url.resourceValues(forKeys: keys)
                if attributes.isSymbolicLink == true { continue }
                if attributes.isDirectory == true {
                    if url.lastPathComponent == "node_modules" { entries.skipDescendants() } else { folders += 1 }
                    continue
                }
                guard attributes.isRegularFile == true else { continue }
                let path = url.pathComponents.suffix(entries.level).joined(separator: "/")
                var item = LocalInventoryItem(path: path, attributes: attributes)
                if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                    guard (item.size ?? 0) <= 512 * 1024, total + (item.size ?? 512 * 1024) <= 20 * 1024 * 1024 else { throw FileFailure.tooLarge }
                    total += item.size ?? 512 * 1024
                    if let old = cached[path], let text = old.text, item.size != nil, item.size == old.size, item.modified != nil, item.modified == old.modified { item.text = text }
                    else if attributes.isUbiquitousItem == true && attributes.ubiquitousItemDownloadingStatus == .notDownloaded { cloudNotes += 1 }
                    else { jobs.append((files.count, url)) }
                }
                files.append(item)
                if files.count == 1 { await progress(files, folders) }
            } catch { warning.insert("Some files could not be read (512 KB per note, 20 MB total).") }
        }
        if cloudNotes > 0 { warning.insert("\(cloudNotes) iCloud notes are not downloaded. Their properties and tags will be available after downloading and refreshing the index.") }
        await progress(files, folders)
        var lastReport = Date()
        await withTaskGroup(of: (Int, String?).self) { group in
            var next = 0
            func enqueue(_ job: (Int, URL)) {
                group.addTask {
                    guard !Task.isCancelled else { return (job.0, nil) }
                    do {
                        let handle = try FileHandle(forReadingFrom: job.1); defer { try? handle.close() }
                        let data = try handle.read(upToCount: 512 * 1024 + 1) ?? Data()
                        guard data.count <= 512 * 1024 else { return (job.0, nil) }
                        return (job.0, try TextFiles.decode(data))
                    } catch { return (job.0, nil) }
                }
            }
            while next < min(8, jobs.count) { enqueue(jobs[next]); next += 1 }
            for await (index, text) in group {
                files[index].text = text
                if text == nil { warning.insert("Some notes could not be read.") }
                if Task.isCancelled { group.cancelAll(); break }
                if next < jobs.count { enqueue(jobs[next]); next += 1 }
                if Date().timeIntervalSince(lastReport) > 0.5 { lastReport = Date(); await progress(files, folders) }
            }
        }
        try Task.checkCancellation()
        return (files.sorted { $0.path < $1.path }, warning.isEmpty ? nil : warning.sorted().joined(separator: " "))
    }
    private struct SavedNoteIndex: Codable, Sendable {
        var items: [LocalInventoryItem]
        var warning: String?
    }
    private static func noteIndexURL(_ root: String) -> URL {
        let name = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crow/NoteIndex/" + name + ".json")
    }
    private static func readInventoryNote(_ details: RemoteFileListing, connection: RemoteConnection,
        root: String) async -> (String, Result<Data, Error>) {
        do {
            try Task.checkCancellation()
            let path = try await connection.realPath(details.entry.path)
            guard path.hasPrefix(root == "/" ? "/" : root + "/") else { throw CommandError("The linked file is outside this workspace.") }
            return (details.entry.path, .success(try await connection.readData(path, maximumSize: 512 * 1024)))
        } catch { return (details.entry.path, .failure(error)) }
    }
    static func inventory(in state: WorkspaceState, preferCached: Bool = false,
        progress: @escaping @MainActor @Sendable ([[String: Any]], Int) async -> Void = { _, _ in }) async throws -> ([[String: Any]], String?) {
        let remote = state.snapshot.workspace.isRemote
        if remote && state.remote == nil { throw FileFailure.disconnected }
        let root = state.snapshot.rootPath, key = inventoryKey(state)
        if state.snapshot.isNoteVault, !remote, inventories.object(forKey: key) == nil {
            let file = noteIndexURL(root)
            let worker = Task.detached(priority: .utility) { () -> SavedNoteIndex? in
                guard let data = try? Data(contentsOf: file), data.count <= 64 * 1024 * 1024 else { return nil }
                return try? JSONDecoder().decode(SavedNoteIndex.self, from: data)
            }
            if let saved = await worker.value {
                let files = saved.items.map(\.payload)
                inventories.setObject(InventoryCache(files, warning: saved.warning), forKey: key, cost: saved.items.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) + 256 })
            }
        }
        let previous = inventories.object(forKey: key)?.files ?? []
        if preferCached && !previous.isEmpty { await progress(previous, 0); return (previous, inventories.object(forKey: key)?.warning) }
        let cached = Dictionary(uniqueKeysWithValues: previous.compactMap { item in (item["path"] as? String).map { ($0, item) } })
        var queue = [root], files: [[String: Any]] = [], warnings = Set<String>(), total = 0, visited = 0
        var lastReport = Date.distantPast
        try Task.checkCancellation()
        await progress(previous, 0)
        if !remote {
            let cachedItems = previous.map(LocalInventoryItem.init)
            let worker = Task.detached(priority: .userInitiated) {
                try await localInventory(root: root, previous: cachedItems) { items, folders in
                    await publishLocal(items, folders: folders, progress: progress)
                }
            }
            let (items, warning) = try await withTaskCancellationHandler { try await worker.value }
                onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard inventoryKey(state) == key else { throw CancellationError() }
            let result = items.map(\.payload)
            inventories.setObject(InventoryCache(result, warning: warning), forKey: key, cost: items.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) + 256 })
            if state.snapshot.isNoteVault {
                let file = noteIndexURL(root)
                Task.detached(priority: .utility) {
                    do {
                        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try JSONEncoder().encode(SavedNoteIndex(items: items, warning: warning)).write(to: file, options: .atomic)
                    } catch {} // An unavailable cache must never prevent opening the notes.
                }
            }
            return (result, warning)
        }
        guard let connection = state.remote else { throw FileFailure.disconnected }
        let canonicalRoot = try await connection.realPath(root)
        var published = cached
        func cachedText(_ details: RemoteFileListing) -> String? {
            let relative = String(details.entry.path.dropFirst(root == "/" ? 1 : root.count + 1))
            guard let old = cached[relative], let text = old["text"] as? String,
                  let size = details.size, (old["size"] as? NSNumber)?.uint64Value == size,
                  let modified = details.modified, (old["modified"] as? Double) == modified.timeIntervalSince1970,
                  Date().timeIntervalSince(modified) > 2 else { return nil }
            return text
        }
        while let folder = queue.popLast() {
            try Task.checkCancellation()
            guard state.remote === connection else { throw FileFailure.disconnected }
            visited += 1
            if visited > 3000 || files.count >= 20000 { warnings.insert("Preview limited to 20,000 files / 3,000 folders."); break }
            let entries: [RemoteFileListing]
            do {
                entries = try await connection.listing(folder).filter {
                    let type = ($0.permissions ?? 0) & 0o170000
                    return !$0.entry.isHidden && $0.entry.name != "node_modules" && (type == 0o040000 || type == 0o100000)
                }.sorted { $0.entry.path < $1.entry.path }
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); warnings.insert("Some folders could not be read."); continue }
            for offset in stride(from: 0, to: entries.count, by: 8) {
                try Task.checkCancellation()
                let batch = Array(entries[offset..<min(entries.count, offset + 8)])
                let candidates = batch.filter {
                    !$0.entry.isDirectory && ["md", "markdown"].contains(($0.entry.path as NSString).pathExtension.lowercased()) &&
                    ($0.size ?? 0) <= 512 * 1024 && total < 20 * 1024 * 1024 && cachedText($0) == nil
                }
                // Bound concurrency and memory while overlapping SFTP round trips.
                let contents = await withTaskGroup(of: (String, Result<Data, Error>).self) { group in
                    for details in candidates {
                        group.addTask { await readInventoryNote(details, connection: connection, root: canonicalRoot) }
                    }
                    var values: [String: Result<Data, Error>] = [:]
                    for await (path, data) in group { values[path] = data }
                    return values
                }
                guard state.remote === connection else { throw FileFailure.disconnected }
                for details in batch {
                    try Task.checkCancellation()
                    let entry = details.entry
                    if entry.isDirectory { queue.append(entry.path); continue }
                    if files.count >= 20000 { warnings.insert("Preview limited to 20,000 files."); break }
                    let relative = String(entry.path.dropFirst(root == "/" ? 1 : root.count + 1))
                    var item: [String: Any] = ["path": relative]
                    if let size = details.size { item["size"] = size }
                    if let date = details.modified { item["modified"] = date.timeIntervalSince1970 }
                    if let date = details.created { item["created"] = date.timeIntervalSince1970 }
                    do {
                        if ["md", "markdown"].contains((entry.path as NSString).pathExtension.lowercased()) {
                            if total >= 20 * 1024 * 1024 || (details.size ?? 0) > 512 * 1024 { throw FileFailure.tooLarge }
                            if let text = cachedText(details) { item["text"] = text; total += text.utf8.count }
                            else {
                                guard let result = contents[entry.path] else { throw FileFailure.unsupportedText }
                                let data = try result.get(); total += data.count; item["text"] = try TextFiles.decode(data)
                            }
                        }
                        files.append(item); published[relative] = item
                    } catch is CancellationError { throw CancellationError() }
                    catch { try Task.checkCancellation(); warnings.insert("Unreadable or oversized notes were omitted (512 KB per note, 20 MB total).") }
                }
                if Date().timeIntervalSince(lastReport) > 0.5 {
                    lastReport = Date(); await progress(published.values.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }, visited)
                }
            }
        }
        try Task.checkCancellation()
        guard inventoryKey(state) == key else { throw CancellationError() }
        inventories.setObject(InventoryCache(files), forKey: key, cost: total + files.count * 256)
        return (files, warnings.isEmpty ? nil : warnings.sorted().joined(separator: " "))
    }

}

@MainActor private struct ObsidianWebView {
    let model: AppModel
    let bufferID: BufferID
    let source: String
    let kind: String
    let refresh: Int
    let status: ObsidianPreviewStatus
    func makeCoordinator() -> Coordinator { Coordinator(model: model, bufferID: bufferID, status: status) }
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
        coordinator.begin()
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
        let status: ObsidianPreviewStatus
        var source = "", kind = "", refresh = -1, ready = false
        var task: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var lastProgress = Date()
        var assets: [String: Task<Void, Never>] = [:]
        var assetLanes: [Task<Void, Never>?] = Array(repeating: nil, count: 4)
        var nextAssetLane = 0
        var assetBytes = 0
        weak var preview: WKWebView?
        init(model: AppModel, bufferID: BufferID, status: ObsidianPreviewStatus) { self.model = model; self.bufferID = bufferID; self.status = status }
        func begin() {
            watchdog?.cancel(); lastProgress = Date()
            watchdog = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                status.loading = true; status.message = "Preparing preview…"
                status.cancel = { [weak self] in self?.finishEarly("Stopped. Showing files already loaded. Refresh to try again, or open Source.") }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    if Date().timeIntervalSince(lastProgress) >= 30 {
                        finishEarly("File loading stalled. Showing files already loaded. Refresh to retry.")
                        return
                    }
                }
            }
        }
        func finishEarly(_ message: String) {
            task?.cancel(); watchdog?.cancel(); status.loading = false; status.message = message; status.cancel = nil
            let expected = source
            Task { [weak preview] in
                _ = try? await preview?.callAsyncJavaScript("window.crowObsidian.stopLoading(source, message)",
                    arguments: ["source": expected, "message": message], in: nil, contentWorld: .defaultClient)
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; render(webView) }
        func render(_ view: WKWebView) {
            guard ready, let (state, index) = model.locate(bufferID) else { return }
            preview = view
            task?.cancel(); assets.values.forEach { $0.cancel() }; assets.removeAll(); assetLanes = Array(repeating: nil, count: 4); nextAssetLane = 0; assetBytes = 0
            begin()
            let value = source, format = kind, path = state.snapshot.buffers[index].path
            task = Task { [weak self, weak view] in
                guard let self, let view else { return }
                var payload: [String: Any] = ["source": value, "kind": format, "selectedView": state.baseViews[bufferID] ?? 0, "path": String(path.dropFirst(state.snapshot.rootPath == "/" ? 1 : state.snapshot.rootPath.count + 1))]
                do {
                    if format == "base" {
                        let valid = try await view.callAsyncJavaScript("return window.crowObsidian.validateBase(payload)", arguments: ["payload": payload], in: nil, contentWorld: .defaultClient) as? Bool
                        guard valid == true else { finishEarly("This Base could not be rendered. See the error below or open Source."); return }
                        var updates = ObsidianFiles.InventoryUpdates()
                        let (files, warning) = try await ObsidianFiles.inventory(in: state, preferCached: state.snapshot.isNoteVault && self.refresh == 0) { files, folders in
                            guard !Task.isCancelled else { return }
                            self.lastProgress = Date()
                            self.status.message = "Loading notes: \(files.filter { $0["text"] is String }.count) read · \(files.count) files"
                            var partial = payload; partial["source"] = self.source; partial["loading"] = true
                            partial.merge(updates.payload(files)) { _, next in next }
                            _ = try? await view.callAsyncJavaScript("window.crowObsidian.receive(payload)", arguments: ["payload": partial], in: nil, contentWorld: .defaultClient)
                        }
                        payload.merge(updates.payload(files)) { _, next in next }
                        payload["warning"] = warning
                    } else {
                        let html = await Task.detached(priority: .utility) {
                            var result: [String: String] = [:]
                            if let doc = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any], let nodes = doc["nodes"] as? [[String: Any]], nodes.count <= 2000 {
                                for node in nodes { if let id = node["id"] as? String, let text = node["text"] as? String { result[id] = MarkdownPreview.body(text) } }
                            }
                            return result
                        }.value
                        if value == self.source { payload["html"] = html }
                    }
                    try Task.checkCancellation()
                    payload["source"] = self.source
                    _ = try await view.callAsyncJavaScript("window.crowObsidian.receive(payload)", arguments: ["payload": payload], in: nil, contentWorld: .defaultClient)
                    try Task.checkCancellation()
                    watchdog?.cancel(); status.loading = false; status.message = nil; status.cancel = nil
                } catch is CancellationError {} catch {
                    guard !Task.isCancelled else { return }
                    watchdog?.cancel(); status.loading = false; status.message = error.localizedDescription; status.cancel = nil
                    _ = try? await view.callAsyncJavaScript("window.crowObsidian.failed(message)", arguments: ["message": error.localizedDescription], in: nil, contentWorld: .defaultClient)
                }
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: String], let action = body["action"],
                  let (state, index) = model.locate(bufferID) else { return }
            if action == "selectView", let raw = body["index"], let selected = Int(raw), selected >= 0 {
                state.baseViews[bufferID] = selected
                return
            }
            if action == "change", let replacement = body["source"], let expected = body["expected"] {
                guard replacement.utf8.count <= TextFiles.sizeLimit,
                      state.snapshot.buffers[index].text == expected else {
                    let current = state.snapshot.buffers[index].text
                    Task { [weak view = message.webView] in
                        _ = try? await view?.callAsyncJavaScript("window.crowObsidian.rejectSource(source)",
                            arguments: ["source": current], in: nil, contentWorld: .defaultClient)
                    }
                    return
                }
                // Acknowledge our own edit before SwiftUI updates the representable;
                // an input event must not rebuild the canvas or restart a vault scan.
                source = replacement
                model.updateBufferText(bufferID, replacement)
                return
            }
            if action == "save" {
                Task { [weak view = message.webView] in
                    let saved = await model.saveBuffer(bufferID)
                    _ = try? await view?.callAsyncJavaScript("window.crowObsidian.saved(ok)", arguments: ["ok": saved], in: nil, contentWorld: .defaultClient)
                }
                return
            }
            if action == "createNote", let name = body["name"], kind == "base" {
                let relative = String(state.snapshot.buffers[index].path.dropFirst(state.snapshot.rootPath == "/" ? 1 : state.snapshot.rootPath.count + 1))
                Task {
                    do {
                        try TextFiles.validateName(name)
                        guard ["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) else {
                            throw CommandError("Choose a Markdown note name.")
                        }
                        let base = try await ObsidianFiles.resolve(relative, in: state)
                        guard model.current === state else { throw CommandError("Return to this workspace to create a note.") }
                        await model.createEntry(name: name, directory: false, in: (base as NSString).deletingLastPathComponent).value
                    } catch { model.report(error) }
                }
                return
            }
            if action == "markdown", let text = body["text"], text.utf8.count <= 512 * 1024, let id = body["id"] {
                Task { [weak view = message.webView] in
                    let html = await Task.detached(priority: .utility) { MarkdownPreview.body(text) }.value
                    _ = try? await view?.callAsyncJavaScript("window.crowObsidian.asset(id, value)", arguments: ["id": id, "value": ["html": html]], in: nil, contentWorld: .defaultClient)
                }
                return
            }
            guard let path = body["path"] else { return }
            if action == "property", let expected = body["expected"], let replacement = body["source"], let id = body["id"] {
                Task { [weak view = message.webView] in
                    var result: [String: Any] = ["ok": true]
                    do { try await ObsidianFiles.writeNote(path, expected: expected, replacement: replacement, in: state, model: model) }
                    catch { result = ["ok": false, "error": error.localizedDescription] }
                    _ = try? await view?.callAsyncJavaScript("window.crowObsidian.propertyResult(id, result)", arguments: ["id": id, "result": result], in: nil, contentWorld: .defaultClient)
                }
                return
            }
            if action == "asset", let id = body["id"], let view = message.webView {
                guard assets.count < 2000 else { return }
                let lane = nextAssetLane % assetLanes.count; nextAssetLane += 1
                let previous = assetLanes[lane]
                let request = Task { [weak view] in
                    await previous?.value
                    guard !Task.isCancelled else { return }
                    var result: [String: String]
                    do {
                        guard self.assetBytes < 24 * 1024 * 1024 else { throw CommandError("Canvas attachment preview limit reached (24 MB). Open the file to view it.") }
                        result = try await ObsidianFiles.asset(path, in: state)
                        try Task.checkCancellation()
                        self.assetBytes += result.values.reduce(0) { $0 + $1.utf8.count }
                    }
                    catch { result = ["error": error.localizedDescription] }
                    guard !Task.isCancelled else { return }
                    _ = try? await view?.callAsyncJavaScript("window.crowObsidian.asset(id, value)", arguments: ["id": id, "value": result], in: nil, contentWorld: .defaultClient)
                    self.assets.removeValue(forKey: id)
                }
                assets[id] = request; assetLanes[lane] = request
            } else if action == "openWiki" {
                model.openMarkdownLink(path, from: bufferID, allowWorkspaceLink: true)
            } else if action == "open" {
                if let url = URL(string: path), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    model.openMarkdownLink(path, from: bufferID)
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
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishEarly(error.localizedDescription) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finishEarly("Preview stopped. Refresh to try again or open Source.") }
        func stop() { task?.cancel(); watchdog?.cancel(); status.cancel = nil; assets.values.forEach { $0.cancel() }; assets.removeAll(); assetLanes = Array(repeating: nil, count: 4); nextAssetLane = 0; assetBytes = 0 }
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
