import CrowCore
import SwiftUI

struct SidebarTopBar: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.crowFloatingMode) private var floating
    #endif
    // Match the workspace tab header so its divider continues across the window.
    static let height: CGFloat = 36
    // Traffic-light clearance, horizontal padding, and the top-bar controls.
    #if os(macOS)
    static let collapsedWidth: CGFloat = 36 + 24 + 28 * 2 + 8
    #else
    static let collapsedWidth: CGFloat = 52
    #endif

    var body: some View {
        HStack(spacing: 8) {
            if model.sidebarVisible { Spacer(minLength: 0) }
            #if os(macOS)
            Button { floating.wrappedValue = true } label: {
                Image(systemName: "pip.enter").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .help("Float Window").accessibilityLabel("Float Window")
            .accessibilityIdentifier("crow.window.float").windowDragExcluded()
            #endif
            Button { model.sidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .help(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            .accessibilityLabel(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            .accessibilityIdentifier("crow.sidebar-toggle")
            .windowDragExcluded()
            if !model.sidebarVisible { Spacer(minLength: 0) }
        }
        .buttonStyle(CrowButtonStyle())
        .font(.system(size: 14))
        .crowForeground(CrowTheme.textDim)
        .padding(.horizontal, 12)
        #if os(macOS)
        .padding(.leading, 36) // Leave room for the native traffic lights.
        #endif
        .frame(height: Self.height)
        .background(CrowTheme.bg1)
        .windowDragBackground()
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.crowPhoneLayout) private var phoneLayout
    @State private var naming = false
    @State private var entryName = ""
    @State private var renameEntry: FileEntry?
    @State private var moveEntry: ExplorerFileDrag?
    @State private var createDirectory = false
    @State private var creationPath: String?
    @State private var dropFolder: String?
    @FocusState private var searchFocused: Bool

    private var explorer: FileExplorer { model.current.explorer }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.sidebarPane == .files { sidebarHeader }
            #if !os(macOS)
            CrowDivider()
            #endif
            if model.sidebarPane == .workspaces {
                AgentWorkspaceBrowser()
            } else if model.sidebarPane == .automation {
                AutomationPanel()
            } else if model.hasWorkspace {
                filesList
            } else {
                Button("Open Workspaces") { model.showWorkspaces() }.padding(12).windowDragExcluded()
                Spacer()
            }
        }
        .background(CrowTheme.bg1)
        .windowDragBackground()
        .crowForeground(CrowTheme.text)
        .task(id: "\(model.selectedWorkspaceID)-\(explorer.searchVisible)-\(model.fileSearchFocusRequest)") {
            await Task.yield()
            guard !Task.isCancelled else { return }
            searchFocused = explorer.searchVisible
        }
        .task(id: model.selectedWorkspaceID.rawValue.uuidString + model.sidebarPane.rawValue + model.current.snapshot.rootPath) {
            guard model.sidebarPane == .files else { return }
            let tree = explorer
            model.refreshFiles()
            defer { tree.stop() }
            while !Task.isCancelled {
                await tree.refresh()
                tree.refreshSearch()
                do { try await Task.sleep(for: .seconds(model.selectedWorkspace.isRemote ? 5 : 2)) }
                catch { return }
            }
        }
        .sheet(isPresented: Binding(get: { moveEntry != nil }, set: { if !$0 { moveEntry = nil } })) {
            if let entry = moveEntry { FileMovePicker(entry: entry).environment(model) }
        }
        .alert(renameEntry == nil ? (createDirectory ? "New Folder" : "New File") : "Rename", isPresented: $naming) {
            TextField("Name", text: $entryName)
            Button("Save") {
                if let entry = renameEntry { model.rename(entry, to: entryName) }
                else { model.createEntry(name: entryName, directory: createDirectory, in: creationPath) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var sidebarHeader: some View {
        HStack {
            toolbarButton("New File", symbol: "doc.badge.plus") { beginCreate(directory: false) }
            toolbarButton("New Folder", symbol: "folder.badge.plus") { beginCreate(directory: true) }
            Spacer(minLength: 0)
                #if os(macOS)
                .frame(maxHeight: .infinity).overlay { WindowDragRegion() }
                #endif
            toolbarButton("Search Files", symbol: "magnifyingglass") {
                if explorer.searchVisible { explorer.searchVisible = false; explorer.query = "" }
                else { model.focusFileSearch() }
            }.accessibilityIdentifier("crow.sidebar-search")
        }.padding(.horizontal, 12).frame(height: phoneLayout ? 44 : 40)
    }

    private func toolbarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 14)).crowForeground(CrowTheme.textDim)
            .frame(width: phoneLayout ? 44 : 28, height: phoneLayout ? 44 : 28).contentShape(Rectangle())
    }

    private func toolbarButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            toolbarIcon(symbol)
        }
        .buttonStyle(CrowButtonStyle()).help(title).accessibilityLabel(title).disabled(!model.hasWorkspace)
        .windowDragExcluded()
    }

    private func beginCreate(directory: Bool, parent: String? = nil) {
        renameEntry = nil; createDirectory = directory; entryName = ""
        creationPath = parent ?? explorer.creationDirectory
        naming = true
    }

    private var filesList: some View {
        VStack(spacing: 0) {
            if model.selectedWorkspace.isRemote {
                HStack(spacing: 6) {
                    if model.selectedWorkspace.connection == .connecting { ProgressView().controlSize(.mini) }
                    Text(model.selectedWorkspace.connection == .connecting ? "Connecting to remote files…" : explorer.rootPath)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.font(.system(size: 10)).crowForeground(CrowTheme.textDim).padding(.horizontal, 12).padding(.vertical, 5)
            }
            if explorer.searchVisible {
                VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Menu {
                        Button("File names") { selectSearchMode(contents: false) }
                        Button("File contents — contents:") { selectSearchMode(contents: true) }
                    } label: {
                        Text(FileSearchQuery(explorer.query).contents ? "Contents" : "Name")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .menuStyle(.borderlessButton).fixedSize().crowMenuHover()
                    .accessibilityLabel("Search mode").accessibilityIdentifier("crow.search-mode")
                    TextField("File names or contents: text", text: Bindable(explorer).query)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityLabel("Search file names or contents")
                        .accessibilityIdentifier("crow.file-search")
                        .help("Search file names, or use contents: text to search inside files. Press Return to refresh.")
                        .onSubmit { explorer.refreshSearch(force: true) }
                        .onKeyPress(.tab) {
                            guard let completion = FileSearchQuery.prefixCompletion(for: explorer.query) else { return .ignored }
                            explorer.query = completion
                            return .handled
                        }
                    Button { explorer.query = ""; explorer.searchVisible = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(CrowButtonStyle()).help("Close Search")
                }
                .font(.system(size: 12)).padding(8)
                .background(CrowTheme.bg0)
                .windowDragExcluded()
                if searchFocused, let completion = FileSearchQuery.prefixCompletion(for: explorer.query) {
                    Button {
                        explorer.query = completion
                        model.focusFileSearch()
                    } label: {
                        HStack {
                            Text("contents:").font(.system(size: 11, design: .monospaced))
                            Text("Search file contents").font(.system(size: 10)).crowForeground(CrowTheme.textDim)
                            Spacer(minLength: 0)
                            Text("⇥").font(.system(size: 11)).crowForeground(CrowTheme.textDim)
                        }.padding(8).frame(maxWidth: .infinity).contentShape(Rectangle())
                    }.buttonStyle(CrowButtonStyle()).background(CrowTheme.bg2).windowDragExcluded()
                        .accessibilityIdentifier("crow.search-prefix-completion")
                }
                }
            }
            if explorer.isSearching || explorer.loading.contains(explorer.rootPath) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(explorer.isSearching ? "Searching…" : "Loading files…").font(.system(size: 11))
                    Spacer()
                }.padding(8)
            }
        // Native List selection uses the navy accent behind our dark labels.
        // File activation is handled by the row button; use a neutral highlight.
        List(explorer.rows) { row in
            let entry = row.entry
            Button { activate(entry) } label: {
                HStack(spacing: 6) {
                    Image(systemName: entry.isDirectory && explorer.expanded.contains(entry.path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10).opacity(entry.isDirectory ? 1 : 0)
                    Image(systemName: entry.isDirectory ? "folder" : icon(for: entry.name))
                        .font(.system(size: 12))
                        .crowForeground(CrowTheme.textDim)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.system(size: 13)).crowForeground(CrowTheme.text).lineLimit(1)
                        if explorer.searching {
                            Text(explorer.relativePath(entry.path)).font(.system(size: 10))
                                .crowForeground(CrowTheme.textDim).lineLimit(1).truncationMode(.middle)
                            if let match = explorer.contentMatches[entry.path] {
                                Text("\(match.line): \(match.excerpt)").font(.system(size: 11))
                                    .crowForeground(CrowTheme.textDim).lineLimit(2)
                            }
                        }
                    }
                    if explorer.loading.contains(entry.path) { ProgressView().controlSize(.mini) }
                }
                .padding(.leading, CGFloat(row.depth) * 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(CrowButtonStyle())
            #if os(iOS)
            .listRowInsets(EdgeInsets(top: 5, leading: 4, bottom: 5, trailing: 8))
            .listRowSeparator(.hidden)
            #endif
            .overlay { if dropFolder == entry.path { RoundedRectangle(cornerRadius: 4).stroke(CrowTheme.accent, lineWidth: 1).allowsHitTesting(false) } }
            .listRowBackground((explorer.selectedPath ?? model.selectedBuffer?.path) == entry.path ? CrowTheme.fileSelection : Color.clear)
            .accessibilityAddTraits((explorer.selectedPath ?? model.selectedBuffer?.path) == entry.path ? .isSelected : [])
            .accessibilityValue(entry.isDirectory ? (explorer.expanded.contains(entry.path) ? "Expanded" : "Collapsed") : "File")
            .contextMenu {
                if entry.isDirectory {
                    Button("New File…") { beginCreate(directory: false, parent: entry.path) }
                    Button("New Folder…") { beginCreate(directory: true, parent: entry.path) }
                    Divider()
                }
                Button("Rename…") { renameEntry = entry; entryName = entry.name; naming = true }
                Button("Move…", systemImage: "folder") {
                    moveEntry = ExplorerFileDrag(workspaceID: model.selectedWorkspaceID, path: entry.path, isDirectory: entry.isDirectory)
                }
                Button("Copy Path", systemImage: "doc.on.doc") {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.path, forType: .string)
                    #else
                    UIPasteboard.general.string = entry.path
                    #endif
                }
                Button("Delete…", systemImage: "trash", role: .destructive) { model.requestDelete(entry) }
                Divider()
                hiddenFilesToggle
            }
            #if os(macOS)
            .overlay {
                NativeExplorerFileSource(model: model,
                    payload: ExplorerFileDrag(workspaceID: model.selectedWorkspaceID, path: entry.path, isDirectory: entry.isDirectory),
                    onClick: { activate(entry) })
            }
            .windowDragExcluded()
            #endif
        }
        .contextMenu { hiddenFilesToggle }
        #if os(iOS)
        .listStyle(.plain)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        #else
        .listStyle(.sidebar)
        #endif
        .scrollContentBackground(.hidden)
        #if os(macOS)
        .overlay { NativeExplorerFileDrop(model: model, folder: $dropFolder) }
        .overlay(alignment: .bottom) {
            if dropFolder == explorer.rootPath {
                Text("Move to workspace root").font(.system(size: 11)).padding(8)
                    .background(CrowTheme.bg1).allowsHitTesting(false)
            }
        }
        .onChange(of: model.draggedFile) { _, drag in if drag == nil { dropFolder = nil } }
        #endif
        .overlay {
            if explorer.rows.isEmpty && !explorer.isSearching && explorer.errorMessage == nil && model.selectedWorkspace.connection != .connecting {
                if explorer.loading.contains(explorer.rootPath) || explorer.children[explorer.rootPath] == nil {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: 10) {
                        Text(explorer.searching ? "No matching files" : "No visible files in this folder")
                            .font(.system(size: 12))
                        Text(explorer.rootPath).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).multilineTextAlignment(.center)
                            .windowDragExcluded()
                    }.crowForeground(CrowTheme.textDim).padding(16)
                }
            }
        }
        if let message = explorer.errorMessage ?? explorer.limitMessage {
            Text(message).font(.system(size: 11)).crowForeground(CrowTheme.textDim).padding(8)
            if explorer.errorMessage != nil, model.selectedWorkspace.isRemote, model.selectedWorkspace.connection != .connecting {
                Button("Retry File Connection") { model.retryRemoteFiles() }.padding(.bottom, 8).windowDragExcluded()
            }
        }
        }
    }

    private var hiddenFilesToggle: some View {
        Toggle("Show Hidden Files", isOn: Bindable(model).showHiddenFiles)
            .accessibilityIdentifier("crow.files.show-hidden")
    }

    private func activate(_ entry: FileEntry) {
        let tree = explorer
        tree.selectedPath = entry.path
        if entry.isDirectory {
            if tree.searching {
                tree.query = ""; tree.searchVisible = false
                Task { await tree.reveal(entry) }
            } else { Task { await tree.toggle(entry) } }
        } else { model.openFile(entry) }
    }

    private func selectSearchMode(contents: Bool) {
        explorer.query = FileSearchQuery(explorer.query).switchingToContents(contents)
        model.focusFileSearch()
    }

    private func icon(for name: String) -> String {
        if ImagePreview.supports(name) { return "photo" }
        switch LanguageMode.infer(filename: name) {
        case .markdown: return "doc.richtext"
        case .json, .yaml, .toml, .ini: return "curlybraces"
        case .shell: return "terminal"
        default: return "doc.plaintext"
        }
    }
}

extension ConnectionState {
    var hostStatusText: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .failed: "Connection failed"
        case .disconnected, .local: "Disconnected"
        }
    }
}

struct HostConnectionButton: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost

    private var connection: ConnectionState { model.connectionState(for: host) }
    private var status: String { connection.hostStatusText }
    private var symbol: String {
        switch connection {
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        default: "circle"
        }
    }
    private var color: Color {
        switch connection {
        case .connected: CrowTheme.ok
        case .failed: CrowTheme.danger
        default: CrowTheme.textDim
        }
    }

    var body: some View {
        Button {
            if connection == .connected { model.disconnect(host) }
            else { model.connect(host) }
        } label: {
            Group {
                if connection == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(color)
                }
            }
            #if os(iOS)
            .frame(width: 44, height: 44)
            #else
            .frame(width: 32, height: 32)
            #endif
            .contentShape(Rectangle())
        }
        .buttonStyle(CrowButtonStyle())
        .disabled(connection == .connecting)
        .help(connection == .connecting ? status : "\(status) — click to \(connection == .connected ? "disconnect" : "connect")")
        .accessibilityLabel("\(connection == .connected ? "Disconnect" : "Connect") \(host.name)")
        .accessibilityValue(status)
        .accessibilityIdentifier("crow.host-connection.\(host.id.rawValue.uuidString)")
    }
}

#if os(macOS)
struct ReverseSSHHostButton: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost
    private var session: ReverseSSHSession? { model.reverseSSHConnections[host.id] }
    private var enabled: Bool { session?.isEnabled == true }
    private var preparing: Bool { enabled && session?.connectCommand == nil }

    var body: some View {
        Button { model.setReverseSSH(!enabled, for: host) } label: {
            Group {
                if preparing { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: enabled ? "arrow.uturn.backward.circle.fill" : "arrow.uturn.backward.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(enabled ? CrowTheme.ok : CrowTheme.textDim)
                }
            }.frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(CrowButtonStyle()).windowDragExcluded()
            .help("Reverse SSH · " + (session?.status ?? "Off") + " — " + (enabled ? "click to turn off" : "turn on and copy access command"))
            .accessibilityLabel((enabled ? "Disable Reverse SSH for " : "Enable Reverse SSH and copy command for ") + host.userAtHost)
            .accessibilityValue(session?.status ?? "Off")
            .accessibilityIdentifier("crow.reverse-ssh.\(host.id)")
    }
}

#endif

struct RemoteProjectFolderPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspaceID: WorkspaceID
    let initialPath: String
    @State private var path = ""
    @State private var loadedPath: String?
    @State private var folders: [FileEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var request: Task<Void, Never>?
    @State private var choosingTerminal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open SSH Workspace").font(.headline)
            Text("Open a folder as a separate workspace on this SSH host.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { browse("~") } label: { Image(systemName: "house") }.help("Remote Home")
                Button {
                    if let loadedPath { browse((loadedPath as NSString).deletingLastPathComponent) }
                } label: { Image(systemName: "arrow.up") }.help("Parent Folder").disabled(loadedPath == nil || loadedPath == "/")
                TextField("Remote folder path", text: $path).textFieldStyle(.roundedBorder).onSubmit { browse(path) }
                Button("Go") { browse(path) }
            }
            Button { choosingTerminal = true } label: { Label("From Terminal…", systemImage: "terminal") }
                .accessibilityIdentifier("crow.project.from-terminal")
            List(folders) { folder in
                Button { browse(folder.path) } label: {
                    Label(folder.name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(CrowButtonStyle())
            }
            .overlay {
                if loading { ProgressView() }
                else if folders.isEmpty && error == nil { Text("No subfolders").foregroundStyle(.secondary) }
            }
            if let error { Text(error).font(.caption).crowForeground(CrowTheme.danger).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open Workspace") {
                    guard let loadedPath else { return }
                    loading = true; error = nil
                    request = Task {
                        do { try await model.openRemoteWorkspace(loadedPath, from: workspaceID); dismiss() }
                        catch is CancellationError {} catch { self.error = error.localizedDescription }
                        loading = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(loading || loadedPath == nil || path != loadedPath)
            }
        }
        .padding(20).frame(minWidth: 380, idealWidth: 520, minHeight: 360, idealHeight: 440)
        .onAppear { browse(initialPath) }
        .onDisappear { request?.cancel() }
        .sheet(isPresented: $choosingTerminal) {
            NavigationStack {
                List {
                    ForEach(model.remoteTerminals(in: workspaceID)) { terminal in
                        Button {
                            guard terminal.running, let directory = terminal.currentDirectory else { return }
                            choosingTerminal = false; browse(directory)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(terminal.title, systemImage: "terminal")
                                Text(terminal.currentDirectory ?? "Waiting for the shell to report its folder")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(terminal.currentDirectory == nil)
                        .accessibilityIdentifier("crow.project.terminal.\(terminal.id)")
                    }
                }
                .overlay {
                    if model.remoteTerminals(in: workspaceID).isEmpty { Text("No open terminals for this SSH host").foregroundStyle(.secondary).padding() }
                }
                .navigationTitle("Choose Terminal")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingTerminal = false } } }
            }
            .frame(minWidth: 320, minHeight: 280)
        }
    }
    private func browse(_ requested: String) {
        request?.cancel(); loading = true; error = nil; folders = []; loadedPath = nil; path = requested
        request = Task {
            do {
                let result = try await model.remoteDirectory(in: workspaceID, at: requested)
                try Task.checkCancellation()
                path = result.path; loadedPath = result.path; folders = result.folders; loading = false
            } catch is CancellationError {} catch {
                if !Task.isCancelled { self.error = error.localizedDescription; loading = false }
            }
        }
    }
}

#if os(macOS)
import AppKit

private struct NativeExplorerFileSource: NSViewRepresentable {
    let model: AppModel
    let payload: ExplorerFileDrag
    let onClick: () -> Void
    func makeNSView(context: Context) -> WorkspaceTabDragView { WorkspaceTabDragView() }
    func updateNSView(_ view: WorkspaceTabDragView, context: Context) {
        view.model = model; view.filePayload = payload; view.payload = nil
        view.title = payload.name; view.onClick = onClick
    }
}

private struct NativeExplorerFileDrop: NSViewRepresentable {
    let model: AppModel
    @Binding var folder: String?
    func makeNSView(context: Context) -> ExplorerFileDropView { ExplorerFileDropView() }
    func updateNSView(_ view: ExplorerFileDropView, context: Context) {
        view.model = model; view.isHidden = model.draggedFile == nil
        view.highlight = { folder = $0 }
        if model.draggedFile == nil { view.cancelHover() }
    }
}

final class ExplorerFileDropView: NSView {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.chajinwoo.crow.explorer-file")
    weak var model: AppModel?
    var highlight: (String?) -> Void = { _ in }
    private var hoverTask: Task<Void, Never>?
    private var hoverPath: String?
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); registerForDraggedTypes([Self.pasteboardType])
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        model?.draggedFile == nil ? nil : super.hitTest(point)
    }
    func payload(from pasteboard: NSPasteboard) -> ExplorerFileDrag? {
        guard let data = pasteboard.data(forType: Self.pasteboardType),
              let drag = try? JSONDecoder().decode(ExplorerFileDrag.self, from: data),
              drag == model?.draggedFile, drag.workspaceID == model?.selectedWorkspaceID else { return nil }
        return drag
    }
    private func fileSources() -> [WorkspaceTabDragView] {
        func sources(_ view: NSView) -> [WorkspaceTabDragView] {
            if let source = view as? WorkspaceTabDragView { return [source] }
            return view.subviews.flatMap(sources)
        }
        return window?.contentView.map(sources)?.filter { $0.filePayload?.workspaceID == model?.selectedWorkspaceID } ?? []
    }
    func destination(at point: NSPoint) -> String? {
        guard let model else { return nil }
        let row = fileSources().first {
            !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.visibleRect.intersection($0.bounds), to: self).contains(point)
        }?.filePayload
        return row.map { $0.isDirectory ? $0.path : ($0.path as NSString).deletingLastPathComponent }
            ?? model.current.explorer.rootPath
    }
    func cancelHover() { hoverTask?.cancel(); hoverTask = nil; hoverPath = nil }
    private func scrollNearEdge(_ point: NSPoint) {
        let delta: CGFloat = point.y < 24 ? -12 : point.y > bounds.height - 24 ? 12 : 0
        guard delta != 0, let scroll = fileSources().first?.enclosingScrollView,
              let document = scroll.documentView else { return }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.y = min(max(0, origin.y + delta), max(0, document.bounds.height - clip.bounds.height))
        clip.scroll(to: origin); scroll.reflectScrolledClipView(clip)
    }
    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        if payload(from: sender.draggingPasteboard) != nil { scrollNearEdge(convert(sender.draggingLocation, from: nil)) }
        guard let drag = payload(from: sender.draggingPasteboard), let model,
              let folder = destination(at: convert(sender.draggingLocation, from: nil)),
              model.canMoveFile(drag, to: folder) else { highlight(nil); cancelHover(); return [] }
        highlight(folder)
        if hoverPath != folder {
            cancelHover(); hoverPath = folder
            let tree = model.current.explorer
            if folder != tree.rootPath && !tree.expanded.contains(folder) {
                hoverTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                    guard self?.hoverPath == folder, model.draggedFile == drag, !tree.expanded.contains(folder) else { return }
                    await tree.toggle(.init(name: (folder as NSString).lastPathComponent, path: folder, isDirectory: true))
                }
            }
        }
        return .move
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight(nil); cancelHover() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { update(sender) == .move }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { highlight(nil); cancelHover() }
        guard let drag = payload(from: sender.draggingPasteboard), let model,
              let folder = destination(at: convert(sender.draggingLocation, from: nil)),
              model.canMoveFile(drag, to: folder) else { return false }
        model.moveFile(drag, to: folder)
        return true
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlight(nil); cancelHover() }
}
#endif
