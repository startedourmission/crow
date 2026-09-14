import CrowCore
import Foundation

extension AppModel {
    var workspaceHostIDs: [HostID] {
        var ids = hosts.map(\.id)
        for state in states {
            if let id = state.snapshot.workspace.hostID, !ids.contains(id) { ids.append(id) }
        }
        let saved = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        let recency = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, saved[id]?.lastConnectedAt ?? states.filter { $0.snapshot.workspace.hostID == id }
                .compactMap { $0.snapshot.lastOpenedAt }.max() ?? .distantPast)
        })
        return ids.sorted {
            if recency[$0] != recency[$1] { return recency[$0]! > recency[$1]! }
            let first = saved[$0]?.userAtHost ?? $0.rawValue.uuidString
            let second = saved[$1]?.userAtHost ?? $1.rawValue.uuidString
            let order = first.localizedCaseInsensitiveCompare(second)
            return order == .orderedSame ? $0.rawValue.uuidString < $1.rawValue.uuidString : order == .orderedAscending
        }
    }

    func alphabetizedWorkspaces(on hostID: HostID?) -> [WorkspaceState] {
        states.filter { $0.snapshot.workspace.hostID == hostID }.sorted {
            let order = $0.snapshot.workspace.name.localizedCaseInsensitiveCompare($1.snapshot.workspace.name)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.snapshot.rootPath != $1.snapshot.rootPath { return $0.snapshot.rootPath < $1.snapshot.rootPath }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
    }

    func recordHostConnection(_ id: HostID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].lastConnectedAt = Date()
        schedulePersist()
    }

    func workspaceFolderName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    func workspaceHostName(_ state: WorkspaceState) -> String {
        guard let hostID = state.snapshot.workspace.hostID else { return "Local" }
        return hosts.first { $0.id == hostID }?.name ?? "SSH"
    }

    func preferredRemoteWorkspace(hostID: HostID, id: WorkspaceID? = nil) -> WorkspaceState? {
        let candidates = states.filter { $0.snapshot.workspace.hostID == hostID }
        if let id { return candidates.first { $0.id == id } }
        return candidates.first { $0.id == selectedWorkspaceID }
            ?? candidates.sorted { ($0.snapshot.lastOpenedAt ?? .distantPast) > ($1.snapshot.lastOpenedAt ?? .distantPast) }.first
    }

    func shareConnection(from source: WorkspaceState, to target: WorkspaceState) {
        guard source !== target, source.remote?.isConnected == true, target.remote?.isConnected != true else { return }
        target.connectionTask?.cancel(); target.connectionTask = nil
        target.stopTerminals()
        target.remote = source.remote
        #if os(macOS)
        target.systemSSH = source.systemSSH
        #endif
        target.snapshot.workspace.connection = .connected
    }

    func showWorkspaces() {
        compactSurface = .hosts
        sidebarPane = .workspaces; sidebarVisible = true
    }

    func activateWorkspace(_ id: WorkspaceID, reconnect: Bool = true) {
        guard let state = states.first(where: { $0.id == id }) else { return }
        selectWorkspace(id, showFiles: false)
        if state.snapshot.layout?.allTabs.isEmpty != false { state.snapshot.layout?.open(.start(UUID())) }
        #if os(iOS)
        switch state.snapshot.layout?.activePane?.selected {
        case .terminal where state.snapshot.workspace.isRemote: compactSurface = .terminal
        case .file: compactSurface = .editor
        default: compactSurface = .files
        }
        #endif
        if reconnect, let hostID = state.snapshot.workspace.hostID, state.remote?.isConnected != true,
           state.snapshot.workspace.connection != .connecting, let host = hosts.first(where: { $0.id == hostID }) {
            connect(host, select: false, workspaceID: state.id)
        }
        schedulePersist()
    }

    func pinWorkspace(_ id: WorkspaceID) {
        guard let state = states.first(where: { $0.id == id }) else { return }
        state.snapshot.isPinned.toggle(); schedulePersist()
    }

    @discardableResult func newAgentTerminal(_ provider: AgentProvider, in paneID: UUID? = nil) -> UUID? {
        guard hasWorkspace else { folderImporterVisible = true; return nil }
        guard !current.snapshot.workspace.isRemote || current.remote?.isConnected == true else {
            report(CommandError("Connect this workspace’s SSH host before starting an agent.")); return nil
        }
        let agent = AgentTerminal(provider: provider, directory: current.snapshot.rootPath)
        current.snapshot.agentTerminals.append(agent)
        openCommandTerminal(id: agent.id, in: paneID)
        return agent.id
    }

    func openCommandTerminal(id: UUID = UUID(), command: String? = nil, in paneID: UUID? = nil) {
        ensureLayout(current)
        current.snapshot.terminalIDs.append(id)
        current.snapshot.selectedTerminalID = id
        if let command { terminal(id, in: current).launchCommand = command }
        current.snapshot.layout?.open(.terminal(id), in: paneID)
        current.maximizedPaneID = nil
        terminalVisible = true
        compactSurface = .terminal
        schedulePersist()
    }

    func openAgentTerminal(_ id: UUID, workspaceID: WorkspaceID) {
        guard let state = states.first(where: { $0.id == workspaceID }), state.snapshot.terminalIDs.contains(id) else { return }
        activateWorkspace(workspaceID)
        ensureLayout(state)
        state.snapshot.layout?.open(.terminal(id))
        state.snapshot.selectedTerminalID = id
        state.maximizedPaneID = nil
        terminalVisible = true; compactSurface = .terminal
        schedulePersist()
    }

    func renameAgentTerminal(_ id: UUID, workspaceID: WorkspaceID, name: String) {
        guard let state = states.first(where: { $0.id == workspaceID }),
              let index = state.snapshot.agentTerminals.firstIndex(where: { $0.id == id }) else { return }
        state.snapshot.agentTerminals[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        schedulePersist()
    }

    func pinAgentTerminal(_ id: UUID, workspaceID: WorkspaceID) {
        guard let state = states.first(where: { $0.id == workspaceID }),
              let index = state.snapshot.agentTerminals.firstIndex(where: { $0.id == id }) else { return }
        state.snapshot.agentTerminals[index].isPinned.toggle()
        schedulePersist()
    }
}
