import CrowCore
import Foundation
import Observation

@MainActor @Observable
final class WorkspaceState: Identifiable {
    var snapshot: WorkspaceSnapshot
    var files: [FileEntry] = []
    var isLoading = false
    let explorer: FileExplorer
    var maximizedPaneID: UUID?
    let id: WorkspaceID
    @ObservationIgnored var remote: RemoteConnection?
    @ObservationIgnored var terminals: [UUID: TerminalSession] = [:]
    @ObservationIgnored var accessURL: URL?
    @ObservationIgnored var refreshGeneration = UUID()
    @ObservationIgnored var connectionTask: Task<Void, Never>?
    @ObservationIgnored var movingPaths: Set<String> = []
    #if os(macOS)
    @ObservationIgnored var systemSSH: SystemSSHSpec?
    #endif
    init(_ snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot; id = snapshot.workspace.id
        explorer = FileExplorer(rootPath: snapshot.rootPath)
    }
    func stopTerminals() {
        terminals.values.forEach { $0.stop() }
        terminals.removeAll()
    }
}

struct FileTreeRow: Identifiable {
    let entry: FileEntry
    let depth: Int
    var id: String { entry.path }
}

/// Lazy, per-vault tree. Directory IO is injected so local and SFTP trees behave alike.
@MainActor @Observable
final class FileExplorer {
    private(set) var rootPath: String
    private(set) var children: [String: [FileEntry]] = [:]
    private(set) var expanded: Set<String> = []
    var selectedPath: String?
    var searchVisible = false
    var query = "" { didSet { if query != oldValue { startSearch() } } }
    private(set) var results: [FileEntry] = []
    private(set) var isSearching = false
    private(set) var loading: Set<String> = []
    private(set) var errorMessage: String?
    private(set) var limitMessage: String?
    @ObservationIgnored var load: ((String) async throws -> [FileEntry])?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var searchRunning = false

    init(rootPath: String) { self.rootPath = rootPath }
    var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var rows: [FileTreeRow] {
        if searching { return results.map { FileTreeRow(entry: $0, depth: 0) } }
        func visit(_ path: String, depth: Int) -> [FileTreeRow] {
            (children[path] ?? []).flatMap { entry in
                [FileTreeRow(entry: entry, depth: depth)] +
                    (entry.isDirectory && expanded.contains(entry.path) ? visit(entry.path, depth: depth + 1) : [])
            }
        }
        return visit(rootPath, depth: 0)
    }
    var creationDirectory: String {
        guard let selectedPath,
              let entry = children.values.joined().first(where: { $0.path == selectedPath }) ?? results.first(where: { $0.path == selectedPath }) else { return rootPath }
        return entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent
    }
    func configure(rootPath: String, load: @escaping (String) async throws -> [FileEntry]) {
        if self.rootPath != rootPath {
            stop(); self.rootPath = rootPath; children = [:]; expanded = []; selectedPath = nil; results = []
        }
        self.load = load
    }
    func stop() {
        generation = UUID(); searchTask?.cancel()
        refreshRequested = false
        searchTask = nil; loading = []; isSearching = false; searchRunning = false
    }
    private func read(_ path: String) async throws -> [FileEntry] {
        guard let load else { return [] }
        let entries = try await load(path)
        try Task.checkCancellation()
        // Only immediate children are accepted. Do not follow remote symlinks or
        // malformed directory entries back into an ancestor during recursive scans.
        return entries.filter {
            !$0.name.hasPrefix(".") && !$0.name.contains("/") &&
                $0.path == (path as NSString).appendingPathComponent($0.name)
        }.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func refresh() async {
        guard load != nil else { return }
        guard !refreshing else { refreshRequested = true; return }
        refreshing = true
        if children[rootPath] == nil { loading.insert(rootPath) }
        defer {
            refreshing = false; loading.remove(rootPath)
            if refreshRequested {
                refreshRequested = false
                Task { await self.refresh() }
            }
        }
        let token = generation
        do {
            var updated: [String: [FileEntry]] = [:]
            var queue = [rootPath], index = 0
            var failure: String?
            while index < queue.count {
                let path = queue[index]; index += 1
                do {
                    let entries = try await read(path)
                    guard token == generation else { return }
                    updated[path] = entries
                    queue += entries.filter { $0.isDirectory && expanded.contains($0.path) }.map(\.path)
                } catch is CancellationError { return }
                catch {
                    guard token == generation else { return }
                    if path == rootPath { throw error }
                    failure = "\(relativePath(path)): \(error.localizedDescription)"
                }
            }
            // Keep collapsed caches for instant re-expansion, but remove deleted branches.
            for (path, entries) in updated {
                let valid = Set(entries.map(\.path))
                for old in children[path] ?? [] where !valid.contains(old.path) {
                    children = children.filter { $0.key != old.path && !$0.key.hasPrefix(old.path + "/") }
                    expanded = expanded.filter { $0 != old.path && !$0.hasPrefix(old.path + "/") }
                    if selectedPath == old.path || selectedPath?.hasPrefix(old.path + "/") == true { selectedPath = nil }
                }
                if children[path] != entries { children[path] = entries }
            }
            errorMessage = failure
        } catch is CancellationError {} catch { if token == generation { errorMessage = error.localizedDescription } }
    }
    func toggle(_ entry: FileEntry) async {
        guard entry.isDirectory else { return }
        if expanded.contains(entry.path) { expanded.remove(entry.path); return }
        expanded.insert(entry.path)
        let token = generation
        loading.insert(entry.path)
        defer { loading.remove(entry.path) }
        do {
            let entries = try await read(entry.path)
            guard token == generation else { return }
            children[entry.path] = entries; errorMessage = nil
        } catch is CancellationError {} catch { if token == generation { errorMessage = error.localizedDescription } }
    }
    func collapseAll() {
        expanded = []
    }
    func reveal(_ entry: FileEntry) async {
        let token = generation
        var path = entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent
        var ancestors: [String] = []
        while path != rootPath && path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") {
            ancestors.append(path)
            path = (path as NSString).deletingLastPathComponent
        }
        for path in ancestors.reversed() where !expanded.contains(path) {
            guard token == generation, !Task.isCancelled else { return }
            await toggle(FileEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: true))
        }
    }
    func didRename(from oldPath: String, to newPath: String) {
        stop() // Ignore reads that started before the rename.
        let oldParent = (oldPath as NSString).deletingLastPathComponent
        let newParent = (newPath as NSString).deletingLastPathComponent
        let movedEntry = children[oldParent]?.first { $0.path == oldPath }
        func relocated(_ path: String) -> String {
            path == oldPath || path.hasPrefix(oldPath + "/") ? newPath + path.dropFirst(oldPath.count) : path
        }
        expanded = Set(expanded.map(relocated))
        if let selectedPath { self.selectedPath = relocated(selectedPath) }
        children = Dictionary(children.map { path, entries in
            (relocated(path), entries.filter { oldParent == newParent || path != oldParent || $0.path != oldPath }.map { entry in
                let path = relocated(entry.path)
                return FileEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: entry.isDirectory)
            })
        }, uniquingKeysWith: { _, new in new })
        if oldParent != newParent, let movedEntry, children[newParent] != nil {
            children[newParent]?.append(.init(name: (newPath as NSString).lastPathComponent,
                path: newPath, isDirectory: movedEntry.isDirectory))
        }
        results = results.map { entry in
            let path = relocated(entry.path)
            return .init(name: (path as NSString).lastPathComponent, path: path, isDirectory: entry.isDirectory)
        }
    }
    func refreshSearch() {
        if searching && !searchRunning { startSearch(clearResults: false) }
    }
    private func startSearch(clearResults: Bool = true) {
        searchTask?.cancel()
        if clearResults { results = []; limitMessage = nil }
        guard searching else { isSearching = false; searchRunning = false; return }
        isSearching = clearResults; searchRunning = true
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines), token = generation
        searchTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            var matches: [FileEntry] = []
            await scan { _, entries in
                matches += entries.filter { self.relativePath($0.path).localizedStandardContains(phrase) }
                if clearResults { self.results = matches }
            }
            if !Task.isCancelled, token == generation { results = matches; isSearching = false; searchRunning = false }
        }
    }
    private func scan(visit: (String, [FileEntry]) -> Void) async {
        let token = generation
        var queue = [(rootPath, 0)], index = 0, count = 0
        errorMessage = nil
        while index < queue.count {
            guard !Task.isCancelled, token == generation else { return }
            if index >= 2_000 || count >= 20_000 {
                limitMessage = "Showing the first 20,000 entries / 2,000 folders. Narrow the vault to search a larger project."
                return
            }
            let (path, depth) = queue[index]; index += 1
            do {
                let all = try await read(path)
                guard token == generation, !Task.isCancelled else { return }
                let entries = Array(all.prefix(20_000 - count))
                count += entries.count; visit(path, entries)
                if entries.count < all.count { limitMessage = "Showing the first 20,000 entries. Open a smaller folder to search further."; return }
                if depth < 64 { queue += entries.filter(\.isDirectory).map { ($0.path, depth + 1) } }
                else if entries.contains(where: \.isDirectory) { limitMessage = "Folders deeper than 64 levels are not scanned." }
            } catch is CancellationError { return }
            catch { if token == generation, !Task.isCancelled { errorMessage = "\(relativePath(path)): \(error.localizedDescription)" } }
        }
    }
    func relativePath(_ path: String) -> String {
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
    nonisolated static func localEntries(_ path: String) throws -> [FileEntry] {
        try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).map { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return FileEntry(name: url.lastPathComponent, path: (path as NSString).appendingPathComponent(url.lastPathComponent),
                    isDirectory: values.isDirectory == true && values.isSymbolicLink != true)
            }
    }
}
