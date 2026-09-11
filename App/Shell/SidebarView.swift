import CrowCore
import SwiftUI

#if os(macOS)
struct SidebarTopBar: View {
    @Environment(AppModel.self) private var model
    // Match the workspace tab header so its divider continues across the window.
    static let height: CGFloat = 36
    // Traffic-light clearance, horizontal padding, and the reopen button.
    static let collapsedWidth: CGFloat = 36 + 24 + 28

    var body: some View {
        HStack(spacing: 8) {
            if model.sidebarVisible { Spacer(minLength: 0) }
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
        .padding(.leading, 36) // Leave room for the native traffic lights.
        .frame(height: Self.height)
        .background(CrowTheme.bg1)
        .windowDragBackground()
    }
}
#endif

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.crowPhoneLayout) private var phoneLayout
    @State private var naming = false
    @State private var entryName = ""
    @State private var renameEntry: FileEntry?
    @State private var createDirectory = false
    @State private var removeHost: SSHHost?
    @State private var creationPath: String?
    @State private var dropFolder: String?
    @State private var choosingProject = false
    @FocusState private var searchFocused: Bool

    private var explorer: FileExplorer { model.current.explorer }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            #if !os(macOS)
            CrowDivider()
            #endif
            if model.sidebarPane == .hosts {
                hostsList
            } else if model.hasWorkspace {
                filesList
            } else {
                Button("Open Folder…") { model.folderImporterVisible = true }.padding(12).windowDragExcluded()
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
        .sheet(isPresented: $choosingProject) {
            RemoteProjectFolderPicker(workspaceID: model.selectedWorkspaceID, initialPath: model.current.snapshot.rootPath)
                .environment(model)
        }
        .alert(renameEntry == nil ? (createDirectory ? "New Folder" : "New File") : "Rename", isPresented: $naming) {
            TextField("Name", text: $entryName)
            Button("Save") {
                if let entry = renameEntry { model.rename(entry, to: entryName) }
                else { model.createEntry(name: entryName, directory: createDirectory, in: creationPath) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Remove SSH host?", isPresented: Binding(get: { removeHost != nil }, set: { if !$0 { removeHost = nil } }), presenting: removeHost) { host in
            Button("Remove", role: .destructive) { model.removeHost(host) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("The saved credentials will be removed from this device. Server files will not be changed.") }
    }

    private var sidebarHeader: some View {
        HStack {
            if model.sidebarPane == .hosts {
                Text("HOSTS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .crowForeground(CrowTheme.textDim)
            }
            if model.sidebarPane == .files {
                toolbarButton("New File", symbol: "doc.badge.plus") { beginCreate(directory: false) }
                toolbarButton("New Folder", symbol: "folder.badge.plus") { beginCreate(directory: true) }
                #if os(iOS)
                Button {
                    if model.hasWorkspace && model.selectedWorkspace.isRemote { choosingProject = true }
                    else { model.folderImporterVisible = true }
                } label: { toolbarIcon("folder") }
                    .buttonStyle(CrowButtonStyle()).accessibilityLabel("Choose Folder")
                    .accessibilityIdentifier("crow.files.choose-folder")
                    .disabled(model.selectedWorkspace.connection == .connecting)
                #else
                if model.hasWorkspace && model.selectedWorkspace.isRemote {
                    toolbarButton("Choose Remote Project Folder", symbol: "folder") { choosingProject = true }
                        .disabled(model.selectedWorkspace.connection == .connecting)
                }
                #endif
                Spacer(minLength: 0)
                    #if os(macOS)
                    .frame(maxHeight: .infinity).overlay { WindowDragRegion() }
                    #endif
                toolbarButton("Search Files", symbol: "magnifyingglass") {
                    if explorer.searchVisible { explorer.searchVisible = false; explorer.query = "" }
                    else { model.focusFileSearch() }
                }
                .accessibilityIdentifier("crow.sidebar-search")
            } else {
                Spacer()
                    #if os(macOS)
                    .frame(maxHeight: .infinity).overlay { WindowDragRegion() }
                    #endif
                #if os(iOS)
                Button { model.sshCommandVisible = true } label: { toolbarIcon("plus") }
                    .buttonStyle(CrowButtonStyle()).accessibilityLabel("Add SSH Host")
                    .accessibilityIdentifier("crow.host.add")
                Button { model.folderImporterVisible = true } label: { toolbarIcon("folder.badge.plus") }
                    .buttonStyle(CrowButtonStyle()).accessibilityLabel("Open Folder")
                    .accessibilityIdentifier("crow.host.open-folder")
                Button { model.settingsVisible = true } label: { toolbarIcon("gearshape") }
                    .buttonStyle(CrowButtonStyle()).accessibilityLabel("Settings")
                #else
                Button { model.sshCommandVisible = true } label: { Image(systemName: "plus") }.buttonStyle(CrowButtonStyle()).help("SSH Command").windowDragExcluded()
                #endif
            }
        }
        .padding(.horizontal, 12)
        .frame(height: phoneLayout ? 44 : 40)
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
                Button("Move to Recovery Folder…", role: .destructive) { model.deleteRequest = entry }
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
                Text("Move to vault root").font(.system(size: 11)).padding(8)
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
                        if model.selectedWorkspace.isRemote && !explorer.searching {
                            Text("The file browser folder is independent of the terminal's current directory. Hidden files are not shown.")
                                .font(.system(size: 11)).multilineTextAlignment(.center)
                            Button("Choose Project Folder…") { choosingProject = true }
                                .accessibilityIdentifier("crow.empty-choose-project")
                                .windowDragExcluded()
                        }
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

    private var hostsList: some View {
        List {
            #if os(iOS)
            if !model.localWorkspaces.isEmpty {
                Section("Workspaces") {
                    ForEach(model.localWorkspaces) { workspace in
                        HStack(spacing: 8) {
                            Button {
                                model.selectWorkspace(workspace.id, showFiles: false)
                                model.compactSurface = .files
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .crowForeground(CrowTheme.textDim)
                                    Text(workspace.name).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if workspace.id == model.selectedWorkspaceID { Image(systemName: "checkmark") }
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(CrowButtonStyle())
                            Menu {
                                Button("New Terminal", systemImage: "terminal") { model.newTerminal(inWorkspace: workspace.id) }
                                Button("Remove Workspace…", systemImage: "trash", role: .destructive) { model.requestWorkspaceRemoval(workspace.id) }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                                .buttonStyle(CrowButtonStyle()).accessibilityLabel("Options for \(workspace.name)")
                        }.listRowBackground(Color.clear)
                    }
                }
            }
            Section("SSH Hosts") {
                if model.hosts.isEmpty {
                    Text("Use + to add an SSH host.").font(.caption).crowForeground(CrowTheme.textDim)
                        .listRowBackground(Color.clear)
                }
                hostRows
            }
            #else
            hostRows
            #endif
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("crow.hosts.workspaces")
        .safeAreaInset(edge: .bottom) {
            #if os(iOS)
            if !model.hosts.isEmpty {
                Text("Tap a host to connect. Use its status icon to connect or disconnect.")
                    .font(.caption).foregroundStyle(CrowTheme.textDim).padding(12)
            }
            #else
            Text(model.hosts.isEmpty ? "Run ssh user@host in the Mac terminal, or enter an SSH command with +." : "Click a host to reconnect. Click its status icon to connect or disconnect.")
                .font(.system(size: 11)).crowForeground(CrowTheme.textDim).padding(12)
            #endif
        }
    }

    private var hostRows: some View {
        ForEach(model.hosts) { (host: SSHHost) in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button {
                        model.connect(host)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(host.name)
                                #if os(iOS)
                                .font(.body.weight(.medium))
                                #else
                                .font(.system(size: 13, weight: .medium))
                                #endif
                            Text("\(host.userAtHost):\(host.port)")
                                #if os(iOS)
                                .font(.system(.caption, design: .monospaced))
                                #else
                                .font(.system(size: 11, design: .monospaced))
                                #endif
                                .crowForeground(CrowTheme.textDim)
                            #if os(iOS)
                            HStack(spacing: 8) {
                                Label(host.authentication == .password ? "Password" : (host.authentication == .ed25519 ? "Ed25519 key" : "RSA key"),
                                    systemImage: host.authentication == .password ? "lock" : "key")
                                Text(model.connectionState(for: host).hostStatusText)
                            }
                            .font(.caption).foregroundStyle(CrowTheme.textDim)
                            #endif
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CrowButtonStyle())
                    HostConnectionButton(host: host)
                    #if os(iOS)
                    Menu {
                        Button("Edit Host…", systemImage: "pencil") { model.editHost(host) }
                        Button("Remove Host…", systemImage: "trash", role: .destructive) { removeHost = host }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Options for \(host.name)")
                    .buttonStyle(.plain)
                    #endif
                }
                .contextMenu {
                    Button("Connect") { model.connect(host) }
                    if model.connectionState(for: host) == .connected {
                        Button("Disconnect") { model.disconnect(host) }
                    }
                    Button("Edit Host…") { model.editHost(host) }
                    Button("Remove Host…", role: .destructive) { removeHost = host }
                }
                #if os(macOS)
                ReverseSSHHostToggle(host: host)
                #endif
            }
            .listRowBackground(Color.clear)
            .windowDragExcluded()
        }
    }

    private func icon(for name: String) -> String {
        switch LanguageMode.infer(filename: name) {
        case .markdown: return "doc.richtext"
        case .json, .yaml, .toml, .ini: return "curlybraces"
        case .shell: return "terminal"
        default: return "doc.plaintext"
        }
    }
}

private extension ConnectionState {
    var hostStatusText: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .failed: "Connection failed"
        case .disconnected, .local: "Disconnected"
        }
    }
}

private struct HostConnectionButton: View {
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
private struct ReverseSSHHostToggle: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost
    private var session: ReverseSSHSession? { model.reverseSSHConnections[host.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Reverse SSH", isOn: Binding(
                get: { session?.isEnabled ?? false },
                set: { model.setReverseSSH($0, for: host) }))
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 11))
                .help("Allow this server's agents to run commands and edit files on this Mac as your account. Off disconnects their sessions.")
                .accessibilityIdentifier("crow.reverse-ssh.\(host.id)")
            if let session {
                if let command = session.connectCommand {
                    CopyClientCommandButton(command: command)
                } else if session.status != "Off" {
                    Text(session.status).font(.system(size: 10)).crowForeground(CrowTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.bottom, 5)
        .windowDragExcluded()
    }
}

struct CopyClientCommandButton: View {
    let command: String
    var pasteboard: NSPasteboard = .general
    @State private var copied: Bool?
    @State private var feedbackID: UUID?

    private var title: String { copied.map { $0 ? "Copied!" : "Copy Failed" } ?? "Copy Client Command" }
    var body: some View {
        Button {
            pasteboard.clearContents()
            copied = pasteboard.setString(command, forType: .string)
            feedbackID = UUID()
        } label: {
            ZStack(alignment: .leading) {
                Label("Copy Client Command", systemImage: "doc.on.doc").hidden()
                Label(title, systemImage: copied.map { $0 ? "checkmark" : "exclamationmark.triangle" } ?? "doc.on.doc")
            }
            .font(.system(size: 11))
            .crowForeground(CrowTheme.textDim)
        }
        .buttonStyle(CrowButtonStyle())
        .accessibilityLabel(title).accessibilityIdentifier("crow.reverse-ssh-copy")
        .help("Run this command on the SSH server. Append a command to execute it on this Mac.")
        .task(id: feedbackID) {
            guard feedbackID != nil else { return }
            do { try await Task.sleep(for: .milliseconds(1600)); copied = nil }
            catch { /* A new click restarts the feedback interval. */ }
        }
        .onChange(of: command) { _, _ in copied = nil; feedbackID = nil }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Remote Project Folder").font(.headline)
            Text("Browse the SSH server or enter an absolute path. Your open tabs and terminal stay open.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { browse("~") } label: { Image(systemName: "house") }.help("Remote Home")
                Button {
                    if let loadedPath { browse((loadedPath as NSString).deletingLastPathComponent) }
                } label: { Image(systemName: "arrow.up") }.help("Parent Folder").disabled(loadedPath == nil || loadedPath == "/")
                TextField("Remote folder path", text: $path).textFieldStyle(.roundedBorder).onSubmit { browse(path) }
                Button("Go") { browse(path) }
            }
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
                Button("Use This Folder") {
                    guard let loadedPath else { return }
                    loading = true; error = nil
                    request = Task {
                        do { try await model.selectRemoteProject(loadedPath, in: workspaceID); dismiss() }
                        catch is CancellationError {} catch { self.error = error.localizedDescription }
                        loading = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(loading || loadedPath == nil || path != loadedPath)
            }
        }
        .padding(20).frame(minWidth: 380, idealWidth: 520, minHeight: 360, idealHeight: 440)
        .onAppear { browse(initialPath) }
        .onDisappear { request?.cancel() }
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
