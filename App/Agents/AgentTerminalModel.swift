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
        case .file, .browser: compactSurface = .editor
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

    @discardableResult func newAgentTerminal(_ provider: AgentProvider, in paneID: UUID? = nil, directory: String? = nil) -> UUID? {
        guard hasWorkspace else { folderImporterVisible = true; return nil }
        guard !current.snapshot.workspace.isRemote || current.remote?.isConnected == true else {
            report(CommandError("Connect this workspace’s SSH host before starting an agent.")); return nil
        }
        let agent = AgentTerminal(provider: provider, directory: directory ?? current.contextRootPath)
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

struct ReverseAgentRequest: Identifiable {
    let id = UUID()
    let workspaceID: WorkspaceID
    let paneID: UUID
    var directory: String
    var provider: AgentProvider = .claude
    var hostID: HostID?
    var sessionID: String?
    var fork = false
    var replacingTerminalID: UUID?
}

extension AppModel {
    func requestReverseAgent(in paneID: UUID, replacing terminalID: UUID? = nil) {
        guard !current.snapshot.workspace.isRemote else { return }
        let agent = current.snapshot.agentTerminals.first { $0.id == terminalID }
        reverseAgentRequest = ReverseAgentRequest(workspaceID: current.id, paneID: paneID,
            directory: agent?.directory ?? current.agentHistoryPath, provider: agent?.provider ?? .claude,
            hostID: agent?.reverseHostID, sessionID: agent?.historySessionID ?? agent?.sessionID,
            fork: agent?.historySessionID == nil && agent?.forkSession == true, replacingTerminalID: terminalID)
    }

    func agentHistorySource(for state: WorkspaceState) throws -> (WorkspaceState, String) {
        guard let id = state.snapshot.selectedTerminalID,
              let agent = state.snapshot.agentTerminals.first(where: { $0.id == id }),
              let hostID = agent.reverseHostID else { return (state, state.agentHistoryPath) }
        guard let remote = states.first(where: { $0.snapshot.workspace.hostID == hostID && $0.remote?.isConnected == true }),
              let directory = agent.reverseServerDirectory else { throw CommandError("Connect the agent's server to read its saved conversations.") }
        return (remote, directory)
    }
}

#if os(macOS)
import AppKit

extension AppModel {
    func launchReverseAgent(_ request: ReverseAgentRequest, host: SSHHost,
                            progress: @escaping (String) -> Void) async throws {
        guard let owner = states.first(where: { $0.id == request.workspaceID }), !owner.snapshot.workspace.isRemote else {
            throw CommandError("Select a local workspace for client work.")
        }
        if let old = request.replacingTerminalID, owner.terminals[old]?.isWorking == true {
            throw CommandError("Stop the current agent task before restarting this tab.")
        }
        let root = URL(fileURLWithPath: NSString(string: request.directory).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CommandError("Choose an existing local folder.") }
        progress("Connecting to \(host.userAtHost)…")
        if !states.contains(where: { $0.snapshot.workspace.hostID == host.id && $0.remote?.isConnected == true }) { connect(host, select: false) }
        var source: WorkspaceState?
        for _ in 0..<240 {
            try Task.checkCancellation()
            source = states.first { $0.snapshot.workspace.hostID == host.id && $0.remote?.isConnected == true }
            if source != nil { break }
            if let failed = preferredRemoteWorkspace(hostID: host.id), case .failed(let message) = failed.snapshot.workspace.connection { throw CommandError(message) }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let source else { throw CommandError("Finish SSH authentication on this host, then try opening the reverse agent again.") }
        let hadReverse = reverseSSHConnections[host.id]?.isEnabled == true
        setReverseSSH(true, for: host)
        guard let reverse = reverseSSHConnections[host.id] else { throw CommandError("Could not start Reverse SSH.") }
        var retained = false
        defer {
            if !retained && !hadReverse && !states.contains(where: { $0.snapshot.agentTerminals.contains(where: { $0.reverseHostID == host.id }) }) { reverse.stop() }
        }
        for _ in 0..<240 {
            try Task.checkCancellation()
            progress(reverse.status)
            if reverse.connectCommand != nil { break }
            if !reverse.isEnabled { throw CommandError(reverse.status) }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let connector = reverse.connectCommand else { throw CommandError("Reverse SSH did not become ready.") }
        copyReverseSSHCommand(for: host)
        progress("Connecting agent tools to the client folder…")
        guard let resource = Bundle.main.url(forResource: "agent-history", withExtension: "py") else { throw CommandError("The agent runtime is missing.") }
        let script = try String(contentsOf: resource, encoding: .utf8)
        let localRuntime = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-agent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: localRuntime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let runtime = localRuntime.appendingPathComponent("runtime.py")
        var preparedLaunch: String?
        defer {
            if !retained {
                try? FileManager.default.removeItem(at: localRuntime)
                if let preparedLaunch { Task { try? await Self.cleanReverseAgentLaunch(preparedLaunch, on: source) } }
            }
        }
        try script.write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtime.path)
        let python = try await ReverseSSHCommand.run("/bin/sh", ["-c", TerminalCommand.environment + "command -v python3"], operation: "Client tools")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard python.hasPrefix("/") else { throw CommandError("Python 3 is required on the client.") }
        let defaults = UserDefaults.standard
        let clientID = defaults.string(forKey: "crow.reverse-agent-client-id") ?? UUID().uuidString
        defaults.set(clientID, forKey: "crow.reverse-agent-client-id")
        var parameters: [String: Any] = ["action": "reverse-prepare", "workspace": source.snapshot.rootPath,
            "provider": request.provider.rawValue, "client_id": clientID, "client_root": root.path,
            "client_python": python, "client_runtime": runtime.path, "runtime_source": script, "connector": connector]
        if let sessionID = request.sessionID { parameters["session_id"] = sessionID; parameters["fork"] = request.fork }
        struct Prepared: Decodable { let directory: String; let launch: String; let command: String }
        let prepared = try JSONDecoder().decode(Prepared.self, from: await AgentHistoryService.run(parameters, in: source, operation: "Reverse agent", timeout: 60))
        preparedLaunch = prepared.launch
        try Task.checkCancellation()
        guard states.contains(where: { $0 === owner }),
              owner.snapshot.layout?.panes.contains(where: { $0.id == request.paneID }) == true,
              reverse.connectCommand == connector, source.remote?.isConnected == true else { throw CommandError("The workspace or SSH connection changed. Try again.") }
        if let old = request.replacingTerminalID, owner.terminals[old]?.isWorking == true {
            throw CommandError("Stop the current agent task before restarting this tab.")
        }
        var agent = AgentTerminal(provider: request.provider, directory: root.path)
        agent.reverseHostID = host.id; agent.reverseServerDirectory = prepared.directory
        agent.sessionID = request.sessionID; agent.forkSession = request.fork
        // The PTY connects to the server; the tab, explorer and Git remain local.
        let execution = Workspace(name: host.name, kind: .remote(hostID: host.id, path: prepared.directory), connection: .connected)
        let session = TerminalSession(id: agent.id, workspace: execution, directory: prepared.directory,
            remote: source.remote, fontSize: settings.terminalFontSize, useSystemSSH: source.systemSSH != nil)
        session.systemSSH = source.systemSSH
        session.launchCommand = TerminalCommand.environment + prepared.command
        session.agentProvider = request.provider
        session.onFirstAgentPrompt = { [weak owner] prompt in
            guard let owner, let index = owner.snapshot.agentTerminals.firstIndex(where: { $0.id == agent.id }),
                  owner.snapshot.agentTerminals[index].firstPrompt == nil else { return }
            owner.snapshot.agentTerminals[index].firstPrompt = prompt
        }
        session.onAgentTitle = { [weak self, weak owner] title in
            guard let self, let owner, let index = owner.snapshot.agentTerminals.firstIndex(where: { $0.id == agent.id }) else { return }
            owner.snapshot.agentTerminals[index].conversationTitle = title; self.schedulePersist()
        }
        session.onStop = {
            try? FileManager.default.removeItem(at: localRuntime)
            Task { try? await Self.cleanReverseAgentLaunch(prepared.launch, on: source) }
        }
        owner.snapshot.agentTerminals.append(agent)
        owner.terminals[agent.id] = session; owner.terminalGeneration += 1
        owner.snapshot.terminalIDs.append(agent.id); owner.snapshot.selectedTerminalID = agent.id
        owner.snapshot.layout?.open(.terminal(agent.id), in: request.paneID)
        // Keep the pane alive when replacing its only tab.
        if let old = request.replacingTerminalID { closeTerminal(old) }
        retained = true
        activateWorkspace(owner.id, reconnect: false)
        terminalVisible = true; compactSurface = .terminal; owner.maximizedPaneID = nil
        defaults.set(host.id.rawValue.uuidString, forKey: "crow.reverse-agent-last-host")
        schedulePersist()
    }

    private static func cleanReverseAgentLaunch(_ path: String, on state: WorkspaceState) async throws {
        guard state.remote?.isConnected == true else { return }
        _ = try await AgentHistoryService.run(["action": "reverse-cleanup", "workspace": state.snapshot.rootPath, "launch": path], in: state, operation: "Reverse agent cleanup")
    }
}
#endif
