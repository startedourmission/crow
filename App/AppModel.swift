import CrowCore
import Foundation
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct WorkspaceTabDrag: Codable, Equatable {
    let workspaceID: WorkspaceID
    let paneID: UUID
    let tab: WorkspaceTab
}

struct ExplorerFileDrag: Codable, Equatable {
    let workspaceID: WorkspaceID
    let path: String
    let isDirectory: Bool
    var name: String { (path as NSString).lastPathComponent }
    var entry: FileEntry { FileEntry(name: name, path: path, isDirectory: isDirectory) }
}

@MainActor @Observable
final class AppModel {
    var hosts: [SSHHost] = []
    var states: [WorkspaceState] = []
    var selectedWorkspaceID: WorkspaceID
    var collapsedWorkspaceIDs: Set<WorkspaceID> = []
    var collapsedWorkspaceHosts: Set<String> = []
    var tmuxExpansionStates: [String: TmuxExpansionState] = [:]
    var workspaceSearchVisible = false
    var workspaceSearch = ""
    var workspaceTmuxVisible = true
    var settings = EditorSettings() { didSet { schedulePersist() } }
    var sidebarPane: SidebarPane = .files
    var inspectorVisible = true
    var editorLocationBufferID: BufferID?
    var editorLocationRequest: EditorLocationRequest?
    var documentFindRequest = 0
    // An editing preference, not ephemeral state owned by the selected file view.
    var markdownPreviewEnabled: Bool {
        get { settings.effectiveMarkdownPreviewEnabled }
        set { settings.markdownPreviewEnabled = newValue }
    }
    var fileSearchFocusRequest = 0

    func focusFileSearch() {
        guard hasWorkspace else { return }
        sidebarPane = .files; sidebarVisible = true
        current.explorer.searchVisible = true
        fileSearchFocusRequest += 1
    }
    func findInCurrentDocument() {
        guard let buffer = inspectedBuffer, !buffer.isImage else { return }
        documentFindRequest += 1
    }
    func adjustFontSize(by amount: Double) {
        if case .terminal = current.snapshot.layout?.activePane?.selected {
            settings.terminalFontSize = min(32, max(11, settings.terminalFontSize + amount))
        } else {
            settings.fontSize = min(32, max(11, settings.fontSize + amount))
        }
    }
    func selectNumberedTab(_ number: Int) {
        guard let pane = current.snapshot.layout?.activePane, number > 0, number <= pane.tabs.count else { return }
        selectTab(pane.tabs[number - 1], in: pane.id)
    }
    var compactSurface: CompactSurface = .editor {
        didSet {
            if compactSurface == .hosts { sidebarPane = .workspaces }
            if compactSurface == .files { sidebarPane = .files }
        }
    }
    var statusMessage = "Ready"
    var errorMessage: String?
    var closeRequest: BufferID?
    var terminalCloseRequest: UUID?
    var draggedTab: WorkspaceTabDrag?
    var draggedFile: ExplorerFileDrag?
    var workspaceRemovalRequest: WorkspaceID?
    var conflictRequest: BufferID?
    var externallyChangedBuffers: Set<BufferID> = []
    var externalFileErrors: [BufferID: String] = [:]
    var imagePreviews: [BufferID: ImagePreview] = [:]
    var deleteRequest: FileEntry?
    var deleteWorkspaceID: WorkspaceID?
    var hostKeyChallenge: HostKeyChallenge?
    var folderImporterVisible = false
    #if os(macOS)
    @ObservationIgnored private(set) var folderSelectionPanel: NSOpenPanel?
    func presentFolderPicker() {
        if let panel = folderSelectionPanel { panel.makeKeyAndOrderFront(nil); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "Open"; panel.title = "Open Local Folder"
        let pathModel = FolderPathCompletion(panel: panel, initialDirectory: current.snapshot.workspace.isRemote ? nil : current.snapshot.rootPath)
        let accessory = NSHostingView(rootView: FolderPathAccessory(completion: pathModel))
        accessory.frame = NSRect(x: 0, y: 0, width: 520, height: 208)
        panel.accessoryView = accessory; panel.isAccessoryViewDisclosed = true
        folderSelectionPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self, weak panel] response in
            guard let self else { return }
            let url = panel?.url
            self.folderSelectionPanel = nil; self.folderImporterVisible = false
            if response == .OK, let url { self.openFolder(url) }
        }
        panel.makeKeyAndOrderFront(nil)
    }
    #endif
    var hostEditorVisible = false
    var editingHost: SSHHost?
    var pendingHostEditor = false
    var pendingHostConnection: SSHHost?
    let gitAccounts = GitAccountStore()
    var settingsVisible = false
    var screenRequest: ScreenRequest?
    #if os(iOS)
    @ObservationIgnored private var backgroundSSH = Set<WorkspaceID>()
    @ObservationIgnored private var backgroundTime: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var backgroundKeepalive: Task<Void, Never>?
    @ObservationIgnored private var foregroundChecks: [WorkspaceID: Task<Void, Never>] = [:]
    #endif
    var sshKeysVisible = false
    var sshCommandVisible = false
    var credentialRequest: SSHHost?
    var pendingCredentialRequest: SSHHost?
    #if os(macOS)
    var reverseSSHConnections: [HostID: ReverseSSHSession] = [:]
    @ObservationIgnored var reverseSSHAccess = ReverseSSHAccessSettings.shared
    @ObservationIgnored var reverseSSHPasteboard = NSPasteboard.general
    @ObservationIgnored private var sshBridge: SystemSSHBridge?
    #endif
    let windowID: UUID
    @ObservationIgnored var onPersist: ((SessionSnapshot) -> Void)?
    let vaultURL: URL
    let sessionURL: URL
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var saving: Set<BufferID> = []
    @ObservationIgnored private var refreshingBuffers: Set<BufferID> = []
    @ObservationIgnored private var observedFileRevisions: [BufferID: ObservedFileRevision] = [:]
    @ObservationIgnored private var fileRefreshPaused = false
    @ObservationIgnored private var persistenceAvailable = true
    // A presentation-only fallback: never persisted or used for file operations.
    private let emptyState = WorkspaceState(.init(
        workspace: Workspace(name: "No Folder", kind: .local, connection: .local), rootPath: ""))

    init(vaultURL: URL? = nil, sessionURL: URL? = nil, windowID: UUID = UUID()) {
        self.windowID = windowID
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var defaultVault = documents.appendingPathComponent("CrowVault", isDirectory: true)
        #if os(macOS)
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/dev.chajinwoo.crow/Data/Documents/CrowVault", isDirectory: true)
        if !FileManager.default.fileExists(atPath: defaultVault.path), FileManager.default.fileExists(atPath: legacy.path) {
            defaultVault = legacy
        }
        #endif
        let requestedVault = vaultURL ?? defaultVault
        self.vaultURL = requestedVault.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(requestedVault.lastPathComponent, isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.sessionURL = sessionURL ?? (vaultURL == nil ? support.appendingPathComponent("Crow/session-v1.json")
            : self.vaultURL.appendingPathComponent(".crow-session.json"))
        let local = Workspace(name: "Crow", kind: .local, connection: .local)
        selectedWorkspaceID = local.id
        var restoredSession = false
        do {
            try FileManager.default.createDirectory(at: self.vaultURL, withIntermediateDirectories: true)
            let readme = self.vaultURL.appendingPathComponent("README.md")
            if !FileManager.default.fileExists(atPath: readme.path) {
                try Data("# Crow\n\nOpen a folder to work on your own files, or add an SSH host.\n".utf8)
                    .write(to: readme, options: .withoutOverwriting)
            }
            if FileManager.default.fileExists(atPath: self.sessionURL.path) {
                let saved = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: self.sessionURL))
                guard saved.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                restoredSession = true
                hosts = saved.hosts; settings = saved.settings
                states = saved.workspaces.map { snapshot in
                    var restored = snapshot
                    if restored.workspace.isRemote {
                        restored.workspace.connection = .disconnected
                        if let host = saved.hosts.first(where: { $0.id == restored.workspace.hostID }),
                           restored.workspace.name == host.name, restored.rootPath.hasPrefix("/") {
                            restored.workspace.name = (restored.rootPath as NSString).lastPathComponent
                        }
                    }
                    else if restored.bookmark == nil {
                        // iOS can change the app container UUID after an update.
                        // Built-in vault paths must follow the current container.
                        restored.relocateRoot(to: self.vaultURL.path)
                        if restored.workspace.name == "Vault" { restored.workspace.name = "Crow" }
                    }
                    return WorkspaceState(restored)
                }
                let labBuffers = states.filter { $0.snapshot.workspace.kind == .imeLab }.flatMap(\.snapshot.buffers)
                states.removeAll { $0.snapshot.workspace.kind == .imeLab }
                if !labBuffers.isEmpty {
                    if !states.contains(where: { !$0.snapshot.workspace.isRemote }) {
                        states.append(WorkspaceState(.init(workspace: local, rootPath: self.vaultURL.path)))
                    }
                    let destination = states.first { !$0.snapshot.workspace.isRemote }!
                    for buffer in labBuffers where !destination.snapshot.buffers.contains(where: { $0.id == buffer.id }) {
                        destination.snapshot.buffers.append(buffer)
                    }
                }
                selectedWorkspaceID = states.contains(where: { $0.id == saved.selectedWorkspaceID }) ? saved.selectedWorkspaceID : (states.first?.id ?? emptyState.id)
                for state in states { restoreAccess(state) }
            }
        } catch {
            errorMessage = "Could not restore session: \(error.localizedDescription)"
            if FileManager.default.fileExists(atPath: self.sessionURL.path) {
                let backup = self.sessionURL.appendingPathExtension("unreadable-" + UUID().uuidString)
                do {
                    try FileManager.default.copyItem(at: self.sessionURL, to: backup)
                    errorMessage! += "\nThe original session is preserved at \(backup.path)."
                } catch { persistenceAvailable = false }
            }
        }
        if states.isEmpty && !restoredSession {
            states = [WorkspaceState(.init(workspace: local, rootPath: self.vaultURL.path))]
            let readme = self.vaultURL.appendingPathComponent("README.md")
            if let text = try? TextFiles.read(readme) { addBuffer(path: readme.path, text: text, to: states[0]) }
        }
        for state in states { ensureLayout(state) }
        refreshFiles()
    }

    var hasWorkspace: Bool { !states.isEmpty }
    var current: WorkspaceState { states.first(where: { $0.id == selectedWorkspaceID }) ?? states.first ?? emptyState }
    var workspaces: [Workspace] { states.map(\.snapshot.workspace) }
    var localWorkspaces: [Workspace] { workspaces.filter { $0.kind == .local } }
    var selectedWorkspace: Workspace { current.snapshot.workspace }
    var workspaceTitle: String { selectedWorkspace.name }
    var files: [FileEntry] { current.files }
    var buffers: [OpenBuffer] { current.snapshot.buffers }
    var selectedBufferID: BufferID? {
        get { current.snapshot.selectedBufferID }
        set {
            current.snapshot.selectedBufferID = newValue
            if let newValue { current.snapshot.layout?.select(.file(newValue)) }
            schedulePersist()
        }
    }
    var selectedBuffer: OpenBuffer? { buffers.first { $0.id == selectedBufferID } }
    var inspectedBuffer: OpenBuffer? {
        guard let layout = current.snapshot.layout,
              let pane = layout.panes.first(where: { $0.id == layout.activePaneID }) else { return selectedBuffer }
        guard case .file(let id) = pane.selected else { return nil }
        return buffers.first { $0.id == id }
    }
    func navigateToOutline(_ item: OutlineItem, in buffer: OpenBuffer) {
        guard inspectedBuffer?.id == buffer.id else { return }
        editorLocationBufferID = buffer.id
        editorLocationRequest = EditorLocationRequest(offset: item.offset, headingIndex: item.headingIndex)
    }
    var sidebarVisible: Bool {
        get { settings.sidebarVisible }
        set { settings.sidebarVisible = newValue }
    }
    var terminalVisible: Bool {
        get { settings.terminalVisible }
        set { settings.terminalVisible = newValue }
    }
    var showHiddenFiles: Bool {
        get { settings.showHiddenFiles ?? false }
        set { settings.showHiddenFiles = newValue; refreshFiles() }
    }
    var hasUnsavedChanges: Bool { states.contains { $0.snapshot.buffers.contains(where: \.isDirty) } }

    func selectWorkspace(_ id: WorkspaceID, showFiles: Bool = true) {
        guard states.contains(where: { $0.id == id }) else { return }
        selectedWorkspaceID = id
        current.snapshot.lastOpenedAt = Date()
        if showFiles {
            sidebarPane = .files
            if compactSurface == .hosts { compactSurface = .files }
        }
        ensureLayout(current); refreshFiles()
        statusMessage = workspaceTitle; schedulePersist()
    }

    func ensureLayout(_ state: WorkspaceState) {
        guard state.snapshot.layout == nil else { return }
        state.snapshot.layout = WorkspaceLayout(files: state.snapshot.buffers.map(\.id),
            selectedFile: state.snapshot.selectedBufferID, terminals: state.snapshot.terminalIDs,
            selectedTerminal: state.snapshot.selectedTerminalID, terminalFraction: settings.terminalFraction)
    }
    func activatePane(_ paneID: UUID) {
        guard let pane = current.snapshot.layout?.panes.first(where: { $0.id == paneID }) else { return }
        current.snapshot.layout?.activePaneID = paneID
        if let tab = pane.selected { selectTab(tab, in: paneID) }
    }
    func selectTab(_ tab: WorkspaceTab, in paneID: UUID) {
        guard current.snapshot.layout?.panes.contains(where: { $0.id == paneID && $0.tabs.contains(tab) }) == true else { return }
        current.snapshot.layout?.select(tab, in: paneID)
        switch tab {
        case .file(let id): current.snapshot.selectedBufferID = id
        case .terminal(let id): current.snapshot.selectedTerminalID = id
        case .start, .browser: break
        }
        schedulePersist()
    }
    func closeTab(_ tab: WorkspaceTab, in paneID: UUID) {
        guard current.snapshot.layout?.panes.contains(where: { $0.id == paneID && $0.tabs.contains(tab) }) == true else { return }
        switch tab {
        case .file(let id):
            if (current.snapshot.layout?.allTabs.filter { $0 == tab }.count ?? 0) > 1 {
                current.snapshot.layout?.remove(tab, from: paneID); schedulePersist()
            } else { closeBuffer(id) }
        case .terminal(let id): requestTerminalClose(id)
        case .browser(let id):
            current.snapshot.layout?.remove(tab, from: paneID)
            if current.snapshot.layout?.allTabs.contains(tab) != true {
                current.browsers.removeValue(forKey: id)?.close()
                current.snapshot.browserAddresses.removeValue(forKey: id)
            }
            schedulePersist()
        case .start:
            current.snapshot.layout?.remove(tab, from: paneID); schedulePersist()
        }
    }
    @discardableResult func moveTab(_ drag: WorkspaceTabDrag, to paneID: UUID,
        placement: PanePlacement, before: WorkspaceTab? = nil) -> Bool {
        guard drag.workspaceID == selectedWorkspaceID else { return false }
        let moved = current.snapshot.layout?.move(drag.tab, from: drag.paneID, to: paneID,
            placement: placement, before: before) ?? false
        if moved {
            current.maximizedPaneID = nil
            if let pane = current.snapshot.layout?.activePane, let tab = pane.selected { selectTab(tab, in: pane.id) }
            schedulePersist()
        }
        return moved
    }
    func splitTab(_ tab: WorkspaceTab, in paneID: UUID, placement: PanePlacement) {
        guard current.snapshot.layout?.panes.contains(where: { $0.id == paneID && $0.tabs.contains(tab) }) == true else { return }
        if case .terminal = tab {
            let id = UUID()
            current.snapshot.terminalIDs.append(id); current.snapshot.selectedTerminalID = id
            current.snapshot.layout?.open(.terminal(id), in: paneID)
            _ = current.snapshot.layout?.move(.terminal(id), from: paneID, to: paneID, placement: placement)
        } else if case .browser(let id) = tab {
            let copy = UUID()
            current.snapshot.browserAddresses[copy] = current.snapshot.browserAddresses[id] ?? ""
            current.snapshot.layout?.open(.browser(copy), in: paneID)
            _ = current.snapshot.layout?.move(.browser(copy), from: paneID, to: paneID, placement: placement)
        } else if case .start = tab {
            let newTab = WorkspaceTab.start(UUID())
            current.snapshot.layout?.open(newTab, in: paneID)
            _ = current.snapshot.layout?.move(newTab, from: paneID, to: paneID, placement: placement)
        } else {
            _ = current.snapshot.layout?.move(tab, from: paneID, to: paneID, placement: placement, copy: true)
        }
        current.maximizedPaneID = nil; schedulePersist()
        if let pane = current.snapshot.layout?.activePane, let tab = pane.selected { selectTab(tab, in: pane.id) }
    }
    func resizePaneSplit(_ id: UUID, fraction: Double) {
        let resized = current.snapshot.layout?.root?.resizing(id, fraction: fraction)
        current.snapshot.layout?.root = resized
        schedulePersist()
    }
    func newTerminal(inWorkspace id: WorkspaceID) {
        guard states.contains(where: { $0.id == id }) else { return }
        activateWorkspace(id); newTerminal(); compactSurface = .terminal
    }
    #if os(macOS)
    func openWorkspaceInFinder(_ id: WorkspaceID) {
        guard let state = states.first(where: { $0.id == id }), !state.snapshot.workspace.isRemote else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: state.snapshot.rootPath, isDirectory: true))
    }
    #endif

    func requestWorkspaceRemoval(_ id: WorkspaceID) {
        guard states.contains(where: { $0.id == id }) else { return }
        workspaceRemovalRequest = id
    }

    @discardableResult func removeWorkspace(_ id: WorkspaceID, discardChanges: Bool = false) -> Bool {
        guard let index = states.firstIndex(where: { $0.id == id }) else { return false }
        let state = states[index]
        guard discardChanges || !state.snapshot.buffers.contains(where: \.isDirty) else {
            workspaceRemovalRequest = id
            return false
        }
        state.browsers.values.forEach { $0.close() }; state.browsers.removeAll()
        disconnect(state)
        state.refreshGeneration = UUID()
        state.accessURL?.stopAccessingSecurityScopedResource(); state.accessURL = nil
        for buffer in state.snapshot.buffers {
            imagePreviews.removeValue(forKey: buffer.id)
            observedFileRevisions.removeValue(forKey: buffer.id)
            externalFileErrors.removeValue(forKey: buffer.id)
            externallyChangedBuffers.remove(buffer.id)
        }
        states.remove(at: index)
        if selectedWorkspaceID == id {
            selectedWorkspaceID = states.isEmpty ? emptyState.id : states[min(index, states.count - 1)].id
            refreshFiles()
        }
        if workspaceRemovalRequest == id { workspaceRemovalRequest = nil }
        statusMessage = "Removed \(state.snapshot.workspace.name) from the list. Files were not deleted."
        persist()
        return true
    }

    @discardableResult func saveAndRemoveWorkspace(_ id: WorkspaceID) async -> Bool {
        guard let state = states.first(where: { $0.id == id }) else { return false }
        for buffer in state.snapshot.buffers.filter(\.isDirty) {
            guard await saveBuffer(buffer.id) else { return false }
        }
        // Recheck all buffers: edits can arrive while a remote save is pending.
        return removeWorkspace(id)
    }

    func openFolder(_ url: URL) {
        // File-provider URLs must be scoped before even reading their metadata.
        // Keep the exact URL supplied by Files alive for the workspace lifetime.
        let accessed = url.startAccessingSecurityScopedResource()
        var retainedAccess = false
        defer { if accessed && !retainedAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            guard url.isFileURL, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw NSError(domain: "Crow.Folder", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Choose a folder to open as a workspace."])
            }
            let path = url.resolvingSymlinksInPath().path
            // iOS bookmarks retain the document picker's grant. macOS uses
            // ordinary bookmarks because its local-shell app is unsandboxed.
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            if let existing = states.first(where: { !$0.snapshot.workspace.isRemote && $0.snapshot.rootPath == path }) {
                // Picking the folder again renews access without losing open edits.
                if accessed {
                    let previousAccess = existing.accessURL
                    existing.accessURL = url; retainedAccess = true
                    previousAccess?.stopAccessingSecurityScopedResource()
                }
                if existing.snapshot.bookmark != nil || path != vaultURL.path { existing.snapshot.bookmark = bookmark }
                sidebarPane = .files; sidebarVisible = true
                selectWorkspace(existing.id); return
            }
            let state = WorkspaceState(.init(workspace: Workspace(name: url.lastPathComponent, kind: .local, connection: .local),
                rootPath: path, bookmark: bookmark))
            if accessed { state.accessURL = url; retainedAccess = true }
            states.append(state); sidebarPane = .files; sidebarVisible = true
            selectWorkspace(state.id)
        } catch { report(error) }
    }

    private func restoreAccess(_ state: WorkspaceState) {
        guard let bookmark = state.snapshot.bookmark else { return }
        do {
            var stale = false
            var options: URL.BookmarkResolutionOptions = []
            #if os(macOS)
            options = .withoutUI
            #endif
            let url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            if url.startAccessingSecurityScopedResource() { state.accessURL = url }
            state.snapshot.relocateRoot(to: url.resolvingSymlinksInPath().path)
            #if os(macOS)
            // Upgrade saved app-scoped bookmarks to ordinary macOS bookmarks.
            state.snapshot.bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            #else
            if stale {
                state.snapshot.bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            #endif
        } catch {
            #if os(macOS)
            // Legacy scoped bookmarks can outlive a development signing identity.
            // Recover only the previously saved local directory, if still readable.
            let saved = URL(fileURLWithPath: state.snapshot.rootPath)
            if !state.snapshot.workspace.isRemote,
               (try? saved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               FileManager.default.isReadableFile(atPath: saved.path),
               let renewed = try? saved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                state.snapshot.bookmark = renewed
                return
            }
            #endif
            report(error)
        }
    }

    func navigate(to path: String) {
        guard hasWorkspace else { return }
        current.snapshot.directoryPath = selectedWorkspace.isRemote ? path : URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        refreshFiles(); schedulePersist()
    }
    func navigateUp() {
        guard current.snapshot.directoryPath != current.snapshot.rootPath else { return }
        navigate(to: (current.snapshot.directoryPath as NSString).deletingLastPathComponent)
    }

    func refreshFiles() {
        guard hasWorkspace else { return }
        let state = current, path = current.contextDirectoryPath
        state.explorer.showHiddenFiles = showHiddenFiles
        state.explorer.configure(rootPath: state.contextRootPath) { [weak self, weak state] path in
            guard let self, let state else { throw CancellationError() }
            if state.snapshot.workspace.isRemote {
                let remote = try self.fileConnection(in: state)
                return try await remote.list(path)
            }
            return try await Task.detached { try FileExplorer.localEntries(path) }.value
        }
        state.explorer.readContent = { [weak self, weak state] path in
            guard let self, let state else { throw CancellationError() }
            if let buffer = state.snapshot.buffers.first(where: { $0.path == path }) {
                guard buffer.text.utf8.count <= FileExplorer.contentSizeLimit else { throw FileFailure.tooLarge }
                return buffer.text
            }
            if state.snapshot.workspace.isRemote {
                let remote = try self.fileConnection(in: state)
                return try await remote.read(path, maximumSize: FileExplorer.contentSizeLimit)
            }
            return try await Task.detached {
                let url = URL(fileURLWithPath: path)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw FileFailure.unsupportedText }
                return try TextFiles.read(url, maximumSize: FileExplorer.contentSizeLimit)
            }.value
        }
        Task { await state.explorer.refresh(); state.explorer.refreshSearch() }
        let generation = UUID(); state.refreshGeneration = generation
        if !state.snapshot.workspace.isRemote {
            do {
                state.files = try FileExplorer.localEntries(path)
                    .filter { showHiddenFiles || !$0.isHidden }
                    .sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            } catch { state.files = []; report(error) }
            return
        }
        guard let remote = state.remote else { state.files = []; return }
        state.isLoading = true
        Task {
            defer { if state.refreshGeneration == generation { state.isLoading = false } }
            do {
                let entries = try await remote.list(path)
                if state.refreshGeneration == generation { state.files = entries.filter { showHiddenFiles || !$0.isHidden } }
            } catch {
                guard state.refreshGeneration == generation, selectedWorkspaceID == state.id else { return }
                report(error)
            }
        }
    }

    /// Reopen only the SFTP channel when it has exited; keep the user's terminal session alive.
    private func fileConnection(in state: WorkspaceState) throws -> RemoteConnection {
        if let remote = state.remote, remote.isConnected { return remote }
        #if os(macOS)
        if let spec = state.systemSSH, FileManager.default.fileExists(atPath: spec.socket),
           state.snapshot.workspace.connection != .disconnected {
            let remote = RemoteConnection()
            try remote.attach(spec); state.remote = remote
            return remote
        }
        #endif
        throw FileFailure.disconnected
    }

    func remoteDirectory(in id: WorkspaceID, at path: String) async throws -> (path: String, folders: [FileEntry]) {
        guard let state = states.first(where: { $0.id == id }), state.snapshot.workspace.isRemote else { throw FileFailure.disconnected }
        let remote = try fileConnection(in: state)
        let resolved = try await remote.realPath(path.isEmpty ? "~" : path)
        let entries = try await remote.list(resolved)
        try Task.checkCancellation()
        guard states.contains(where: { $0 === state }), state.remote === remote else { throw CancellationError() }
        return (resolved, entries.filter { $0.isDirectory && $0.name != "." && $0.name != ".." })
    }

    func remoteTerminals(in id: WorkspaceID) -> [TerminalSession] {
        guard let state = states.first(where: { $0.id == id }), state.snapshot.workspace.isRemote else { return [] }
        return states.filter { $0.snapshot.workspace.hostID == state.snapshot.workspace.hostID }
            .flatMap { workspace in workspace.snapshot.terminalIDs.compactMap { workspace.terminals[$0] } }.filter(\.running)
    }

    @discardableResult func openRemoteWorkspace(_ path: String, from id: WorkspaceID) async throws -> WorkspaceID {
        let directory = try await remoteDirectory(in: id, at: path)
        guard let source = states.first(where: { $0.id == id }),
              let hostID = source.snapshot.workspace.hostID else { throw FileFailure.disconnected }
        let state: WorkspaceState
        if let existing = states.first(where: { $0.snapshot.workspace.hostID == hostID && $0.snapshot.rootPath == directory.path }) {
            state = existing
        } else {
            state = WorkspaceState(.init(workspace: Workspace(name: workspaceFolderName(directory.path),
                kind: .remote(hostID: hostID, path: directory.path), connection: .connected), rootPath: directory.path))
            states.append(state)
        }
        shareConnection(from: source, to: state)
        activateWorkspace(state.id)
        refreshFiles()
        await state.explorer.refresh()
        schedulePersist()
        return state.id
    }

    func retryRemoteFiles() {
        let state = current
        Task {
            do { _ = try await remoteDirectory(in: state.id, at: state.snapshot.rootPath); refreshFiles(); await state.explorer.refresh() }
            catch { report(error) }
        }
    }

    func openFile(_ entry: FileEntry) {
        if entry.isDirectory { navigate(to: entry.path); return }
        let state = current
        if let existing = state.snapshot.buffers.first(where: { $0.path == entry.path }) {
            state.snapshot.selectedBufferID = existing.id
            ensureLayout(state); state.snapshot.layout?.open(.file(existing.id))
            state.maximizedPaneID = nil; compactSurface = .editor; schedulePersist(); return
        }
        if ImagePreview.supports(entry.path) {
            addBuffer(path: entry.path, text: "", to: state, image: true)
        } else if !state.snapshot.workspace.isRemote {
            do { addBuffer(path: entry.path, text: try TextFiles.read(URL(fileURLWithPath: entry.path)), to: state) }
            catch { report(error) }
        } else {
            Task {
                do {
                    guard let remote = state.remote else { throw FileFailure.disconnected }
                    let text = try await remote.read(entry.path)
                    addBuffer(path: entry.path, text: text, to: state)
                } catch { report(error) }
            }
        }
        compactSurface = .editor
    }

    private func addBuffer(path: String, text: String, to state: WorkspaceState, image: Bool = false) {
        if let existing = state.snapshot.buffers.first(where: { $0.path == path }) {
            state.snapshot.selectedBufferID = existing.id; return
        }
        var buffer = OpenBuffer(title: (path as NSString).lastPathComponent, path: path, text: text,
            language: LanguageMode.infer(filename: path), isRemote: state.snapshot.workspace.isRemote)
        buffer.contentKind = image ? .image : .text
        buffer.savedText = text
        state.snapshot.buffers.append(buffer); state.snapshot.selectedBufferID = buffer.id
        ensureLayout(state); state.snapshot.layout?.open(.file(buffer.id)); state.maximizedPaneID = nil
        schedulePersist()
    }

    func updateBufferText(_ id: BufferID, _ text: String) {
        guard let (state, index) = locate(id), !state.snapshot.buffers[index].isImage else { return }
        let wasDirty = state.snapshot.buffers[index].isDirty
        state.snapshot.buffers[index].text = text
        state.snapshot.buffers[index].isDirty = text != state.snapshot.buffers[index].savedText
        if wasDirty && !state.snapshot.buffers[index].isDirty { observedFileRevisions.removeValue(forKey: id) }
        schedulePersist()
    }
    func saveSelectedBuffer() { if let id = selectedBufferID { Task { _ = await saveBuffer(id) } } }

    /// Runs only for mounted editors, including split panes. Rechecks edits after each asynchronous read.
    func observeBuffer(_ id: BufferID) async {
        while !Task.isCancelled {
            await refreshBufferFromSource(id)
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
        }
    }

    func refreshBufferFromSource(_ id: BufferID, discardChanges: Bool = false, force: Bool = false) async {
        guard !fileRefreshPaused, !refreshingBuffers.contains(id), !saving.contains(id), let (state, index) = locate(id) else { return }
        let buffer = state.snapshot.buffers[index]
        guard !state.movingPaths.contains(where: { buffer.path == $0 || buffer.path.hasPrefix($0 + "/") }) else { return }
        let connection = state.remote
        if buffer.isRemote && connection?.isConnected != true { return }
        refreshingBuffers.insert(id); defer { refreshingBuffers.remove(id) }
        do {
            let revision: FileRevision
            if let connection, buffer.isRemote { revision = try await connection.revision(buffer.path) }
            else { revision = try await Task.detached { try FileRevision.local(buffer.path) }.value }
            let previous = observedFileRevisions[id]
            // SFTP timestamps have second precision. Verify a newly observed revision on the next
            // tick as well; occasional content checks also handle tools that preserve timestamps.
            let contentInterval: TimeInterval = (revision.size ?? 0) > 262_144 ? 30 : 5
            if !force, !discardChanges, let previous, previous.path == buffer.path, previous.revision == revision,
               !previous.verifyAgain, Date().timeIntervalSince(previous.checkedAt) < contentInterval { return }
            if buffer.isImage {
                let preview: ImagePreview
                let after: FileRevision
                if let connection, buffer.isRemote {
                    let data: Data
                    do { data = try await connection.readData(buffer.path, maximumSize: ImagePreview.sizeLimit) }
                    catch FileFailure.tooLarge { throw ImagePreview.Failure.tooLarge }
                    preview = try await Task.detached(priority: .utility) { try ImagePreview.decode(data) }.value
                    after = try await connection.revision(buffer.path)
                } else {
                    (preview, after) = try await Task.detached(priority: .utility) {
                        (try ImagePreview.read(buffer.path), try FileRevision.local(buffer.path))
                    }.value
                }
                guard !Task.isCancelled, !fileRefreshPaused, after == revision,
                      let (currentState, currentIndex) = locate(id), currentState === state,
                      state.remote === connection, state.snapshot.buffers[currentIndex].path == buffer.path,
                      !state.movingPaths.contains(where: { buffer.path == $0 || buffer.path.hasPrefix($0 + "/") }) else { return }
                imagePreviews[id] = preview
                externalFileErrors.removeValue(forKey: id)
                observedFileRevisions[id] = ObservedFileRevision(path: buffer.path, revision: revision, checkedAt: Date(),
                    verifyAgain: buffer.isRemote && previous?.revision != revision)
                return
            }
            let text: String
            let after: FileRevision
            if let connection, buffer.isRemote {
                text = try await connection.read(buffer.path)
                after = try await connection.revision(buffer.path)
            } else {
                (text, after) = try await Task.detached {
                    (try TextFiles.read(URL(fileURLWithPath: buffer.path)), try FileRevision.local(buffer.path))
                }.value
            }
            guard !Task.isCancelled, !fileRefreshPaused, after == revision, !saving.contains(id),
                  let (currentState, currentIndex) = locate(id), currentState === state,
                  state.remote === connection,
                  !state.movingPaths.contains(where: { buffer.path == $0 || buffer.path.hasPrefix($0 + "/") }) else { return }
            let currentBuffer = state.snapshot.buffers[currentIndex]
            guard currentBuffer.path == buffer.path, currentBuffer.text == buffer.text,
                  currentBuffer.savedText == buffer.savedText, currentBuffer.isDirty == buffer.isDirty else { return }
            observedFileRevisions[id] = ObservedFileRevision(path: buffer.path, revision: revision, checkedAt: Date(),
                verifyAgain: buffer.isRemote && previous?.revision != revision)
            externalFileErrors.removeValue(forKey: id)
            if buffer.isDirty && !discardChanges {
                if text != buffer.savedText { externallyChangedBuffers.insert(id) }
                else { externallyChangedBuffers.remove(id) }
                return
            }
            externallyChangedBuffers.remove(id)
            if text != buffer.text || buffer.savedText != text || buffer.isDirty {
                state.snapshot.buffers[currentIndex].text = text
                state.snapshot.buffers[currentIndex].savedText = text
                state.snapshot.buffers[currentIndex].isDirty = false
                schedulePersist()
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, let (currentState, currentIndex) = locate(id), currentState === state,
                  state.snapshot.buffers[currentIndex].path == buffer.path, state.remote === connection else { return }
            observedFileRevisions.removeValue(forKey: id)
            let message = buffer.isImage ? "Could not load this image. \(error.localizedDescription)"
                : "Could not refresh this file. Your open text is kept. \(error.localizedDescription)"
            if externalFileErrors[id] != message { externalFileErrors[id] = message }
        }
    }

    @discardableResult func saveBuffer(_ id: BufferID, overwrite: Bool = false) async -> Bool {
        guard let (state, index) = locate(id), !state.snapshot.buffers[index].isImage, !saving.contains(id) else { return false }
        guard !state.movingPaths.contains(where: { state.snapshot.buffers[index].path == $0 || state.snapshot.buffers[index].path.hasPrefix($0 + "/") }) else {
            statusMessage = "Wait for the file move to finish before saving."; return false
        }
        saving.insert(id); defer { saving.remove(id) }
        let buffer = state.snapshot.buffers[index]
        do {
            if buffer.isRemote {
                guard let remote = state.remote else { throw FileFailure.disconnected }
                try await remote.write(buffer.text, path: buffer.path, expected: buffer.savedText, overwrite: overwrite)
            } else { try TextFiles.write(buffer.text, to: URL(fileURLWithPath: buffer.path), expected: buffer.savedText, overwrite: overwrite) }
            if let index = state.snapshot.buffers.firstIndex(where: { $0.id == id }) {
                state.snapshot.buffers[index].savedText = buffer.text
                state.snapshot.buffers[index].isDirty = state.snapshot.buffers[index].text != buffer.text
                observedFileRevisions.removeValue(forKey: id)
                externallyChangedBuffers.remove(id); externalFileErrors.removeValue(forKey: id)
            }
            statusMessage = "Saved \(buffer.title)"; schedulePersist()
            // A remote save can finish after another edit. Do not let a pending
            // Save-and-Close or Quit discard those newer, still-unsaved edits.
            return !state.snapshot.buffers.contains { $0.id == id && $0.isDirty }
        } catch FileFailure.conflict { conflictRequest = id }
        catch { report(error) }
        return false
    }
    func saveAll() async -> Bool {
        for id in states.flatMap(\.snapshot.buffers).filter(\.isDirty).map(\.id) {
            if !(await saveBuffer(id)) { return false }
        }
        return !hasUnsavedChanges
    }
    func closeBuffer(_ id: BufferID) {
        if let (state, index) = locate(id), state.snapshot.buffers[index].isDirty { closeRequest = id }
        else { discardBuffer(id) }
    }
    func discardBuffer(_ id: BufferID) {
        guard let (state, _) = locate(id) else { return }
        state.snapshot.buffers.removeAll { $0.id == id }
        imagePreviews.removeValue(forKey: id)
        observedFileRevisions.removeValue(forKey: id)
        externallyChangedBuffers.remove(id); externalFileErrors.removeValue(forKey: id)
        state.snapshot.layout?.remove(.file(id))
        if state.snapshot.selectedBufferID == id { state.snapshot.selectedBufferID = state.snapshot.buffers.last?.id }
        if state.snapshot.splitBufferID == id { state.snapshot.splitBufferID = nil }
        schedulePersist()
    }
    func toggleSplit() {
        current.snapshot.splitBufferID = current.snapshot.splitBufferID == nil ? selectedBufferID : nil; schedulePersist()
    }
    func newUntitledBuffer() { createEntry(name: "untitled-\(UUID().uuidString.prefix(6)).txt", directory: false) }
    @discardableResult func createEntry(name: String, directory: Bool, in parentPath: String? = nil) -> Task<Void, Never> {
        guard hasWorkspace else { folderImporterVisible = true; return Task {} }
        let state = current
        return Task {
            do {
                try TextFiles.validateName(name)
                let path = ((parentPath ?? state.contextDirectoryPath) as NSString).appendingPathComponent(name)
                if state.snapshot.workspace.isRemote {
                    guard let remote = state.remote else { throw FileFailure.disconnected }
                    try await remote.create(path, directory: directory)
                } else if directory { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) }
                else { try Data().write(to: URL(fileURLWithPath: path), options: .withoutOverwriting) }
                if !directory { addBuffer(path: path, text: "", to: state) }
                state.explorer.selectedPath = path
                if parentPath != nil {
                    await state.explorer.reveal(FileEntry(name: name, path: path, isDirectory: false))
                }
                if state.id == selectedWorkspaceID { refreshFiles() }
            } catch { report(error) }
        }
    }
    @discardableResult func rename(_ entry: FileEntry, to name: String) -> Task<Void, Never> {
        let state = current
        return Task {
            do {
                try TextFiles.validateName(name)
                let destination = ((entry.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
                guard destination != entry.path else { return }
                if state.snapshot.workspace.isRemote {
                    guard let remote = state.remote else { throw FileFailure.disconnected }
                    try await remote.rename(entry.path, to: destination)
                } else { try FileManager.default.moveItem(atPath: entry.path, toPath: destination) }
                state.explorer.didRename(from: entry.path, to: destination)
                for index in state.snapshot.buffers.indices {
                    let path = state.snapshot.buffers[index].path
                    if path == entry.path || path.hasPrefix(entry.path + "/") {
                        state.snapshot.buffers[index].path = destination + path.dropFirst(entry.path.count)
                        state.snapshot.buffers[index].title = (state.snapshot.buffers[index].path as NSString).lastPathComponent
                        state.snapshot.buffers[index].language = LanguageMode.infer(filename: state.snapshot.buffers[index].title)
                    }
                }
                if state.id == selectedWorkspaceID { refreshFiles() }; schedulePersist()
            } catch { report(error) }
        }
    }
    func canMoveFile(_ drag: ExplorerFileDrag, to folder: String) -> Bool {
        guard drag.workspaceID == selectedWorkspaceID, hasWorkspace else { return false }
        let root = current.contextRootPath
        func within(_ path: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
        guard within(drag.path), within(folder), drag.path != root,
              (drag.path as NSString).deletingLastPathComponent != folder,
              !drag.isDirectory || (folder != drag.path && !folder.hasPrefix(drag.path + "/")) else { return false }
        return folder == root || current.explorer.children.values.joined().contains { $0.path == folder && $0.isDirectory }
            || current.explorer.results.contains { $0.path == folder && $0.isDirectory }
    }
    @discardableResult func moveFile(_ drag: ExplorerFileDrag, to folder: String) -> Task<Void, Never> {
        guard canMoveFile(drag, to: folder) else { return Task {} }
        let state = current
        return Task {
            do { try await performFileMove(drag, to: folder, in: state) }
            catch { report(error) }
        }
    }

    func moveOpenFile(_ id: BufferID, to folder: String) async throws {
        guard let (state, index) = locate(id) else { throw CommandError("This file is no longer open.") }
        let drag = ExplorerFileDrag(workspaceID: state.id, path: state.snapshot.buffers[index].path, isDirectory: false)
        try await performFileMove(drag, to: folder, in: state)
    }

    func moveExplorerFile(_ drag: ExplorerFileDrag, to folder: String) async throws {
        guard let state = states.first(where: { $0.id == drag.workspaceID }) else {
            throw CommandError("This workspace was removed.")
        }
        try await performFileMove(drag, to: folder, in: state)
    }

    private func performFileMove(_ drag: ExplorerFileDrag, to folder: String, in state: WorkspaceState) async throws {
        let connection = state.remote
        let contextRoot = state.contextRootPath
        let affected = state.snapshot.buffers.filter { $0.path == drag.path || $0.path.hasPrefix(drag.path + "/") }
        guard !affected.contains(where: { saving.contains($0.id) }),
              !state.movingPaths.contains(where: { drag.path == $0 || drag.path.hasPrefix($0 + "/") || $0.hasPrefix(drag.path + "/") }) else {
            throw CommandError("Wait for the current save or move to finish.")
        }
        state.movingPaths.insert(drag.path)
        defer { state.movingPaths.remove(drag.path) }
        let source: String, parent: String, root: String
        if state.snapshot.workspace.isRemote {
            guard let remote = connection else { throw FileFailure.disconnected }
            root = try await remote.realPath(contextRoot)
            parent = try await remote.realPath(folder)
            source = (try await remote.realPath((drag.path as NSString).deletingLastPathComponent) as NSString).appendingPathComponent(drag.name)
        } else {
            root = URL(fileURLWithPath: contextRoot).resolvingSymlinksInPath().path
            parent = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
            source = URL(fileURLWithPath: drag.path).deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(drag.name).path
            guard try URL(fileURLWithPath: parent).resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        func within(_ path: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
        guard within(source), within(parent), source != root,
              !drag.isDirectory || (parent != source && !parent.hasPrefix(source + "/")) else {
            throw CommandError("Files can only be moved within this workspace, outside their own subfolders.")
        }
        let destination = (parent as NSString).appendingPathComponent(drag.name)
        guard destination != source else { return }
        if state.snapshot.workspace.isRemote {
            guard let remote = connection else { throw FileFailure.disconnected }
            guard try await !remote.list(parent).contains(where: { $0.name == drag.name }) else { throw CocoaError(.fileWriteFileExists) }
            try Task.checkCancellation()
            guard state.remote === remote, states.contains(where: { $0 === state }) else { throw FileFailure.disconnected }
            try await remote.rename(source, to: destination)
        } else {
            guard (try? FileManager.default.attributesOfItem(atPath: destination)) == nil else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.moveItem(atPath: source, toPath: destination)
        }
        state.explorer.didRename(from: drag.path, to: destination)
        for index in state.snapshot.buffers.indices {
            let path = state.snapshot.buffers[index].path
            if path == drag.path || path.hasPrefix(drag.path + "/") {
                state.snapshot.buffers[index].path = destination + path.dropFirst(drag.path.count)
            }
        }
        let working = state.snapshot.directoryPath
        if working == drag.path || working.hasPrefix(drag.path + "/") {
            state.snapshot.directoryPath = destination + working.dropFirst(drag.path.count)
        }
        state.explorer.selectedPath = destination
        await state.explorer.reveal(.init(name: drag.name, path: destination, isDirectory: false))
        if selectedWorkspaceID == state.id { refreshFiles() }
        statusMessage = "Moved \(drag.name) to \(state.explorer.relativePath(parent))"
        schedulePersist()
    }

    func fileMoveFolders(_ id: BufferID, at path: String) async throws -> (path: String, root: String, folders: [FileEntry]) {
        guard let (state, _) = locate(id) else { throw CommandError("This file is no longer open.") }
        return try await fileMoveFolders(workspaceID: state.id, at: path)
    }

    func fileMoveFolders(workspaceID: WorkspaceID, at path: String) async throws -> (path: String, root: String, folders: [FileEntry]) {
        guard let state = states.first(where: { $0.id == workspaceID }) else { throw CommandError("This workspace was removed.") }
        let root = state.contextRootPath
        let resolved: String, canonicalRoot: String
        let folders: [FileEntry]
        if state.snapshot.workspace.isRemote {
            let remote = try fileConnection(in: state)
            canonicalRoot = try await remote.realPath(root)
            resolved = try await remote.realPath(path)
            guard resolved == canonicalRoot || resolved.hasPrefix(canonicalRoot == "/" ? "/" : canonicalRoot + "/") else {
                throw CommandError("Choose a folder inside this workspace.")
            }
            folders = try await remote.list(resolved).filter { $0.isDirectory && $0.name != "." && $0.name != ".." }
            guard state.remote === remote else { throw FileFailure.disconnected }
        } else {
            canonicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            (resolved, folders) = try await Task.detached(priority: .utility) {
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                guard url.path == canonicalRoot || url.path.hasPrefix(canonicalRoot == "/" ? "/" : canonicalRoot + "/") else {
                    throw CommandError("Choose a folder inside this workspace.")
                }
                let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
                return (url.path, try entries.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
                    .map { FileEntry(name: $0.lastPathComponent, path: $0.path, isDirectory: true) })
            }.value
        }
        try Task.checkCancellation()
        guard states.contains(where: { $0 === state }) else { throw CommandError("This workspace was removed.") }
        return (resolved, canonicalRoot, folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    /// Export the original bytes, or the current draft when a text file has unsaved edits.
    func downloadOpenFile(_ id: BufferID) async throws -> Data {
        guard let (state, index) = locate(id) else { throw CommandError("This file is no longer open.") }
        let buffer = state.snapshot.buffers[index], connection = state.remote
        guard !state.movingPaths.contains(buffer.path) else { throw CommandError("Wait for the file move to finish.") }
        if buffer.isDirty && !buffer.isImage { return Data(buffer.text.utf8) }
        let data: Data
        if buffer.isRemote {
            guard let connection else { throw FileFailure.disconnected }
            data = try await connection.readData(buffer.path, maximumSize: FileDownload.sizeLimit)
        } else {
            data = try await Task.detached(priority: .utility) { try FileDownload.read(buffer.path) }.value
        }
        try Task.checkCancellation()
        guard let (latestState, latestIndex) = locate(id), latestState === state,
              state.remote === connection, state.snapshot.buffers[latestIndex].path == buffer.path,
              !state.movingPaths.contains(buffer.path) else { throw CommandError("The file changed location. Try downloading it again.") }
        return data
    }
    func requestDelete(_ entry: FileEntry) {
        deleteWorkspaceID = selectedWorkspaceID
        deleteRequest = entry
    }

    @discardableResult func trash(_ entry: FileEntry, workspaceID: WorkspaceID? = nil) -> Task<Void, Never> {
        guard let state = states.first(where: { $0.id == (workspaceID ?? selectedWorkspaceID) }) else {
            report(CommandError("This workspace was removed.")); return Task {}
        }
        let destination = settings.effectiveFileDeletionDestination
        let contextRoot = state.contextRootPath
        return Task {
            do {
                let root: String, path: String
                if state.snapshot.workspace.isRemote {
                    guard let remote = state.remote else { throw FileFailure.disconnected }
                    root = try await remote.realPath(contextRoot)
                    path = (try await remote.realPath((entry.path as NSString).deletingLastPathComponent) as NSString).appendingPathComponent(entry.name)
                    guard state.remote === remote else { throw FileFailure.disconnected }
                } else {
                    root = URL(fileURLWithPath: contextRoot).resolvingSymlinksInPath().path
                    path = URL(fileURLWithPath: entry.path).deletingLastPathComponent().resolvingSymlinksInPath()
                        .appendingPathComponent(entry.name).path
                }
                guard path != root, path.hasPrefix(root == "/" ? "/" : root + "/") else {
                    throw CommandError("Only items inside this workspace can be deleted.")
                }
                try Task.checkCancellation()
                guard states.contains(where: { $0 === state }) else { throw CommandError("This workspace was removed.") }
                let affected = state.snapshot.buffers.filter { $0.path == entry.path || $0.path.hasPrefix(entry.path + "/") }
                guard !affected.contains(where: \.isDirty) else {
                    errorMessage = "Save or close the modified files inside this item before deleting it."; return
                }
                guard !affected.contains(where: { saving.contains($0.id) }),
                      !state.movingPaths.contains(where: { entry.path == $0 || entry.path.hasPrefix($0 + "/") || $0.hasPrefix(entry.path + "/") }) else {
                    throw CommandError("Wait for the current save or move to finish.")
                }
                state.movingPaths.insert(entry.path)
                defer { state.movingPaths.remove(entry.path) }
                let recovery: String
                if destination == .trash {
                    if state.snapshot.workspace.isRemote {
                        recovery = try await moveToHostTrash(entry, in: state)
                    } else {
                        var result: NSURL?
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: &result)
                        recovery = result?.path ?? "Trash"
                    }
                } else if state.snapshot.workspace.isRemote {
                    guard let remote = state.remote else { throw FileFailure.disconnected }
                    recovery = try await remote.trash(entry, rootPath: contextRoot)
                } else {
                    let root = URL(fileURLWithPath: contextRoot)
                    let storage = root.appendingPathComponent(".crow", isDirectory: true)
                    let folder = storage.appendingPathComponent("recovery", isDirectory: true)
                    guard !folder.path.hasPrefix(entry.path + "/") else { throw FileFailure.invalidName }
                    for directory in [storage, folder] {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw FileFailure.invalidName }
                    }
                    let legacy = root.appendingPathComponent(".crow-trash", isDirectory: true)
                    if legacy.path != entry.path, FileManager.default.fileExists(atPath: legacy.path) {
                        try FileManager.default.moveItem(at: legacy, to: folder.appendingPathComponent("legacy-" + UUID().uuidString))
                    }
                    let target = folder.appendingPathComponent(UUID().uuidString + "-" + entry.name)
                    try FileManager.default.moveItem(atPath: entry.path, toPath: target.path); recovery = target.path
                }
                affected.forEach { discardBuffer($0.id) }; statusMessage = "Moved to \(recovery)"
                if state.id == selectedWorkspaceID { refreshFiles() }; schedulePersist()
            } catch { report(error) }
        }
    }

    private func moveToHostTrash(_ entry: FileEntry, in state: WorkspaceState) async throws -> String {
        guard let remote = state.remote, remote.isConnected else { throw FileFailure.disconnected }
        let marker = "CROW_TRASH_OK_" + UUID().uuidString
        let command = "( " + RemoteConnection.trashCommand(path: entry.path) + " ) 2>&1 && printf '\n" + marker + "\n'"
        let output: String
        #if os(macOS)
        if let ssh = state.systemSSH {
            output = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-T"] + ssh.multiplexArguments
                + ["sh -lc " + TerminalCommand.quote(command)], operation: "Trash")
        } else {
            output = try await remote.workspaceCommand(command, operation: "Trash")
        }
        #else
        output = try await remote.workspaceCommand(command, operation: "Trash")
        #endif
        guard output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(marker) else {
            throw CommandError(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Could not move this item to the server’s trash. Choose Recovery Folder in Settings if trash is unavailable."
                : String(output.prefix(2000)))
        }
        return "Trash on " + workspaceHostName(state)
    }

    func showHosts() {
        sidebarPane = .workspaces; sidebarVisible = true; compactSurface = .hosts
    }

    func editHost(_ host: SSHHost? = nil) {
        editingHost = host
        if sshCommandVisible {
            pendingHostEditor = true; sshCommandVisible = false
        } else { hostEditorVisible = true }
    }

    func saveHostFromEditor(_ proposed: SSHHost, credential: HostCredential, connectAfterSaving: Bool) throws {
        var host = proposed
        var credential = credential
        if host.authentication == .password { credential.keyID = nil }
        if credential.keyID != nil {
            credential.privateKey = ""; credential.passphrase = ""; credential.password = ""
            // A library key uses in-app authentication instead of the saved system SSH command.
            host.commandArguments = nil; host.commandDirectory = nil
        }
        host.hostname = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        host.username = host.username.trimmingCharacters(in: .whitespacesAndNewlines)
        host.name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.name.isEmpty { host.name = host.hostname }
        if host.remotePath.isEmpty { host.remotePath = "~" }
        if host.authentication != .password { try credential.resolved(for: host.authentication).validatePrivateKey(for: host.authentication) }
        try storeHost(host, credential: credential)
        showHosts()
        statusMessage = "Saved \(host.name) — tap the host to connect."
        pendingHostConnection = connectAfterSaving ? host : nil
    }

    func finishHostEditorDismissal() {
        guard let host = pendingHostConnection else { return }
        pendingHostConnection = nil
        connect(host)
    }
    func connectCommand(_ line: String, password: String = "", preserveReverseSSH: Bool = false) async throws {
        let command = try SSHCommand(line)
        #if os(macOS)
        let directory = !hasWorkspace || current.snapshot.workspace.isRemote ? vaultURL.path : current.snapshot.directoryPath
        let spec = try await bridge().prepare(command.arguments, directory: directory)
        try Task.checkCancellation()
        beginSystemSSH(spec, imported: false, preserveReverseSSH: preserveReverseSSH)
        #else
        let (parsed, identity) = try command.portableHost(defaultUsername: "")
        var host = hosts.first { $0.hostname == parsed.hostname && $0.port == parsed.port && $0.username == parsed.username } ?? parsed
        host.commandArguments = command.arguments
        let saved = try SecureStore.credential(host)
        let missingCredential = host.authentication == .password
            ? saved.password.isEmpty && password.isEmpty
            : saved.keyID == nil && saved.privateKey.isEmpty
        if identity != nil || missingCredential {
            if identity != nil { host.authentication = .ed25519 }
            if sshCommandVisible { pendingCredentialRequest = host } else { credentialRequest = host }
            return
        }
        try storeHost(host, credential: password.isEmpty ? saved : HostCredential(password: password))
        connect(host)
        #endif
    }

    #if os(macOS)
    private func bridge() throws -> SystemSSHBridge {
        if let sshBridge { return sshBridge }
        let value = try SystemSSHBridge()
        value.onConnection = { [weak self] spec in self?.beginSystemSSH(spec, imported: true) }
        sshBridge = value; return value
    }

    private func beginSystemSSH(_ proposed: SystemSSHSpec, imported: Bool, preserveReverseSSH: Bool = false, workspaceID: WorkspaceID? = nil, select: Bool = true) {
        if let workspaceID, !states.contains(where: { $0.id == workspaceID }) { return }
        var host = proposed.host
        if let saved = hosts.first(where: { $0.hostname == host.hostname && $0.port == host.port && $0.username == host.username }) {
            host.id = saved.id; host.lastConnectedAt = saved.lastConnectedAt
        }
        let spec = SystemSSHSpec(host: host, socket: proposed.socket, arguments: proposed.arguments, directory: proposed.directory)
        if let index = hosts.firstIndex(where: { $0.id == host.id }) { hosts[index] = host } else { hosts.append(host) }
        let state: WorkspaceState
        if let existing = preferredRemoteWorkspace(hostID: host.id, id: workspaceID) {
            if existing.remote?.isConnected == true {
                recordHostConnection(host.id)
                if !imported && select { selectWorkspace(existing.id, showFiles: false); terminalVisible = true; compactSurface = .terminal }
                return
            }
            state = existing; disconnect(state, stopReverseSSH: !preserveReverseSSH)
        } else {
            // Resolve the server's starting directory only for a new workspace.
            // Existing project selections survive reconnect; later terminal cd is independent.
            state = WorkspaceState(.init(workspace: Workspace(name: host.name, kind: .remote(hostID: host.id, path: "."), connection: .connecting), rootPath: "."))
            states.append(state)
        }
        state.systemSSH = spec
        state.snapshot.workspace.connection = .connecting
        if !imported {
            if select { selectWorkspace(state.id, showFiles: false); terminalVisible = true; compactSurface = .terminal }
            if state.snapshot.selectedTerminalID == nil {
                let id = UUID(); state.snapshot.terminalIDs.append(id); state.snapshot.selectedTerminalID = id
                state.snapshot.layout?.open(.terminal(id))
            }
            if state.snapshot.agentTerminals.contains(where: { $0.id == state.snapshot.selectedTerminalID }) {
                let id = UUID(); state.snapshot.terminalIDs.append(id); state.snapshot.selectedTerminalID = id
                state.snapshot.layout?.open(.terminal(id))
            }
            let authenticationTerminalID = state.snapshot.selectedTerminalID!
            state.snapshot.layout?.open(.terminal(authenticationTerminalID))
            if selectedWorkspaceID == state.id { terminalVisible = true; compactSurface = .terminal }
            terminal(state.snapshot.selectedTerminalID!, in: state).start()
        }
        state.connectionTask = Task { [weak self, weak state] in
            guard let self, let state else { return }
            do {
                for _ in 0..<1200 {
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: spec.socket) { break }
                    if !imported, !state.terminals.values.contains(where: \.running) { throw CommandError("SSH exited before connecting. Run the command again to retry.") }
                    try await Task.sleep(for: .milliseconds(250))
                }
                let connection = RemoteConnection(); try connection.attach(spec)
                state.remote = connection
                let root = try await connection.realPath(state.snapshot.rootPath)
                try Task.checkCancellation()
                guard state.remote === connection else { return }
                state.snapshot.rootPath = root; state.snapshot.directoryPath = root
                state.snapshot.workspace.kind = .remote(hostID: host.id, path: root)
                if state.snapshot.workspace.name == host.name { state.snapshot.workspace.name = workspaceFolderName(root) }
                state.snapshot.workspace.connection = .connected
                recordHostConnection(host.id)
                if selectedWorkspaceID == state.id { refreshFiles() }
                statusMessage = "SSH workspace added: \(host.userAtHost)"; schedulePersist()
            } catch {
                if !Task.isCancelled {
                    state.snapshot.workspace.connection = .failed(error.localizedDescription)
                    statusMessage = error.localizedDescription
                }
            }
        }
        schedulePersist()
    }
    #endif
    func storeHost(_ host: SSHHost, credential: HostCredential) throws {
        var host = host
        host.lastConnectedAt = hosts.first(where: { $0.id == host.id })?.lastConnectedAt ?? host.lastConnectedAt
        guard !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty, !host.username.isEmpty, (1...65535).contains(host.port) else {
            throw NSError(domain: "Crow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a host, username and port between 1 and 65535."])
        }
        try SecureStore.set(JSONEncoder().encode(credential), for: host.id.rawValue.uuidString)
        if let index = hosts.firstIndex(where: { $0.id == host.id }) { hosts[index] = host } else { hosts.append(host) }
        schedulePersist()
    }
    func removeHost(_ host: SSHHost) {
        do {
            let workspaces = states.filter { $0.snapshot.workspace.hostID == host.id }
            guard !workspaces.contains(where: { $0.snapshot.buffers.contains(where: \.isDirty) }) else {
                throw CommandError("Save or close this host's unsaved files before removing it.")
            }
            #if os(macOS)
            reverseSSHConnections.removeValue(forKey: host.id)?.stop()
            #endif
            try SecureStore.remove(host.id.rawValue.uuidString); hosts.removeAll { $0.id == host.id }
            for state in workspaces { removeWorkspace(state.id) }
            schedulePersist()
        } catch { report(error) }
    }
    func connectionState(for host: SSHHost) -> ConnectionState {
        let workspaces = states.filter { $0.snapshot.workspace.hostID == host.id }
        if workspaces.contains(where: { $0.remote?.isConnected == true }) { return .connected }
        if workspaces.contains(where: { $0.snapshot.workspace.connection == .connecting }) { return .connecting }
        return workspaces.first?.snapshot.workspace.connection ?? .disconnected
    }

    func disconnect(_ host: SSHHost) {
        for state in states {
            if case .remote(let id, _) = state.snapshot.workspace.kind, id == host.id {
                disconnect(state)
            }
        }
        statusMessage = "Disconnected from \(host.userAtHost)"
        schedulePersist()
    }

    func connect(_ host: SSHHost, select: Bool = true, workspaceID: WorkspaceID? = nil) {
        if let target = preferredRemoteWorkspace(hostID: host.id, id: workspaceID),
           let connected = states.first(where: { $0.snapshot.workspace.hostID == host.id && $0.remote?.isConnected == true }) {
            shareConnection(from: connected, to: target)
            recordHostConnection(host.id)
            if select { activateWorkspace(target.id, reconnect: false) }
            return
        }
        if let target = preferredRemoteWorkspace(hostID: host.id, id: workspaceID),
           let pending = states.first(where: { $0 !== target && $0.snapshot.workspace.hostID == host.id && $0.snapshot.workspace.connection == .connecting }) {
            if select { activateWorkspace(target.id, reconnect: false) }
            target.snapshot.workspace.connection = .connecting
            target.connectionTask = Task { [weak self, weak target, weak pending] in
                await pending?.connectionTask?.value
                guard let self, let target, let pending, !Task.isCancelled else { return }
                if pending.remote?.isConnected == true {
                    self.shareConnection(from: pending, to: target)
                    if self.selectedWorkspaceID == target.id { self.refreshFiles() }
                } else { target.snapshot.workspace.connection = pending.snapshot.workspace.connection }
            }
            return
        }
        #if os(macOS)
        if let arguments = host.commandArguments {
            if preferredRemoteWorkspace(hostID: host.id, id: workspaceID)?.snapshot.workspace.connection == .connecting { return }
            Task {
                do { let spec = try await bridge().prepare(arguments, directory: host.commandDirectory ?? vaultURL.path); beginSystemSSH(spec, imported: false, workspaceID: workspaceID, select: select) }
                catch { report(error) }
            }
            return
        }
        #endif
        let state: WorkspaceState
        if let existing = preferredRemoteWorkspace(hostID: host.id, id: workspaceID) { state = existing }
        else {
            state = WorkspaceState(.init(workspace: Workspace(name: host.name,
                kind: .remote(hostID: host.id, path: host.remotePath), connection: .disconnected), rootPath: host.remotePath))
            states.append(state)
        }
        if select { selectWorkspace(state.id, showFiles: false) }
        #if os(iOS)
        if select { compactSurface = .terminal; terminalVisible = true }
        #endif
        if state.snapshot.workspace.connection == .connected || state.snapshot.workspace.connection == .connecting { return }
        state.snapshot.workspace.connection = .connecting
        let connection = RemoteConnection(); state.remote = connection
        state.connectionTask = Task {
            do {
                try await connection.connect(host, credential: SecureStore.credential(host)); try Task.checkCancellation()
                connection.client?.onDisconnect { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        let affected = self.states.filter { $0.remote === connection }
                        for workspace in affected {
                            workspace.snapshot.workspace.connection = .disconnected; workspace.stopTerminals()
                            #if os(iOS)
                            if !self.fileRefreshPaused { self.recoverBackgroundSSH(workspace) }
                            #endif
                        }
                        self.statusMessage = "Connection closed — reconnect to start a new shell."
                    }
                }
                let root = try await connection.realPath(state.snapshot.rootPath)
                try Task.checkCancellation()
                guard state.remote === connection else { await connection.disconnect(); return }
                state.snapshot.rootPath = root; state.snapshot.directoryPath = root
                state.snapshot.workspace.kind = .remote(hostID: host.id, path: root)
                if state.snapshot.workspace.name == host.name { state.snapshot.workspace.name = workspaceFolderName(root) }
                state.stopTerminals(); state.snapshot.workspace.connection = .connected
                recordHostConnection(host.id)
                statusMessage = "Connected to \(host.userAtHost)"
                if selectedWorkspaceID == state.id { refreshFiles() }; schedulePersist()
            } catch let challenge as HostKeyChallenge {
                guard state.remote === connection, !Task.isCancelled else { return }
                state.snapshot.workspace.connection = .disconnected; state.remote = nil; hostKeyChallenge = challenge
            } catch {
                await connection.disconnect()
                if state.remote === connection { state.snapshot.workspace.connection = .failed(error.localizedDescription); state.remote = nil }
                if !Task.isCancelled { report(error) }
            }
        }
    }
    func trustHostKey(_ challenge: HostKeyChallenge) {
        do { try SecureStore.set(Data(challenge.key.utf8), for: challenge.account); connect(challenge.host) }
        catch { report(error) }
    }
    func reconnectCurrent() {
        guard case .remote(let id, _) = selectedWorkspace.kind, let host = hosts.first(where: { $0.id == id }) else { return }
        disconnect(current); connect(host, workspaceID: current.id)
    }
    func disconnectCurrent() { disconnect(current) }
    #if os(macOS)
    func copyReverseSSHCommand(for host: SSHHost) {
        guard let command = reverseSSHConnections[host.id]?.connectCommand else { return }
        reverseSSHPasteboard.clearContents()
        if reverseSSHPasteboard.setString(command, forType: .string) {
            statusMessage = "Reverse SSH command copied — paste it on the server and enter your access password."
        } else { report(CommandError("Could not copy the Reverse SSH command. Use the host menu to try again.")) }
    }

    func setReverseSSH(_ enabled: Bool, for host: SSHHost) {
        if !enabled { reverseSSHConnections[host.id]?.stop(); return }
        let password: String
        do {
            guard let saved = try reverseSSHAccess.password() else {
                settingsVisible = true
                statusMessage = "Set a Reverse SSH password in Settings first."
                return
            }
            password = saved
        } catch { report(error); return }
        let session = reverseSSHConnections[host.id] ?? ReverseSSHSession()
        reverseSSHConnections[host.id] = session
        session.start(password: password, onReady: { [weak self] _ in
            self?.copyReverseSSHCommand(for: host)
        }) { [weak self] in
            guard let self else { throw CancellationError() }
            if let spec = connectedSystemSSH(for: host.id) { return spec }
            guard let arguments = host.commandArguments else {
                throw CommandError("Connect this host with an SSH command once to enable Reverse SSH.")
            }
            try await connectCommand("ssh " + arguments.map(SystemSSHBridge.quote).joined(separator: " "), preserveReverseSSH: true)
            for _ in 0..<480 {
                try Task.checkCancellation()
                if let spec = connectedSystemSSH(for: host.id) { return spec }
                let workspaces = states.filter { $0.snapshot.workspace.hostID == host.id }
                if !workspaces.contains(where: { $0.snapshot.workspace.connection == .connecting }),
                   let workspace = preferredRemoteWorkspace(hostID: host.id),
                   case .failed(let error) = workspace.snapshot.workspace.connection {
                    throw CommandError(error)
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw CommandError("Finish SSH authentication in the terminal, then enable Reverse SSH again.")
        }
    }

    /// Reverse SSH belongs to a host, not whichever project appears first in its list.
    func connectedSystemSSH(for hostID: HostID) -> SystemSSHSpec? {
        states.first {
            $0.snapshot.workspace.hostID == hostID && $0.systemSSH != nil &&
                $0.snapshot.workspace.connection == .connected
        }?.systemSSH
    }
    #endif
    private func disconnect(_ state: WorkspaceState, stopReverseSSH: Bool = true) {
        if state.snapshot.workspace.isRemote { state.browsers.values.forEach { $0.disconnect() } }
        #if os(iOS)
        backgroundSSH.remove(state.id)
        foregroundChecks.removeValue(forKey: state.id)?.cancel()
        #endif
        #if os(macOS)
        if stopReverseSSH, let id = state.snapshot.workspace.hostID,
           !states.contains(where: { $0 !== state && $0.snapshot.workspace.hostID == id && $0.remote?.isConnected == true }) { reverseSSHConnections[id]?.stop() }
        state.systemSSH = nil
        #endif
        state.explorer.stop()
        state.connectionTask?.cancel(); state.connectionTask = nil
        let connection = state.remote; state.remote = nil; state.stopTerminals()
        state.snapshot.workspace.connection = .disconnected
        if let connection, !states.contains(where: { $0.remote === connection }) { Task { await connection.disconnect() } }
    }
    func terminal(_ id: UUID, in state: WorkspaceState) -> TerminalSession {
        if let existing = state.terminals[id] { return existing }
        var useSystemSSH = false
        #if os(macOS)
        useSystemSSH = state.systemSSH != nil
        #endif
        let directory = state.contextRootPath
        let session = TerminalSession(id: id, workspace: state.snapshot.workspace, directory: directory,
            remote: state.remote, fontSize: settings.terminalFontSize, useSystemSSH: useSystemSSH)
        if let agent = state.snapshot.agentTerminals.first(where: { $0.id == id }) {
            session.launchCommand = agent.command
            session.agentProvider = agent.provider
        }
        session.imagePasteContext = { [weak self, weak state] in
            guard let self, let state else { return nil }
            return self.imagePasteContext(for: id, in: state)
        }
        session.uploadImage = { [weak self, weak state] data, context in
            guard let self, let state, self.imagePasteContext(for: id, in: state) == context else { throw FileFailure.disconnected }
            if state.snapshot.workspace.isRemote {
                guard let remote = state.remote else { throw FileFailure.disconnected }
                return try await remote.uploadClipboardImage(data)
            }
            #if os(macOS)
            let bridge = try self.bridge()
            let spec = try await bridge.imagePasteConnection(socket: context)
            guard bridge.activeSocket(for: id) == context else { throw FileFailure.disconnected }
            let files = try SystemSFTP(spec: spec)
            defer { files.close() }
            return try await files.uploadClipboardImage(data)
            #else
            throw FileFailure.disconnected
            #endif
        }
        #if os(macOS)
        session.systemSSH = state.systemSSH
        if state.snapshot.workspace.kind == .local {
            do { session.shellEnvironment = try bridge().environment } catch { report(error) }
        }
        #endif
        state.terminals[id] = session
        state.terminalGeneration += 1
        return session
    }
    private func imagePasteContext(for terminalID: UUID, in state: WorkspaceState) -> String? {
        if state.snapshot.workspace.isRemote {
            guard let remote = state.remote, remote.isConnected else { return nil }
            #if os(macOS)
            if let socket = state.systemSSH?.socket { return socket }
            #endif
            return String(describing: ObjectIdentifier(remote))
        }
        #if os(macOS)
        return sshBridge?.activeSocket(for: terminalID)
        #else
        return nil
        #endif
    }
    func newTab(in paneID: UUID? = nil) {
        guard hasWorkspace else { folderImporterVisible = true; return }
        ensureLayout(current)
        current.snapshot.layout?.open(.start(UUID()), in: paneID)
        current.maximizedPaneID = nil
        schedulePersist()
    }

    func newTerminal() {
        guard hasWorkspace else { folderImporterVisible = true; return }
        ensureLayout(current)
        let id = UUID(); current.snapshot.terminalIDs.append(id); current.snapshot.selectedTerminalID = id
        current.snapshot.layout?.open(.terminal(id)); current.maximizedPaneID = nil
        terminalVisible = true; schedulePersist()
    }
    func requestTerminalClose(_ id: UUID?) {
        guard let id, let state = states.first(where: { $0.snapshot.terminalIDs.contains(id) }) else { return }
        let session = state.terminals[id]
        session?.updateAgentActivity()
        if session?.isWorking == true { terminalCloseRequest = id }
        else { closeTerminal(id) }
    }

    func closeTerminal(_ id: UUID) {
        if terminalCloseRequest == id { terminalCloseRequest = nil }
        guard let state = states.first(where: { $0.snapshot.terminalIDs.contains(id) }) else { return }
        state.terminals[id]?.stop(); state.terminals[id] = nil; state.snapshot.terminalIDs.removeAll { $0 == id }
        state.snapshot.layout?.remove(.terminal(id))
        state.snapshot.agentTerminals.removeAll { $0.id == id }
        state.terminalGeneration += 1
        if state.snapshot.selectedTerminalID == id { state.snapshot.selectedTerminalID = state.snapshot.terminalIDs.last }
        schedulePersist()
    }
    func schedulePersist() {
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }; self?.persist()
        }
    }
    var sessionSnapshot: SessionSnapshot {
        SessionSnapshot(hosts: hosts, workspaces: states.map(\.snapshot), selectedWorkspaceID: selectedWorkspaceID, settings: settings)
    }
    func persist() {
        guard persistenceAvailable else { return }
        do {
            let snapshot = sessionSnapshot
            try TextFiles.saveSession(snapshot, to: sessionURL)
            onPersist?(snapshot)
        } catch { report(error) }
    }
    func suspend() {
        fileRefreshPaused = true; persist()
        #if os(iOS)
        foregroundChecks.values.forEach { $0.cancel() }; foregroundChecks.removeAll()
        guard backgroundTime == .invalid else { return }
        backgroundSSH.formUnion(states.filter { $0.snapshot.workspace.isRemote && $0.snapshot.workspace.connection == .connected }.map(\.id))
        guard !backgroundSSH.isEmpty else { return }
        backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Keep SSH connections alive") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTime() }
        }
        backgroundKeepalive = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, fileRefreshPaused else { return }
                for state in states where backgroundSSH.contains(state.id) {
                    guard !Task.isCancelled, let remote = state.remote, remote.isConnected else { continue }
                    _ = try? await remote.revision(".")
                }
            }
        }
        #endif
    }
    func resume() {
        fileRefreshPaused = false; observedFileRevisions.removeAll()
        #if os(iOS)
        endBackgroundTime()
        for state in states where backgroundSSH.contains(state.id) {
            guard let remote = state.remote, remote.isConnected else { recoverBackgroundSSH(state); continue }
            foregroundChecks[state.id]?.cancel()
            foregroundChecks[state.id] = Task { [weak self, weak state] in
                guard let self, let state else { return }
                let timeout = Task { [weak self, weak state] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    guard let self, let state, state.remote === remote else { return }
                    recoverBackgroundSSH(state)
                }
                defer { timeout.cancel() }
                do {
                    try await withTaskCancellationHandler {
                        _ = try await remote.revision(".")
                    } onCancel: { timeout.cancel() }
                    guard !Task.isCancelled, state.remote === remote else { return }
                    backgroundSSH.remove(state.id)
                    foregroundChecks[state.id] = nil
                } catch {
                    guard !Task.isCancelled, state.remote === remote else { return }
                    recoverBackgroundSSH(state)
                }
            }
        }
        #else
        for state in states where state.snapshot.workspace.isRemote {
            if state.remote?.isConnected == false { disconnect(state) }
        }
        #endif
        refreshFiles()
    }
    #if os(iOS)
    private func endBackgroundTime() {
        backgroundKeepalive?.cancel(); backgroundKeepalive = nil
        if backgroundTime != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTime); backgroundTime = .invalid
        }
        // Let iOS suspend the app when its grant expires. Do not close live SSH sockets.
    }
    private func recoverBackgroundSSH(_ state: WorkspaceState) {
        guard !fileRefreshPaused, backgroundSSH.contains(state.id),
              states.contains(where: { $0 === state }),
              case .remote(let hostID, _) = state.snapshot.workspace.kind,
              let host = hosts.first(where: { $0.id == hostID }) else { return }
        disconnect(state)
        connect(host, select: false, workspaceID: state.id)
    }
    #endif
    func shutdown() {
        fileRefreshPaused = true
        #if os(iOS)
        endBackgroundTime()
        foregroundChecks.values.forEach { $0.cancel() }; foregroundChecks.removeAll()
        backgroundSSH.removeAll()
        #endif
        #if os(macOS)
        reverseSSHConnections.values.forEach { $0.stop() }
        sshBridge?.stop(); sshBridge = nil
        #endif
        persistenceTask?.cancel()
        persist()
        for state in states {
            state.explorer.stop()
            state.browsers.values.forEach { $0.close() }; state.browsers.removeAll()
            state.stopTerminals(); state.connectionTask?.cancel()
            let remote = state.remote; Task { await remote?.disconnect() }
            state.accessURL?.stopAccessingSecurityScopedResource()
        }
    }
    func locate(_ id: BufferID) -> (WorkspaceState, Int)? {
        for state in states { if let index = state.snapshot.buffers.firstIndex(where: { $0.id == id }) { return (state, index) } }
        return nil
    }
    func report(_ error: Error) { errorMessage = error.localizedDescription; statusMessage = error.localizedDescription }
}

#if os(macOS)
@MainActor @Observable final class ReverseSSHAccessSettings {
    static let shared = ReverseSSHAccessSettings()
    private let account: String
    private(set) var hasPassword = false

    init(account: String = "reverse-ssh-access-password") { self.account = account }

    func password() throws -> String? {
        guard let data = try SecureStore.data(for: account) else { hasPassword = false; return nil }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw CommandError("Could not read the Reverse SSH password. Set it again in Settings.")
        }
        hasPassword = true
        return value
    }

    func save(_ password: String) throws {
        guard password.count >= 8, password.utf8.count <= 1024,
              !password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
            throw CommandError("Use 8 or more characters on a single line (up to 1,024 bytes).")
        }
        try SecureStore.set(Data(password.utf8), for: account)
        hasPassword = true
        // Applies to every host in every Crow window, including startup in progress.
        ReverseSSHSession.revokeAll()
    }
}
#endif
