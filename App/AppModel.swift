import CrowCore
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class AppModel {
    var hosts: [SSHHost] = []
    var states: [WorkspaceState] = []
    var selectedWorkspaceID: WorkspaceID
    var settings = EditorSettings() { didSet { schedulePersist() } }
    var sidebarPane: SidebarPane = .files
    var compactSurface: CompactSurface = .editor
    var imeProbe: IMEProbe = .empty
    var statusMessage = "Ready"
    var errorMessage: String?
    var closeRequest: BufferID?
    var conflictRequest: BufferID?
    var deleteRequest: FileEntry?
    var hostKeyChallenge: HostKeyChallenge?
    var folderImporterVisible = false
    var hostEditorVisible = false
    var editingHost: SSHHost?
    var settingsVisible = false
    let vaultURL: URL
    let sessionURL: URL
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var saving: Set<BufferID> = []
    @ObservationIgnored private var persistenceAvailable = true

    init(vaultURL: URL? = nil, sessionURL: URL? = nil) {
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
        let local = Workspace(name: "Vault", kind: .local, connection: .local)
        selectedWorkspaceID = local.id
        do {
            try FileManager.default.createDirectory(at: self.vaultURL, withIntermediateDirectories: true)
            let readme = self.vaultURL.appendingPathComponent("README.md")
            if !FileManager.default.fileExists(atPath: readme.path) {
                try Data("# Crow\n\nOpen a folder to work on your own files, or add an SSH host.\n".utf8)
                    .write(to: readme, options: .withoutOverwriting)
            }
            if FileManager.default.fileExists(atPath: self.sessionURL.path) {
                let saved = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: self.sessionURL))
                guard saved.version == 1, !saved.workspaces.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                hosts = saved.hosts; settings = saved.settings
                states = saved.workspaces.map { snapshot in
                    var restored = snapshot
                    if restored.workspace.isRemote { restored.workspace.connection = .disconnected }
                    else if restored.bookmark == nil {
                        // iOS can change the app container UUID after an update.
                        // Built-in vault paths must follow the current container.
                        restored.relocateRoot(to: self.vaultURL.path)
                    }
                    return WorkspaceState(restored)
                }
                selectedWorkspaceID = states.contains(where: { $0.id == saved.selectedWorkspaceID }) ? saved.selectedWorkspaceID : states[0].id
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
        if states.isEmpty {
            states = [WorkspaceState(.init(workspace: local, rootPath: self.vaultURL.path)),
                WorkspaceState(.init(workspace: Workspace(name: "IME Lab", kind: .imeLab, connection: .local), rootPath: self.vaultURL.path))]
            let readme = self.vaultURL.appendingPathComponent("README.md")
            if let text = try? TextFiles.read(readme) { addBuffer(path: readme.path, text: text, to: states[0]) }
        }
        refreshFiles()
    }

    var current: WorkspaceState { states.first(where: { $0.id == selectedWorkspaceID }) ?? states[0] }
    var workspaces: [Workspace] { states.map(\.snapshot.workspace) }
    var selectedWorkspace: Workspace { current.snapshot.workspace }
    var workspaceTitle: String { selectedWorkspace.name }
    var files: [FileEntry] { current.files }
    var buffers: [OpenBuffer] { current.snapshot.buffers }
    var selectedBufferID: BufferID? {
        get { current.snapshot.selectedBufferID }
        set { current.snapshot.selectedBufferID = newValue; schedulePersist() }
    }
    var selectedBuffer: OpenBuffer? { buffers.first { $0.id == selectedBufferID } }
    var sidebarVisible: Bool {
        get { settings.sidebarVisible }
        set { settings.sidebarVisible = newValue }
    }
    var terminalVisible: Bool {
        get { settings.terminalVisible }
        set { settings.terminalVisible = newValue }
    }
    var hasUnsavedChanges: Bool { states.contains { $0.snapshot.buffers.contains(where: \.isDirty) } }

    func selectWorkspace(_ id: WorkspaceID) {
        selectedWorkspaceID = id; refreshFiles()
        if case .imeLab = selectedWorkspace.kind { compactSurface = .terminal; terminalVisible = true }
        statusMessage = workspaceTitle; schedulePersist()
    }

    func openFolder(_ url: URL) {
        let path = url.resolvingSymlinksInPath().path
        if let existing = states.first(where: { !$0.snapshot.workspace.isRemote && $0.snapshot.rootPath == path }) {
            selectWorkspace(existing.id); return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        do {
            var options: URL.BookmarkCreationOptions = []
            #if os(macOS)
            options = .withSecurityScope
            #endif
            let bookmark = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            let state = WorkspaceState(.init(workspace: Workspace(name: url.lastPathComponent, kind: .local, connection: .local),
                rootPath: path, bookmark: bookmark))
            if accessed { state.accessURL = url }
            states.append(state); selectWorkspace(state.id)
        } catch { if accessed { url.stopAccessingSecurityScopedResource() }; report(error) }
    }

    private func restoreAccess(_ state: WorkspaceState) {
        guard let bookmark = state.snapshot.bookmark else { return }
        do {
            var stale = false
            var options: URL.BookmarkResolutionOptions = []
            #if os(macOS)
            options = .withSecurityScope
            #endif
            let url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            if url.startAccessingSecurityScopedResource() { state.accessURL = url }
            state.snapshot.relocateRoot(to: url.resolvingSymlinksInPath().path)
            if stale { statusMessage = "Reopen \(state.snapshot.workspace.name) if folder access fails." }
        } catch { report(error) }
    }

    func navigate(to path: String) {
        current.snapshot.directoryPath = selectedWorkspace.isRemote ? path : URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        refreshFiles(); schedulePersist()
    }
    func navigateUp() {
        guard current.snapshot.directoryPath != current.snapshot.rootPath else { return }
        navigate(to: (current.snapshot.directoryPath as NSString).deletingLastPathComponent)
    }

    func refreshFiles() {
        let state = current, path = current.snapshot.directoryPath
        let generation = UUID(); state.refreshGeneration = generation
        if !state.snapshot.workspace.isRemote {
            do {
                state.files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                    includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    .map { FileEntry(name: $0.lastPathComponent,
                        path: $0.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent($0.lastPathComponent).path,
                        isDirectory: (try $0.resourceValues(forKeys: [.isDirectoryKey])).isDirectory ?? false) }
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
                if state.refreshGeneration == generation { state.files = entries.filter { !$0.name.hasPrefix(".") } }
            } catch { report(error) }
        }
    }

    func openFile(_ entry: FileEntry) {
        if entry.isDirectory { navigate(to: entry.path); return }
        let state = current
        if let existing = state.snapshot.buffers.first(where: { $0.path == entry.path }) {
            state.snapshot.selectedBufferID = existing.id; compactSurface = .editor; return
        }
        if !state.snapshot.workspace.isRemote {
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

    private func addBuffer(path: String, text: String, to state: WorkspaceState) {
        if let existing = state.snapshot.buffers.first(where: { $0.path == path }) {
            state.snapshot.selectedBufferID = existing.id; return
        }
        var buffer = OpenBuffer(title: (path as NSString).lastPathComponent, path: path, text: text,
            language: LanguageMode.infer(filename: path), isRemote: state.snapshot.workspace.isRemote)
        buffer.savedText = text
        state.snapshot.buffers.append(buffer); state.snapshot.selectedBufferID = buffer.id; schedulePersist()
    }

    func updateBufferText(_ id: BufferID, _ text: String) {
        guard let (state, index) = locate(id) else { return }
        state.snapshot.buffers[index].text = text
        state.snapshot.buffers[index].isDirty = text != state.snapshot.buffers[index].savedText
        schedulePersist()
    }
    func saveSelectedBuffer() { if let id = selectedBufferID { Task { _ = await saveBuffer(id) } } }

    @discardableResult func saveBuffer(_ id: BufferID, overwrite: Bool = false) async -> Bool {
        guard let (state, index) = locate(id), !saving.contains(id) else { return false }
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
        if state.snapshot.selectedBufferID == id { state.snapshot.selectedBufferID = state.snapshot.buffers.last?.id }
        if state.snapshot.splitBufferID == id { state.snapshot.splitBufferID = nil }
        schedulePersist()
    }
    func toggleSplit() {
        current.snapshot.splitBufferID = current.snapshot.splitBufferID == nil ? selectedBufferID : nil; schedulePersist()
    }
    func newUntitledBuffer() { createEntry(name: "untitled-\(UUID().uuidString.prefix(6)).txt", directory: false) }
    @discardableResult func createEntry(name: String, directory: Bool) -> Task<Void, Never> {
        let state = current
        return Task {
            do {
                try TextFiles.validateName(name)
                let path = (state.snapshot.directoryPath as NSString).appendingPathComponent(name)
                if state.snapshot.workspace.isRemote {
                    guard let remote = state.remote else { throw FileFailure.disconnected }
                    try await remote.create(path, directory: directory)
                } else if directory { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) }
                else { try Data().write(to: URL(fileURLWithPath: path), options: .withoutOverwriting) }
                if !directory { addBuffer(path: path, text: "", to: state) }
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
    @discardableResult func trash(_ entry: FileEntry) -> Task<Void, Never> {
        let state = current
        return Task {
            do {
                let affected = state.snapshot.buffers.filter { $0.path == entry.path || $0.path.hasPrefix(entry.path + "/") }
                guard !affected.contains(where: \.isDirty) else {
                    errorMessage = "Save or close the modified files inside this item before deleting it."; return
                }
                let recovery: String
                if state.snapshot.workspace.isRemote {
                    guard let remote = state.remote else { throw FileFailure.disconnected }
                    recovery = try await remote.trash(entry)
                } else {
                    let folder = URL(fileURLWithPath: state.snapshot.rootPath).appendingPathComponent(".crow-trash", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let target = folder.appendingPathComponent(UUID().uuidString + "-" + entry.name)
                    try FileManager.default.moveItem(atPath: entry.path, toPath: target.path); recovery = target.path
                }
                affected.forEach { discardBuffer($0.id) }; statusMessage = "Moved to \(recovery)"
                if state.id == selectedWorkspaceID { refreshFiles() }; schedulePersist()
            } catch { report(error) }
        }
    }

    func editHost(_ host: SSHHost? = nil) { editingHost = host; hostEditorVisible = true }
    func storeHost(_ host: SSHHost, credential: HostCredential) throws {
        guard !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty, !host.username.isEmpty, (1...65535).contains(host.port) else {
            throw NSError(domain: "Crow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a host, username and port between 1 and 65535."])
        }
        try SecureStore.set(JSONEncoder().encode(credential), for: host.id.rawValue.uuidString)
        if let index = hosts.firstIndex(where: { $0.id == host.id }) { hosts[index] = host } else { hosts.append(host) }
        schedulePersist()
    }
    func removeHost(_ host: SSHHost) {
        do {
            try SecureStore.remove(host.id.rawValue.uuidString); hosts.removeAll { $0.id == host.id }
            for state in states {
                if case .remote(let id, _) = state.snapshot.workspace.kind, id == host.id { disconnect(state) }
            }
            schedulePersist()
        } catch { report(error) }
    }
    func connect(_ host: SSHHost) {
        let state: WorkspaceState
        if let existing = states.first(where: {
            if case .remote(let id, _) = $0.snapshot.workspace.kind { return id == host.id }; return false
        }) { state = existing }
        else {
            state = WorkspaceState(.init(workspace: Workspace(name: host.name,
                kind: .remote(hostID: host.id, path: host.remotePath), connection: .disconnected), rootPath: host.remotePath))
            states.append(state)
        }
        selectWorkspace(state.id)
        if state.snapshot.workspace.connection == .connected || state.snapshot.workspace.connection == .connecting { return }
        state.snapshot.workspace.name = host.name; state.snapshot.workspace.connection = .connecting
        let connection = RemoteConnection(); state.remote = connection
        state.connectionTask = Task {
            do {
                try await connection.connect(host, credential: SecureStore.credential(host)); try Task.checkCancellation()
                connection.client?.onDisconnect { [weak self, weak state] in
                    Task { @MainActor in
                        guard let state, state.remote === connection else { return }
                        state.snapshot.workspace.connection = .disconnected; state.stopTerminals()
                        self?.statusMessage = "Connection closed — reconnect to start a new shell."
                    }
                }
                let root = try await connection.realPath(host.remotePath)
                try Task.checkCancellation()
                guard state.remote === connection else { await connection.disconnect(); return }
                state.snapshot.rootPath = root; state.snapshot.directoryPath = root
                state.stopTerminals(); state.snapshot.workspace.connection = .connected
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
        disconnect(current); connect(host)
    }
    func disconnectCurrent() { disconnect(current) }
    private func disconnect(_ state: WorkspaceState) {
        state.connectionTask?.cancel(); state.connectionTask = nil
        let connection = state.remote; state.remote = nil; state.stopTerminals()
        state.snapshot.workspace.connection = .disconnected
        Task { await connection?.disconnect() }
    }
    func terminal(_ id: UUID, in state: WorkspaceState) -> TerminalSession {
        if let existing = state.terminals[id] { return existing }
        let session = TerminalSession(id: id, workspace: state.snapshot.workspace, directory: state.snapshot.rootPath,
            remote: state.remote, fontSize: settings.terminalFontSize)
        session.onBytes = { [weak self] bytes in self?.recordPTY(bytes[...]) }; state.terminals[id] = session
        return session
    }
    func newTerminal() {
        let id = UUID(); current.snapshot.terminalIDs.append(id); current.snapshot.selectedTerminalID = id
        terminalVisible = true; schedulePersist()
    }
    func closeTerminal(_ id: UUID) {
        current.terminals[id]?.stop(); current.terminals[id] = nil; current.snapshot.terminalIDs.removeAll { $0 == id }
        if current.snapshot.selectedTerminalID == id { current.snapshot.selectedTerminalID = current.snapshot.terminalIDs.last }
        schedulePersist()
    }
    func recordPTY(_ bytes: ArraySlice<UInt8>) { imeProbe = IMEProbe.from(bytes: bytes) }
    func schedulePersist() {
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }; self?.persist()
        }
    }
    func persist() {
        guard !states.isEmpty, persistenceAvailable else { return }
        do { try TextFiles.saveSession(.init(hosts: hosts, workspaces: states.map(\.snapshot),
            selectedWorkspaceID: selectedWorkspaceID, settings: settings), to: sessionURL) }
        catch { report(error) }
    }
    func suspend() { persist() }
    func resume() {
        refreshFiles()
        for state in states where state.snapshot.workspace.isRemote {
            if state.remote?.client?.isConnected == false { disconnect(state) }
        }
    }
    func shutdown() {
        persistenceTask?.cancel()
        persist()
        for state in states {
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
