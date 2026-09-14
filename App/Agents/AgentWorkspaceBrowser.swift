import CrowCore
import SwiftUI

struct AgentTerminalRoute: Hashable {
    let workspaceID: WorkspaceID
    let terminalID: UUID
}

/// A workspace is a folder on a host; terminals are children of that workspace.
struct AgentWorkspaceBrowser: View {
    @Environment(AppModel.self) private var model
    var onOpen: (() -> Void)?
    @State private var search = ""
    @State private var collapsed: Set<WorkspaceID> = []
    @State private var collapsedHosts: Set<String> = []
    @State private var removeHost: SSHHost?
    @State private var renaming: AgentTerminalRoute?
    @State private var name = ""
    @State private var closing: UUID?
    @State private var pickingLocalFolder = false
    @State private var folderSource: WorkspaceID?

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
                Text("WORKSPACES").font(.system(size: 11, weight: .semibold)).tracking(0.6)
                Spacer()
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
            .fileImporter(isPresented: $pickingLocalFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): model.openFolder(url); onOpen?()
                case .failure(let error): model.report(error)
                }
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
            } message: { _ in Text("The saved credentials will be removed from this device. Server files will not be changed.") }
            .alert("Close this terminal?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
                Button("Close Terminal", role: .destructive) { if let id = closing { model.closeTerminal(id) }; closing = nil }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { closing = nil }
            } message: { Text("The terminal and its running commands will be terminated.") }
            .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name)
                Button("Save") {
                    if let route = renaming { model.renameAgentTerminal(route.terminalID, workspaceID: route.workspaceID, name: name) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
    }

    private var addWorkspaceMenu: some View {
        Menu {
            Button("Open Local Folder…", systemImage: "folder.badge.plus") { pickingLocalFolder = true }
            ForEach(model.hosts) { host in
                if let source = model.states.first(where: { $0.snapshot.workspace.hostID == host.id && $0.remote?.isConnected == true }) {
                    Button("Open Folder on \(host.name)…", systemImage: "network") { folderSource = source.id }
                } else {
                    Button("Connect to \(host.name)…", systemImage: "network") { model.connect(host); onOpen?() }
                }
            }
            Button("Add SSH Host…", systemImage: "plus") { model.sshCommandVisible = true }
            Divider()
            Button("SSH Keys…", systemImage: "key") { model.sshKeysVisible = true }
            Button("Settings…", systemImage: "gearshape") { model.settingsVisible = true }
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
                            .font(.system(size: host == nil ? 12 : 11, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.85).truncationMode(.middle)
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
                        Button("Open Local Folder…") { pickingLocalFolder = true }
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
            .font(.system(size: 10, weight: .medium)).padding(.leading, 34).padding(.trailing, 10)
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
                        Text(state.snapshot.workspace.name).fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                }.accessibilityIdentifier("crow.workspaces.select." + state.id.rawValue.uuidString)
                newSessionMenu(state)
            }.font(.system(size: 12)).padding(.horizontal, 6)
                .contextMenu {
                    Button("Open Workspace") { model.activateWorkspace(state.id); onOpen?() }
                    Button("Copy Path") { copyPath(state.snapshot.rootPath) }
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
        return Button { model.openAgentTerminal(id, workspaceID: state.id); onOpen?() } label: {
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                if let agent { AgentProviderIcon(provider: agent.provider, size: 13) }
                else { Image(systemName: "terminal").font(.system(size: 11)) }
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
                Text(activity?.title ?? (session?.running == true ? "Running" : session?.status ?? "Ready"))
                    .font(.system(size: 9, weight: activity == .needsInput ? .semibold : .regular))
                    .foregroundStyle(statusColor).lineLimit(1)
                    .help(agent == nil ? "Terminal status" : "Estimated from the agent’s terminal screen. Needs input includes questions and approvals.")
            }.padding(8).padding(.leading, 28).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? CrowTheme.bg3 : .clear, in: RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
        }.accessibilityIdentifier("crow.agents.session." + id.uuidString)
            .contextMenu {
                if let agent {
                    Button("Rename…") { name = agent.title; renaming = .init(workspaceID: state.id, terminalID: id) }
                }
                Button("Close terminal…", role: .destructive) { closing = id }
            }
    }
}
