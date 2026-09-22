import CrowCore
import Foundation

struct CrowmapAgentItem: Identifiable {
    let state: WorkspaceState
    let agent: AgentTerminal
    var id: UUID { agent.id }
}

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

    func orderedWorkspaces(on hostID: HostID?) -> [WorkspaceState] {
        let alphabetical = alphabetizedWorkspaces(on: hostID)
        return alphabetical.enumerated().sorted {
            let left = $0.element.snapshot.sortOrder ?? Int.max
            let right = $1.element.snapshot.sortOrder ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    @discardableResult func moveWorkspace(_ id: WorkspaceID, relativeTo targetID: WorkspaceID, after: Bool) -> Bool {
        guard id != targetID, let source = states.first(where: { $0.id == id }),
              let target = states.first(where: { $0.id == targetID }),
              source.snapshot.workspace.hostID == target.snapshot.workspace.hostID else { return false }
        var ordered = orderedWorkspaces(on: source.snapshot.workspace.hostID).filter { $0.id != id }
        guard let index = ordered.firstIndex(where: { $0.id == targetID }) else { return false }
        source.snapshot.isPinned = target.snapshot.isPinned
        ordered.insert(source, at: index + (after ? 1 : 0))
        for (rank, state) in ordered.enumerated() { state.snapshot.sortOrder = rank }
        schedulePersist()
        return true
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

    @discardableResult func newAgentTerminal(_ provider: AgentProvider, in paneID: UUID? = nil, directory: String? = nil,
                                           sessionID: String? = nil, fork: Bool = false, conversationTitle: String? = nil, reuseTmux: Bool = true, crowmapPath: String? = nil) -> UUID? {
        let panelPath = crowmapPath ?? (directory == nil ? focusedPanelCrowmap : nil)
        var destinationPane = paneID
        if let panelPath, !hasWorkspace || current.snapshot.workspace.isRemote {
            if let local = states.first(where: { !$0.snapshot.workspace.isRemote }) { activateWorkspace(local.id, reconnect: false) }
            else { openFolder(URL(fileURLWithPath: panelPath).deletingLastPathComponent()) }
            destinationPane = nil
        }
        guard hasWorkspace else { folderImporterVisible = true; return nil }
        guard !current.snapshot.workspace.isRemote || current.remote?.isConnected == true else {
            report(CommandError("Connect this workspace’s SSH host before starting an agent.")); return nil
        }
        // Resolve the launching pane before opening a terminal changes tab focus.
        let launchPane = destinationPane.flatMap { id in current.snapshot.layout?.panes.first { $0.id == id } } ?? current.snapshot.layout?.activePane
        let focusedMap: String? = {
            guard directory == nil, !current.snapshot.workspace.isRemote else { return nil }
            switch launchPane?.selected {
            case .file(let id):
                guard let buffer = current.snapshot.buffers.first(where: { $0.id == id }), !buffer.isRemote,
                      buffer.path.hasSuffix(".crowmap") else { return nil }
                return buffer.path
            case .terminal(let id):
                return current.snapshot.agentTerminals.first { $0.id == id }?.crowmapPath
            default: return nil
            }
        }()
        let mapPath = panelPath ?? focusedMap
        let launchDirectory = directory ?? mapPath.map { ($0 as NSString).deletingLastPathComponent } ?? current.contextRootPath
        var agent = AgentTerminal(provider: provider, directory: launchDirectory)
        agent.crowmapPath = mapPath
        agent.sessionID = sessionID; agent.forkSession = fork; agent.conversationTitle = conversationTitle
        if reuseTmux, mapPath == nil, let terminal = tmuxLaunchTerminal(in: current, paneID: paneID), let location = terminal.tmuxLocation {
            guard !terminal.tmuxAgentLaunching else { return terminal.id }
            terminal.tmuxAgentLaunching = true
            let state = current
            Task {
                defer { terminal.tmuxAgentLaunching = false }
                do {
                    guard states.contains(where: { $0 === state }), state.terminals[terminal.id] === terminal,
                          terminal.running, terminal.tmuxLocation?.sessionID == location.sessionID else { return }
                    let output = try await runTmux(TmuxCommand.focus(sessionID: location.sessionID), in: state)
                    let focus = try TmuxCommand.parseFocus(output, sessionID: location.sessionID)
                    if directory == nil { agent.directory = focus.directory }
                    try await launchInTmux(agent.command, location: focus.location, terminal: terminal, in: state)
                    if let pane = focus.location.paneID { terminal.tmuxReverseAgents.removeValue(forKey: pane) }
                } catch { report(error) }
            }
            return terminal.id
        }
        crowmapPanelFocused = false
        current.snapshot.agentTerminals.append(agent)
        openCommandTerminal(id: agent.id, in: destinationPane)
        if let mapPath { crowmap.selected = URL(fileURLWithPath: mapPath); sidebarVisible = true }
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
        if let agent = state.snapshot.agentTerminals.first(where: { $0.id == id }), let directory = agent.crowmapDirectory {
            crowmap.list()
            crowmap.selected = agent.crowmapPath.map { URL(fileURLWithPath: $0) } ?? crowmap.maps.first { $0.deletingLastPathComponent().path == directory }
            sidebarVisible = true
        }
        schedulePersist()
    }

    func crowmapAgents(in folder: URL) -> [CrowmapAgentItem] {
        let root = folder.resolvingSymlinksInPath().path
        return states.flatMap { state in state.snapshot.agentTerminals.compactMap { agent -> CrowmapAgentItem? in
            guard state.snapshot.terminalIDs.contains(agent.id), let directory = agent.crowmapDirectory,
                  URL(fileURLWithPath: directory).resolvingSymlinksInPath().path == root else { return nil }
            return CrowmapAgentItem(state: state, agent: agent)
        } }.sorted { ($0.agent.createdAt ?? .distantPast) > ($1.agent.createdAt ?? .distantPast) }
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
    var tmuxTerminalID: UUID?
}

enum ReverseSessionResume {
    /// The CLI conversation to reopen for one disconnected reverse-agent tab.
    /// Prompt and title matches have to be unique so another open tab does not
    /// receive this conversation. Otherwise the newest session in this tab's
    /// server folder is the one it was using.
    static func sessionID(provider: AgentProvider, directory: String, createdAt: Date?, firstPrompt: String?,
                          conversationTitle: String?, entries: [AgentHistoryEntry], serverTime: Double,
                          claimed: Set<String>, unboundSibling: Bool, excluding excluded: String? = nil) -> String? {
        let root = normalizedPath(directory)
        let available = entries.filter { entry in
            guard entry.provider == provider, entry.id != excluded, !claimed.contains(entry.id), let cwd = entry.cwd else { return false }
            return normalizedPath(cwd) == root
        }
        let prompt = firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !prompt.isEmpty, let createdAt {
            let floor = createdAt.timeIntervalSince1970 + (serverTime - Date().timeIntervalSince1970) - 2
            let matches = available.filter { entry in
                guard let started = entry.started, started >= floor else { return false }
                return entry.first.text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt
            }
            if matches.count == 1 { return matches[0].id }
        }
        let title = conversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            let matches = available.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == title }
            if matches.count == 1 { return matches[0].id }
        }
        guard !unboundSibling else { return nil }
        let floor = createdAt.map { $0.timeIntervalSince1970 + (serverTime - Date().timeIntervalSince1970) - 2 }
        let born = floor.map { value in available.filter { ($0.started ?? $0.modified) >= value } } ?? []
        return (born.isEmpty ? available : born).max { $0.modified < $1.modified }?.id
    }

    /// Keep the tab's name and pin. A resumed conversation also keeps its title and prompt.
    static func reconnectedAgent(_ previous: AgentTerminal, provider: AgentProvider, directory: String, hostID: HostID,
                                 serverDirectory: String, sessionID: String?, fork: Bool) -> AgentTerminal {
        var agent = previous
        agent.provider = provider
        agent.directory = directory
        agent.reverseHostID = hostID
        agent.reverseServerDirectory = serverDirectory
        let resumed = sessionID != nil && !fork
        agent.sessionID = sessionID
        agent.forkSession = sessionID == nil ? nil : fork
        agent.historySessionID = resumed ? sessionID : nil
        if !resumed {
            agent.conversationTitle = nil
            agent.firstPrompt = nil
            agent.createdAt = Date()
        }
        return agent
    }

    static func normalizedPath(_ path: String) -> String {
        var value = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

extension AppModel {
    func requestReverseAgent(in paneID: UUID, replacing terminalID: UUID? = nil) {
        guard !current.snapshot.workspace.isRemote else { return }
        let agent = current.snapshot.agentTerminals.first { $0.id == terminalID }
        reverseAgentRequest = ReverseAgentRequest(workspaceID: current.id, paneID: paneID,
            directory: agent?.directory ?? current.agentHistoryPath, provider: agent?.provider ?? .claude,
            hostID: agent?.reverseHostID, sessionID: agent?.historySessionID ?? agent?.sessionID,
            fork: agent?.historySessionID == nil && agent?.forkSession == true, replacingTerminalID: terminalID,
            tmuxTerminalID: terminalID == nil ? tmuxLaunchTerminal(in: current, paneID: paneID)?.id : nil)
    }

    func agentHistorySource(for state: WorkspaceState) throws -> (WorkspaceState, String) {
        if let context = panelAgentHistorySource() { return context }
        guard let agent = state.selectedAgent,
              let hostID = agent.reverseHostID else { return (state, state.agentHistoryPath) }
        guard let remote = states.first(where: { $0.snapshot.workspace.hostID == hostID && $0.remote?.isConnected == true }),
              let directory = agent.reverseServerDirectory else { throw CommandError("Connect the agent's server to read its saved conversations.") }
        return (remote, directory)
    }

    /// Other open tabs on this server already own these CLI ids. A sibling that
    /// still has no id shares the reverse folder, so a bare "newest session" guess
    /// could attach this tab to that sibling's conversation.
    func reverseSessionClaim(around agent: AgentTerminal) -> (claimed: Set<String>, unboundSibling: Bool) {
        guard let hostID = agent.reverseHostID else { return ([], false) }
        let directory = agent.reverseServerDirectory.map(ReverseSessionResume.normalizedPath)
        var claimed: Set<String> = []
        var unboundSibling = false
        for state in states {
            let open = state.snapshot.agentTerminals.filter { state.snapshot.terminalIDs.contains($0.id) }
            let tmux = state.terminals.values.flatMap { $0.tmuxReverseAgents.values }
            for other in open + tmux {
                guard other.id != agent.id, other.provider == agent.provider,
                      (other.reverseHostID ?? state.snapshot.workspace.hostID) == hostID else { continue }
                if let id = other.currentSessionID { claimed.insert(id) }
                let otherDirectory = other.reverseServerDirectory.map(ReverseSessionResume.normalizedPath)
                if other.currentSessionID == nil, otherDirectory == directory { unboundSibling = true }
            }
        }
        return (claimed, unboundSibling)
    }

    func resolvedReverseResume(previous: AgentTerminal, provider: AgentProvider, fallbackSessionID: String?,
                               entries: [AgentHistoryEntry], serverTime: Double) -> (sessionID: String?, fork: Bool) {
        if let history = previous.historySessionID { return (history, false) }
        let sessionID = previous.sessionID ?? fallbackSessionID
        let fork = previous.forkSession == true
        guard let directory = previous.reverseServerDirectory, sessionID == nil || fork else { return (sessionID, false) }
        let claim = reverseSessionClaim(around: previous)
        if let matched = ReverseSessionResume.sessionID(provider: provider, directory: directory, createdAt: previous.createdAt,
                                                        firstPrompt: previous.firstPrompt, conversationTitle: previous.conversationTitle,
                                                        entries: entries, serverTime: serverTime, claimed: claim.claimed,
                                                        unboundSibling: claim.unboundSibling, excluding: fork ? sessionID : nil) {
            return (matched, false)
        }
        return (sessionID, sessionID != nil && fork)
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
        let tmuxTerminal = request.tmuxTerminalID.flatMap { owner.terminals[$0] }
        guard tmuxTerminal?.tmuxAgentLaunching != true else { throw CommandError("An agent is already starting in this tmux pane.") }
        tmuxTerminal?.tmuxAgentLaunching = true
        defer { tmuxTerminal?.tmuxAgentLaunching = false }
        var tmuxFocus: TmuxFocus?
        if let id = request.tmuxTerminalID {
            guard let tmuxTerminal, tmuxTerminal.id == id, tmuxTerminal.running,
                  let location = tmuxTerminal.tmuxLocation else { throw CommandError("The tmux terminal was closed. Try again.") }
            let output = try await runTmux(TmuxCommand.focus(sessionID: location.sessionID), in: owner)
            tmuxFocus = try TmuxCommand.parseFocus(output, sessionID: location.sessionID)
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
        let previous = request.replacingTerminalID.flatMap { id in owner.snapshot.agentTerminals.first { $0.id == id } }
        var resumeID = request.sessionID
        var resumeFork = request.fork
        if let previous, previous.historySessionID == nil, previous.reverseServerDirectory != nil,
           (previous.sessionID ?? request.sessionID) == nil || previous.forkSession == true {
            progress("Restoring this tab’s conversation…")
            do {
                let listed = try await AgentHistoryService.list(in: source, workspacePath: previous.reverseServerDirectory)
                try Task.checkCancellation()
                let resolved = resolvedReverseResume(previous: previous, provider: request.provider,
                    fallbackSessionID: request.sessionID, entries: listed.sessions,
                    serverTime: listed.server_time ?? Date().timeIntervalSince1970)
                resumeID = resolved.sessionID
                resumeFork = resolved.fork
            } catch is CancellationError { throw CancellationError() } catch {}
        } else if let previous {
            let resolved = resolvedReverseResume(previous: previous, provider: request.provider,
                fallbackSessionID: request.sessionID, entries: [], serverTime: Date().timeIntervalSince1970)
            resumeID = resolved.sessionID
            resumeFork = resolved.fork
        }
        var parameters: [String: Any] = ["action": "reverse-prepare", "workspace": source.snapshot.rootPath,
            "provider": request.provider.rawValue, "client_id": clientID, "client_root": root.path,
            "client_python": python, "client_runtime": runtime.path, "runtime_source": script, "connector": connector]
        if let sessionID = resumeID { parameters["session_id"] = sessionID; parameters["fork"] = resumeFork }
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
        let stillOpen = previous.map { owner.snapshot.terminalIDs.contains($0.id) } == true
        let agent: AgentTerminal
        if let previous, stillOpen {
            agent = ReverseSessionResume.reconnectedAgent(previous, provider: request.provider, directory: root.path,
                hostID: host.id, serverDirectory: prepared.directory, sessionID: resumeID, fork: resumeFork)
        } else {
            var created = AgentTerminal(provider: request.provider, directory: root.path)
            created.reverseHostID = host.id
            created.reverseServerDirectory = prepared.directory
            created.sessionID = resumeID
            created.forkSession = resumeFork
            agent = created
        }
        if let tmuxTerminal, let tmuxFocus {
            var relay: TmuxSSHRelay?
            let command: String
            if let ssh = source.systemSSH {
                command = (["/usr/bin/ssh", "-tt"] + ssh.multiplexArguments
                    + ["sh -lc " + TerminalCommand.quote(TerminalCommand.utf8Environment + TerminalCommand.environment + prepared.command)])
                    .map(TerminalCommand.quote).joined(separator: " ")
            } else {
                guard let client = source.remote?.client else { throw CommandError("The SSH connection closed. Try again.") }
                let bridge = TmuxSSHRelay(client: client, command: prepared.command)
                relay = bridge
                do {
                    let port = try await bridge.start()
                    let config = localRuntime.appendingPathComponent("terminal.json")
                    try JSONSerialization.data(withJSONObject: ["port": port, "token": bridge.token]).write(to: config)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
                    let request = String(decoding: try JSONSerialization.data(withJSONObject: ["action": "tmux-terminal", "config": config.path]), as: UTF8.self)
                    command = [python, runtime.path, request].map(TerminalCommand.quote).joined(separator: " ")
                } catch { bridge.stop(); throw error }
            }
            let completed = localRuntime.appendingPathComponent("completed")
            let trackedCommand = "trap " + TerminalCommand.quote(": > " + TerminalCommand.quote(completed.path)) + " 0; " + command
            do { try await launchInTmux(trackedCommand, location: tmuxFocus.location, terminal: tmuxTerminal, in: owner) }
            catch { relay?.stop(); throw error }
            let runID = UUID()
            owner.tmuxAgentRuns[runID] = TmuxAgentRun(hostID: host.id, completed: completed) { [weak self, weak owner, weak tmuxTerminal] in
                relay?.stop()
                try? FileManager.default.removeItem(at: localRuntime)
                Task { try? await Self.cleanReverseAgentLaunch(prepared.launch, on: source) }
                owner?.tmuxAgentRuns.removeValue(forKey: runID)
                if let pane = tmuxFocus.location.paneID, tmuxTerminal?.tmuxReverseAgents[pane]?.id == agent.id {
                    tmuxTerminal?.tmuxReverseAgents.removeValue(forKey: pane)
                }
                self?.stopUnusedReverseSSH(for: [host.id])
            }
            if let pane = tmuxFocus.location.paneID { tmuxTerminal.tmuxReverseAgents[pane] = agent }
            retained = true
            defaults.set(host.id.rawValue.uuidString, forKey: "crow.reverse-agent-last-host")
            return
        }
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
        configureTerminalImagePaste(session, id: agent.id, in: owner)
        if stillOpen {
            let replaced = owner.terminals[agent.id]
            owner.terminals[agent.id] = session
            if let index = owner.snapshot.agentTerminals.firstIndex(where: { $0.id == agent.id }) {
                owner.snapshot.agentTerminals[index] = agent
            }
            owner.terminalGeneration += 1
            owner.snapshot.selectedTerminalID = agent.id
            owner.snapshot.layout?.select(.terminal(agent.id), in: request.paneID)
            replaced?.stop()
        } else {
            owner.snapshot.agentTerminals.append(agent)
            owner.terminals[agent.id] = session
            owner.terminalGeneration += 1
            owner.snapshot.terminalIDs.append(agent.id)
            owner.snapshot.selectedTerminalID = agent.id
            owner.snapshot.layout?.open(.terminal(agent.id), in: request.paneID)
            if let old = request.replacingTerminalID { closeTerminal(old) }
        }
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

import Network
@preconcurrency import Citadel
@preconcurrency import NIOCore

private struct TmuxRelayWriter: @unchecked Sendable { let value: TTYStdinWriter }

/// Owned by the workspace: detaching/closing a tmux client must leave its agent running.
@MainActor final class TmuxAgentRun {
    let hostID: HostID
    private var cleanup: (() -> Void)?
    private var task: Task<Void, Never>?
    init(hostID: HostID, completed: URL, cleanup: @escaping () -> Void) {
        self.hostID = hostID; self.cleanup = cleanup
        task = Task { [weak self] in
            while !Task.isCancelled {
                if FileManager.default.fileExists(atPath: completed.path) { self?.stop(); return }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }
    func stop() {
        task?.cancel(); task = nil
        let cleanup = cleanup; self.cleanup = nil; cleanup?()
    }
}

/// One authenticated, loopback-only client connects a tmux tty to the existing SSH connection.
@MainActor final class TmuxSSHRelay {
    let token = UUID().uuidString + UUID().uuidString
    private let client: SSHClient
    private let command: String
    private var listener: NWListener?
    private var connection: NWConnection?
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var pending = Data()
    private var ready: CheckedContinuation<Int, Error>?

    init(client: SSHClient, command: String) { self.client = client; self.command = command }

    func start() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, let ready = self.ready else { return }
                switch state {
                case .ready:
                    if let port = self.listener?.port { self.ready = nil; ready.resume(returning: Int(port.rawValue)) }
                case .failed(let error): self.ready = nil; ready.resume(throwing: error); self.stop()
                case .cancelled: self.ready = nil; ready.resume(throwing: CancellationError())
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] peer in
            Task { @MainActor in
                guard let self, self.connection == nil else { peer.cancel(); return }
                self.connection = peer; peer.start(queue: .main)
                self.task = Task { await self.serve() }
            }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.stop()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { ready = $0; listener.start(queue: .main) }
        } onCancel: { listener.cancel() }
    }

    private func serve() async {
        defer { stop() }
        do {
            let hello = try await message()
            guard hello["token"] as? String == token else { throw CommandError("Invalid terminal relay token.") }
            listener?.cancel(); listener = nil
            let command = TerminalCommand.utf8Environment + TerminalCommand.environment + command
            try await client.withPTY(.init(wantReply: true, term: "xterm-256color",
                terminalCharacterWidth: max(1, hello["cols"] as? Int ?? 80), terminalRowHeight: max(1, hello["rows"] as? Int ?? 24),
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))) { @Sendable [weak self] inbound, outbound in
                let writer = TmuxRelayWriter(value: outbound)
                var startup = SSHStartupOutput()
                try await outbound.write(ByteBuffer(string: startup.command("exec sh -lc " + TerminalCommand.quote(command) + "\n")))
                let input = Task { try await self?.pumpInput(writer) }
                defer { input.cancel() }
                for try await output in inbound {
                    try Task.checkCancellation()
                    switch output {
                    case .stdout(let bytes), .stderr(let bytes):
                        let visible = startup.receive(Array(bytes.readableBytesView))
                        if startup.isReady { await self?.didStart() }
                        if !visible.isEmpty { try await self?.send(Data(visible)) }
                    }
                }
            }
        } catch ChannelError.eof {
        } catch ChannelError.alreadyClosed {
        } catch {
            try? await send(Data(("\r\n" + error.localizedDescription + "\r\n").utf8))
        }
    }

    private func didStart() { timeout?.cancel(); timeout = nil }

    private func pumpInput(_ writer: TmuxRelayWriter) async throws {
        do {
            while !Task.isCancelled {
                let value = try await message()
                if let input = value["input"] as? String, let data = Data(base64Encoded: input) {
                    try await writer.value.write(ByteBuffer(bytes: data))
                } else if let cols = value["cols"] as? Int, let rows = value["rows"] as? Int {
                    try await writer.value.changeSize(cols: max(1, cols), rows: max(1, rows), pixelWidth: 0, pixelHeight: 0)
                }
            }
        } catch { stop(); throw error }
    }

    private func message() async throws -> [String: Any] {
        while true {
            if let end = pending.firstIndex(of: 10) {
                let line = pending[..<end]; pending.removeSubrange(...end)
                guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CommandError("Invalid terminal input.") }
                return value
            }
            guard pending.count < 131_072, let connection else { throw CancellationError() }
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: CancellationError()) }
                }
            }
            pending.append(data)
        }
    }

    private func send(_ data: Data) async throws {
        guard let connection else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func stop() {
        timeout?.cancel(); timeout = nil; task?.cancel(); task = nil
        listener?.cancel(); listener = nil; connection?.cancel(); connection = nil
        ready?.resume(throwing: CancellationError()); ready = nil
    }
}
#endif
