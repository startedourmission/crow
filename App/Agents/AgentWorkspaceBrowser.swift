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
    @State private var renaming: AgentTerminalRoute?
    @State private var name = ""
    @State private var closing: UUID?
    @State private var pickingLocalFolder = false
    @State private var folderSource: WorkspaceID?

    private var workspaces: [WorkspaceState] {
        model.states.filter { state in
            search.isEmpty || ([state.snapshot.workspace.name, state.snapshot.rootPath, model.workspaceHostName(state)]
                + state.snapshot.agentTerminals.map(\.title)).joined(separator: " ").localizedCaseInsensitiveContains(search)
        }.sorted { ($0.snapshot.lastOpenedAt ?? .distantPast) > ($1.snapshot.lastOpenedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("WORKSPACES").font(.system(size: 11, weight: .semibold)).tracking(0.6)
                Spacer()
                addWorkspaceMenu
            }.foregroundStyle(CrowTheme.textDim).padding(.horizontal, 12).frame(height: 40)
            TextField("Search workspaces", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                .padding(8).background(CrowTheme.bg0, in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, 10).padding(.bottom, 10)
                .accessibilityIdentifier("crow.agents.search")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    let pinned = workspaces.filter { $0.snapshot.isPinned }
                    let recent = workspaces.filter { !$0.snapshot.isPinned }
                    if !pinned.isEmpty {
                        sectionLabel("Pinned", count: pinned.count, symbol: "pin")
                        ForEach(pinned) { workspaceRow($0) }
                    }
                    if !recent.isEmpty {
                        sectionLabel("Recent", count: recent.count, symbol: "clock")
                        ForEach(recent) { workspaceRow($0) }
                    }
                    if workspaces.isEmpty {
                        Text(search.isEmpty ? "Open a local or SSH folder with +." : "No matching workspaces")
                            .font(.caption).foregroundStyle(CrowTheme.textDim).padding(12)
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
            Button("Add SSH Host…", systemImage: "plus") { model.sshCommandVisible = true; onOpen?() }
        } label: { Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Add workspace").accessibilityIdentifier("crow.workspaces.add").windowDragExcluded()
    }

    private func sectionLabel(_ title: String, count: Int, symbol: String) -> some View {
        HStack(spacing: 5) { Image(systemName: symbol); Text(title); Text("\(count)").foregroundStyle(CrowTheme.textDim) }
            .font(.system(size: 10, weight: .medium)).padding(.horizontal, 10)
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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text(state.snapshot.workspace.name).fontWeight(.semibold).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        Text(model.workspaceHostName(state) + " · " + state.snapshot.rootPath)
                            .font(.system(size: 10)).foregroundStyle(CrowTheme.textDim).lineLimit(1).truncationMode(.middle)
                        if state.snapshot.workspace.isRemote {
                            Text(connectionLabel(state)).font(.system(size: 10)).foregroundStyle(CrowTheme.textDim)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                }.accessibilityIdentifier("crow.workspaces.select." + state.id.rawValue.uuidString)
                newSessionMenu(state)
            }.font(.system(size: 12)).padding(.horizontal, 6)
                .contextMenu {
                    Button("Open Workspace") { model.activateWorkspace(state.id); onOpen?() }
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
            .buttonStyle(.plain).padding(.horizontal, 5).windowDragExcluded()
    }

    private func connectionLabel(_ state: WorkspaceState) -> String {
        switch state.snapshot.workspace.connection {
        case .connected, .local: "Connected"
        case .connecting: "Connecting…"
        case .disconnected: "Disconnected"
        case .failed: "Connection failed"
        }
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
            }.padding(8).padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
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

#if os(iOS)
struct AgentWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            AgentWorkspaceBrowser(onOpen: { dismiss() })
                .navigationTitle("Workspaces").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
