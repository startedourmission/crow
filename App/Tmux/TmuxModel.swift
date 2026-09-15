import CrowCore
import Foundation

struct TmuxExpansionState {
    var expanded = false
    var collapsedSessions: Set<String> = []
    var collapsedWindows: Set<String> = []
}

extension AppModel {
    /// A host owns one tmux tree even when it has several folder workspaces.
    func tmuxWorkspace(on hostID: HostID?) -> WorkspaceState? {
        #if os(iOS)
        guard hostID != nil else { return nil }
        #endif
        let candidates = states.filter {
            $0.snapshot.workspace.hostID == hostID && (hostID == nil || $0.remote?.isConnected == true)
        }
        return candidates.first { $0.id == selectedWorkspaceID } ?? candidates.first
    }

    func selectedTerminalID(in state: WorkspaceState) -> UUID? {
        #if os(iOS)
        return state.snapshot.selectedTerminalID
        #else
        if case .terminal(let id) = state.snapshot.layout?.activePane?.selected { return id }
        return nil
        #endif
    }

    var selectedTmuxLocation: TmuxLocation? {
        guard let id = selectedTerminalID(in: current) else { return nil }
        return current.terminals[id]?.tmuxLocation
    }

    func attachedTmuxTerminal(for sessionID: String, in state: WorkspaceState) -> TerminalSession? {
        let selected = selectedTerminalID(in: state)
        let ids = [selected].compactMap { $0 } + state.snapshot.terminalIDs.reversed()
        return ids.compactMap { state.terminals[$0] }.first {
            $0.running && $0.tmuxLocation?.sessionID == sessionID
        }
    }

    func attachTmux(_ location: TmuxLocation, in target: WorkspaceState? = nil) async throws {
        let command = try TmuxCommand.attach(location)
        let state = target ?? current
        guard states.contains(where: { $0 === state }) else { throw CommandError("This workspace was removed.") }
        activateWorkspace(state.id, reconnect: false)
        if let session = attachedTmuxTerminal(for: location.sessionID, in: state) {
            _ = try await runTmux(TmuxCommand.select(location), in: state)
            try Task.checkCancellation()
            guard selectedWorkspaceID == state.id else { return }
            if session.running {
                session.tmuxLocation = location
                openAgentTerminal(session.id, workspaceID: state.id)
                #if os(macOS)
                session.view.window?.makeFirstResponder(session.view)
                #else
                session.view.becomeFirstResponder()
                #endif
                return
            }
        }
        let id = UUID()
        openCommandTerminal(id: id, command: command)
        let session = terminal(id, in: state)
        session.tmuxLocation = location
        session.start()
    }

    func runTmux(_ command: String, in state: WorkspaceState) async throws -> String {
        #if os(macOS)
        if !state.snapshot.workspace.isRemote {
            return try await ReverseSSHCommand.run("/bin/zsh", ["-lc", command], operation: "tmux")
        }
        if let ssh = state.systemSSH, state.remote?.isConnected == true {
            return try await ReverseSSHCommand.run("/usr/bin/ssh", ["-T"] + ssh.multiplexArguments
                + ["sh -lc " + TerminalCommand.quote(command)], operation: "tmux")
        }
        #endif
        guard let remote = state.remote, remote.isConnected else {
            throw CommandError("Connect this workspace’s SSH host to manage tmux.")
        }
        return try await remote.workspaceCommand(command)
    }
}
