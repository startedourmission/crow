import CrowCore
import SwiftUI

struct GitCloneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host: String
    @State private var source = ""
    @State private var parent = "~"
    @State private var folder = ""
    @State private var suggestions: [String] = []
    @State private var useSavedCredential = true
    @State private var working = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var completedPath: String?
    #if os(macOS)
    @State private var folderPanel: NSOpenPanel?
    #endif

    init(initialHost: String) { _host = State(initialValue: initialHost) }
    private var remoteState: WorkspaceState? {
        guard let id = model.workspaceHostIDs.first(where: { $0.rawValue.uuidString == host }) else { return nil }
        return model.tmuxWorkspace(on: id)
    }
    private var connectedHosts: [SSHHost] {
        model.hosts.filter { model.tmuxWorkspace(on: $0.id) != nil }
    }
    private var request: GitCloneRequest? { try? GitCloneRequest(source: source, parent: parent, folder: folder) }
    private var validationError: String? {
        guard !source.isEmpty, !parent.isEmpty, !folder.isEmpty else { return nil }
        do { _ = try GitCloneRequest(source: source, parent: parent, folder: folder); return nil }
        catch { return error.localizedDescription }
    }
    private var canUseSavedCredential: Bool {
        #if os(macOS)
        return host == "local" && request?.supportsSavedCredential == true && model.gitAccounts.account != nil
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Clone Git Repository").font(.title3.weight(.semibold))
            Text("Clone a project and open it as a workspace.").font(.callout).foregroundStyle(CrowTheme.textDim)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    caption("Device")
                    Picker("Device", selection: $host) {
                        #if os(macOS)
                        Text("Local").tag("local")
                        #endif
                        ForEach(connectedHosts) { item in Text(item.userAtHost).tag(item.id.rawValue.uuidString) }
                    }.labelsHidden().pickerStyle(.menu).accessibilityIdentifier("crow.clone.device")
                }
                VStack(alignment: .leading, spacing: 6) {
                    caption("Repository URL")
                    TextField("https://github.com/owner/project.git", text: $source)
                        .crowSettingsInput().accessibilityIdentifier("crow.clone.source")
                }
                VStack(alignment: .leading, spacing: 6) {
                    caption("Parent folder")
                    HStack {
                        TextField("~/Projects", text: $parent).crowSettingsInput().accessibilityIdentifier("crow.clone.parent")
                        #if os(macOS)
                        if host == "local" {
                            Button { chooseFolder() } label: { Image(systemName: "folder") }
                                .help("Choose parent folder").accessibilityLabel("Choose parent folder")
                        }
                        #endif
                    }
                    ForEach(suggestions, id: \.self) { path in
                        Button { parent = path; suggestions = [] } label: {
                            Label(path, systemImage: "folder").font(.caption).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    caption("New folder name")
                    TextField("project", text: $folder).crowSettingsInput().accessibilityIdentifier("crow.clone.folder")
                }
                if canUseSavedCredential {
                    Toggle("Use saved GitHub credentials (\(model.gitAccounts.account?.login ?? ""))", isOn: $useSavedCredential)
                        .font(.callout).accessibilityIdentifier("crow.clone.credentials")
                } else {
                    Text("Uses Git credentials and SSH keys configured on the selected device.")
                        .font(.caption).foregroundStyle(CrowTheme.textDim)
                }
            }.disabled(working || completedPath != nil)
            if let error = error ?? validationError { Text(error).font(.caption).foregroundStyle(CrowTheme.danger).textSelection(.enabled).lineLimit(6) }
            if working {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Cloning repository…").font(.callout) }
            }
            HStack {
                Button(working ? "Stop" : "Cancel") {
                    if working { task?.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(completedPath == nil ? "Clone & Open" : "Open Workspace") { clone() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(working || request == nil || (host != "local" && remoteState == nil))
                    .accessibilityIdentifier("crow.clone.submit")
            }
        }.padding(24).frame(minWidth: 420, idealWidth: 520, maxWidth: 600)
            .background(CrowTheme.bg0).foregroundStyle(CrowTheme.text)
            .autocorrectionDisabled().windowDragExcluded()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .interactiveDismissDisabled(working)
            .onAppear {
                model.gitAccounts.reload()
                #if os(iOS)
                if remoteState == nil, let first = connectedHosts.first { host = first.id.rawValue.uuidString }
                #endif
                resetParent()
            }
            .onChange(of: source) { old, new in
                if folder.isEmpty || folder == GitCloneRequest.suggestedFolder(old) { folder = GitCloneRequest.suggestedFolder(new) }
            }
            .onChange(of: host) { _, _ in resetParent(); error = nil; completedPath = nil }
            .task(id: host + "\n" + parent) { await completeParent() }
            .onDisappear {
                task?.cancel()
                #if os(macOS)
                folderPanel?.cancel(nil)
                #endif
            }
    }

    private func caption(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(CrowTheme.textDim)
    }
    private func resetParent() {
        if host == "local" {
            #if os(macOS)
            parent = model.selectedWorkspace.isRemote ? "~" : model.current.snapshot.rootPath
            #endif
        } else { parent = remoteState?.snapshot.rootPath ?? "~" }
        suggestions = []
    }
    private func completeParent() async {
        let value = parent, device = host
        do {
            try await Task.sleep(for: .milliseconds(180))
            let matches: [String]
            if device == "local" {
                #if os(macOS)
                matches = try await Task.detached { try FolderPathCompletion.suggestions(for: value) }.value
                #else
                matches = []
                #endif
            } else if let state = remoteState {
                let browsing = value.hasSuffix("/") || value == "~"
                let base = browsing ? value : (value as NSString).deletingLastPathComponent
                let prefix = browsing ? "" : (value as NSString).lastPathComponent
                let result = try await model.remoteDirectory(in: state.id, at: base.isEmpty ? "~" : base)
                matches = result.folders.filter { $0.name.lowercased().hasPrefix(prefix.lowercased()) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.prefix(4).map { $0.path + "/" }
            } else { matches = [] }
            try Task.checkCancellation()
            if host == device, parent == value { suggestions = matches }
        } catch { if !Task.isCancelled { suggestions = [] } }
    }
    #if os(macOS)
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Choose"
        let completion = FolderPathCompletion(panel: panel, initialDirectory: (parent as NSString).expandingTildeInPath)
        let accessory = NSHostingView(rootView: FolderPathAccessory(completion: completion))
        accessory.frame = NSRect(x: 0, y: 0, width: 520, height: 164)
        panel.accessoryView = accessory; panel.isAccessoryViewDisclosed = true; folderPanel = panel
        panel.begin { result in
            if result == .OK, let url = panel.url { parent = url.path }
            folderPanel = nil
        }
    }
    #endif
    private func clone() {
        guard let request else { return }
        let state = remoteState, device = host
        let saved = canUseSavedCredential && useSavedCredential
        working = true; error = nil
        task = Task {
            defer { working = false }
            do {
                let path: String
                if let completedPath { path = completedPath }
                else {
                    #if os(macOS)
                    let credential = saved ? try model.gitAccounts.credential() : nil
                    if device == "local" { path = try await GitRepository.clone(request, credential: credential) }
                    else if let spec = state?.systemSSH, state?.remote?.isConnected == true {
                        path = try await GitRepository.clone(request, remote: spec)
                    } else {
                        guard let remote = state?.remote, remote.isConnected else { throw FileFailure.disconnected }
                        path = try GitCloneRequest.completedPath(await remote.workspaceCommand(request.command(), operation: "Git clone", timeout: 1800))
                    }
                    #else
                    guard let remote = state?.remote, remote.isConnected else { throw FileFailure.disconnected }
                    path = try GitCloneRequest.completedPath(await remote.workspaceCommand(request.command(), operation: "Git clone", timeout: 1800))
                    #endif
                    completedPath = path
                }
                try Task.checkCancellation()
                if let state {
                    guard model.states.contains(where: { $0 === state }) else { throw CommandError("Cloned to \(path), but the source workspace was removed.") }
                    try await model.openRemoteWorkspace(path, from: state.id)
                } else if device == "local" { model.openFolder(URL(fileURLWithPath: path)) }
                else { throw FileFailure.disconnected }
                model.sidebarPane = .workspaces; model.sidebarVisible = true
                model.collapsedWorkspaceHosts.remove(device)
                model.collapsedWorkspaceIDs.remove(model.selectedWorkspaceID)
                dismiss()
            } catch is CancellationError {
                error = "Clone stopped. A partial folder may remain at the destination."
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct AgentTerminalRoute: Hashable {
    let workspaceID: WorkspaceID
    let terminalID: UUID
}

/// A workspace is a folder on a host; terminals are children of that workspace.
struct AgentWorkspaceBrowser: View {
    @Environment(AppModel.self) private var model
    var onOpen: (() -> Void)?
    @State private var search = ""
    private var collapsed: Set<WorkspaceID> {
        get { model.collapsedWorkspaceIDs }
        nonmutating set { model.collapsedWorkspaceIDs = newValue }
    }
    private var collapsedHosts: Set<String> {
        get { model.collapsedWorkspaceHosts }
        nonmutating set { model.collapsedWorkspaceHosts = newValue }
    }
    @State private var removeHost: SSHHost?
    @State private var renaming: AgentTerminalRoute?
    @State private var name = ""
    @State private var folderSource: WorkspaceID?
    @State private var cloneHost: String?

    private func workspaces(on hostID: HostID?) -> [WorkspaceState] {
        model.alphabetizedWorkspaces(on: hostID).filter { state in
            search.isEmpty ||
                ([state.snapshot.workspace.name, state.snapshot.rootPath, model.workspaceHostName(state)]
                 + state.snapshot.agentTerminals.map(\.title)).joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    private func matchesHost(_ host: SSHHost?, id: HostID?) -> Bool {
        search.isEmpty || (host.map { $0.name + " " + $0.userAtHost } ?? (id == nil ? "Local" : "SSH"))
            .localizedCaseInsensitiveContains(search) || !workspaces(on: id).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    let expand = allHostsCollapsed
                    collapsedHosts = expand ? [] : Set(["local"] + model.workspaceHostIDs.map { $0.rawValue.uuidString })
                    collapsed = expand ? [] : Set(model.states.map(\.id))
                } label: {
                    Image(systemName: allHostsCollapsed ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(CrowButtonStyle()).windowDragExcluded()
                    .help(allHostsCollapsed ? "Expand All" : "Collapse All")
                    .accessibilityLabel(allHostsCollapsed ? "Expand All" : "Collapse All")
                    .accessibilityIdentifier("crow.workspaces.toggle-all")
                Spacer()
                Button { model.sshKeysVisible = true } label: {
                    Image(systemName: "key").frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(CrowButtonStyle()).windowDragExcluded()
                    .help("SSH Keys").accessibilityLabel("SSH Keys")
                    .accessibilityIdentifier("crow.keys.open")
                addWorkspaceMenu
            }.foregroundStyle(CrowTheme.textDim).padding(.horizontal, 12).frame(height: 40)
            TextField("Search hosts and workspaces", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                .padding(8).background(CrowTheme.bg0, in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, 10).padding(.bottom, 10)
                .accessibilityIdentifier("crow.agents.search")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if matchesHost(nil, id: nil) { hostGroup(nil, id: nil) }
                    ForEach(model.workspaceHostIDs, id: \.self) { id in
                        let host = model.hosts.first { $0.id == id }
                        if matchesHost(host, id: id) { hostGroup(host, id: id) }
                    }
                }.padding(.vertical, 8)
            }
        }.background(CrowTheme.bg1).foregroundStyle(CrowTheme.text)
            .accessibilityIdentifier("crow.agents.browser")
            .sheet(isPresented: Binding(get: { cloneHost != nil }, set: { if !$0 { cloneHost = nil } })) {
                if let cloneHost { GitCloneSheet(initialHost: cloneHost).environment(model) }
            }
            .sheet(isPresented: Binding(get: { folderSource != nil }, set: { if !$0 { folderSource = nil } })) {
                if let id = folderSource, let state = model.states.first(where: { $0.id == id }) {
                    RemoteProjectFolderPicker(workspaceID: id, initialPath: state.snapshot.rootPath)
                        .environment(model)
                }
            }
            .alert("Remove SSH host?", isPresented: Binding(get: { removeHost != nil }, set: { if !$0 { removeHost = nil } }), presenting: removeHost) { host in
                Button("Remove", role: .destructive) { model.removeHost(host) }
                Button("Cancel", role: .cancel) { }
            } message: { _ in Text("Remove this host, its workspaces and saved credentials from Crow. Server files will not be changed.") }
            .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name)
                Button("Save") {
                    if let route = renaming { model.renameAgentTerminal(route.terminalID, workspaceID: route.workspaceID, name: name) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
    }

    private var allHostsCollapsed: Bool {
        Set(["local"] + model.workspaceHostIDs.map { $0.rawValue.uuidString }).isSubset(of: collapsedHosts)
    }

    private var addWorkspaceMenu: some View {
        Menu {
            Button("Clone Git Repository…", systemImage: "arrow.down.to.line") {
                cloneHost = model.current.snapshot.workspace.hostID?.rawValue.uuidString ?? "local"
            }.accessibilityIdentifier("crow.workspaces.clone")
            Button("Open Local Folder…", systemImage: "folder.badge.plus") { model.folderImporterVisible = true }
            ForEach(model.hosts) { host in
                if let source = model.states.first(where: { $0.snapshot.workspace.hostID == host.id && $0.remote?.isConnected == true }) {
                    Button("Open Folder on \(host.name)…", systemImage: "network") { folderSource = source.id }
                } else {
                    Button("Connect to \(host.name)…", systemImage: "network") { model.connect(host); onOpen?() }
                }
            }
            Button("Add SSH Host…", systemImage: "plus") { model.sshCommandVisible = true }
        } label: { Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Add workspace").accessibilityIdentifier("crow.workspaces.add").windowDragExcluded()
    }

    private func hostGroup(_ host: SSHHost?, id: HostID?) -> some View {
        let key = id?.rawValue.uuidString ?? "local"
        let rows = workspaces(on: id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    if !collapsedHosts.insert(key).inserted { collapsedHosts.remove(key) }
                } label: {
                    Image(systemName: collapsedHosts.contains(key) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9)).frame(width: 14, height: 28).contentShape(Rectangle())
                }.accessibilityLabel("Toggle folders for " + (host?.userAtHost ?? "Local"))
                Button {
                    collapsedHosts.remove(key)
                    if let host { model.connect(host); onOpen?() }
                    else if id == nil, let local = model.states.first(where: { !$0.snapshot.workspace.isRemote }) {
                        model.activateWorkspace(local.id); onOpen?()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: id == nil ? "laptopcomputer" : "server.rack")
                        Text(host?.userAtHost ?? (id == nil ? "Local" : "SSH (not saved)"))
                            .font(.system(size: host == nil ? 12 : 11, weight: model.selectedWorkspace.hostID == id ? .bold : .regular))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.accessibilityLabel(host.map { "Connect to " + $0.userAtHost } ?? "Open Local workspaces")
                    .accessibilityIdentifier("crow.workspaces.connect." + key)
                if let host {
                    HostConnectionButton(host: host)
                    #if os(macOS)
                    ReverseSSHHostButton(host: host)
                    #endif
                }
                Menu {
                    if let host {
                        Button("Connect") { model.connect(host) }
                        if model.connectionState(for: host) == .connected {
                            Button("Clone Git Repository…") { cloneHost = key }
                            Button("Open Folder…") {
                                folderSource = model.tmuxWorkspace(on: id)?.id
                            }
                            Button("Disconnect") { model.disconnect(host) }
                        }
                        #if os(macOS)
                        if model.reverseSSHConnections[host.id]?.connectCommand != nil {
                            Button("Copy Reverse SSH Command") { model.copyReverseSSHCommand(for: host) }
                        }
                        #endif
                        Button("Edit Host…") { model.editHost(host) }
                        Button("Remove Host…", role: .destructive) { removeHost = host }
                    } else if id == nil {
                        Button("Open Local Folder…") { model.folderImporterVisible = true }
                        #if os(macOS)
                        Button("Clone Git Repository…") { cloneHost = "local" }
                        #endif
                    } else {
                        Button("Add SSH Host…") { model.sshCommandVisible = true }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 26, height: 28).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Host options")
            }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
            if !collapsedHosts.contains(key) {
                let pinned = rows.filter { $0.snapshot.isPinned }
                let recent = rows.filter { !$0.snapshot.isPinned }
                if !pinned.isEmpty {
                    sectionLabel("Pinned", count: pinned.count, symbol: "pin")
                    ForEach(pinned) { workspaceRow($0) }
                }
                if !recent.isEmpty {
                    if !pinned.isEmpty { sectionLabel("Projects", count: recent.count, symbol: "clock") }
                    ForEach(recent) { workspaceRow($0) }
                }
                if rows.isEmpty {
                    Text(search.isEmpty ? "No workspaces. Open a folder from the host menu." : "No matching workspaces")
                        .font(.system(size: 11)).foregroundStyle(CrowTheme.textDim).padding(.leading, 34).padding(.trailing, 10).padding(.vertical, 6)
                }
                if let state = model.tmuxWorkspace(on: id) {
                    TmuxPanel(workspace: state, onAttach: onOpen).padding(.leading, 24)
                } else if id != nil {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right").font(.system(size: 9))
                        Label("tmux", systemImage: "rectangle.split.2x2")
                    }.font(.system(size: 11)).foregroundStyle(CrowTheme.textDim)
                        .padding(.leading, 34).padding(.vertical, 8)
                        .help("Connect this host to manage tmux")
                }
            }
        }.buttonStyle(.plain).windowDragExcluded()
            .accessibilityIdentifier("crow.workspaces.host." + key)
    }

    private func sectionLabel(_ title: String, count: Int, symbol: String) -> some View {
        HStack(spacing: 5) { Image(systemName: symbol); Text(title); Text("\(count)").foregroundStyle(CrowTheme.textDim) }
            .font(.system(size: 10)).padding(.leading, 34).padding(.trailing, 10)
    }

    private func workspaceRow(_ state: WorkspaceState) -> some View {
        let _ = state.terminalGeneration
        let selected = model.selectedWorkspaceID == state.id
        return VStack(spacing: 3) {
            HStack(spacing: 4) {
                Button {
                    if !collapsed.insert(state.id).inserted { collapsed.remove(state.id) }
                } label: { Image(systemName: collapsed.contains(state.id) ? "chevron.right" : "chevron.down").font(.system(size: 9)).frame(width: 18, height: 30) }
                    .accessibilityLabel("Toggle sessions")
                Button { model.activateWorkspace(state.id); onOpen?() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(state.snapshot.workspace.name).lineLimit(1)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                }.accessibilityIdentifier("crow.workspaces.select." + state.id.rawValue.uuidString)
                newSessionMenu(state)
            }.font(.system(size: 12)).padding(.horizontal, 6)
                .contextMenu {
                    Button("Open Workspace") { model.activateWorkspace(state.id); onOpen?() }
                    Button("Copy Path") { copyPath(state.snapshot.rootPath) }
                    #if os(macOS)
                    if !state.snapshot.workspace.isRemote {
                        Button("Open in Finder") { model.openWorkspaceInFinder(state.id) }
                    }
                    #endif
                    Button(state.snapshot.isPinned ? "Unpin" : "Pin") { model.pinWorkspace(state.id) }
                    if state.snapshot.workspace.isRemote, state.remote?.isConnected == true {
                        Button("Open Another Folder…") { folderSource = state.id }
                    }
                    Button("Remove from List…", role: .destructive) { model.requestWorkspaceRemoval(state.id); onOpen?() }
                }
            if !collapsed.contains(state.id) {
                ForEach(state.snapshot.terminalIDs, id: \.self) { id in sessionRow(id, state: state) }
            }
        }.padding(.bottom, collapsed.contains(state.id) ? 0 : 4)
            .background(selected ? CrowTheme.bg2 : .clear, in: RoundedRectangle(cornerRadius: 6))
            .buttonStyle(.plain).padding(.leading, 24).padding(.trailing, 5).windowDragExcluded()
    }

    private func copyPath(_ path: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        #else
        UIPasteboard.general.string = path
        #endif
    }

    private func newSessionMenu(_ state: WorkspaceState) -> some View {
        Menu {
            Button("Web Browser") {
                model.activateWorkspace(state.id); model.newBrowser(); onOpen?()
            }
            Button("New Terminal") {
                model.activateWorkspace(state.id); model.newTerminal(); model.compactSurface = .terminal; onOpen?()
            }
            ForEach(AgentProvider.allCases) { provider in
                Button("New \(provider.title)") {
                    model.activateWorkspace(state.id)
                    if model.newAgentTerminal(provider) != nil { onOpen?() }
                }
            }
        } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(state.snapshot.workspace.isRemote && state.remote?.isConnected != true)
            .accessibilityLabel("New session")
    }

    private func sessionRow(_ id: UUID, state: WorkspaceState) -> some View {
        let session = state.terminals[id]
        let agent = state.snapshot.agentTerminals.first { $0.id == id }
        let title = agent?.title ?? "Terminal \((state.snapshot.terminalIDs.firstIndex(of: id) ?? 0) + 1)"
        let selected = model.selectedWorkspaceID == state.id && model.selectedTerminalID(in: state) == id
        let activity = agent != nil && session?.running == true ? session?.agentActivity : nil
        let statusColor: Color = switch activity {
        case .working: .green
        case .needsInput: .orange
        case .idle: CrowTheme.textDim
        default: agent == nil && session?.running == true ? .green : CrowTheme.textDim
        }
        return HStack(spacing: 0) {
            Button { model.openAgentTerminal(id, workspaceID: state.id); onOpen?() } label: {
            HStack(spacing: 7) {
                SessionActivityLight(color: statusColor, spinning: activity == .needsInput)
                if let agent { AgentProviderIcon(provider: agent.provider, size: 13) }
                else { Image(systemName: "terminal").font(.system(size: 11)) }
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.vertical, 8).padding(.leading, 36).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(activity?.title ?? (session?.running == true ? "Running" : "Ready"))
                .accessibilityIdentifier("crow.agents.session." + id.uuidString)
            Button { model.requestTerminalClose(id) } label: {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(CrowTheme.textDim)
                    .frame(width: 28, height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Close terminal").accessibilityLabel("Close " + title)
                .accessibilityIdentifier("crow.agents.close." + id.uuidString)
        }.background(selected ? CrowTheme.bg3 : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contextMenu {
                if let agent {
                    Button("Rename…") { name = agent.title; renaming = .init(workspaceID: state.id, terminalID: id) }
                }
                Button("Close terminal", role: .destructive) { model.requestTerminalClose(id) }
            }
    }
}

private struct SessionActivityLight: View {
    let color: Color
    let spinning: Bool
    @State private var rotating = false

    var body: some View {
        Group {
            if spinning {
                Circle().trim(from: 0.12, to: 0.85).stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(rotating ? 360 : 0))
                    .onAppear { rotating = true }
                    .onDisappear { rotating = false }
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: rotating)
            } else { Circle().fill(color).padding(1) }
        }.frame(width: 8, height: 8).accessibilityHidden(true)
    }
}
