import CrowCore
import SwiftUI

struct AgentHistoryMessage: Codable, Sendable {
    let role: String
    let text: String
}

struct AgentHistoryEntry: Codable, Identifiable, Sendable {
    let id: String
    let provider: AgentProvider
    let path: String
    let title: String
    let modified: Double
    let size: Int
    let first: AgentHistoryMessage
    let recent: [AgentHistoryMessage]
    let tokens: Int?
    var key: String { provider.rawValue + ":" + id }
}

struct AgentHistoryResult: Decodable {
    let sessions: [AgentHistoryEntry]
    let warnings: [String]
}

@MainActor enum AgentHistoryService {
    static func run(_ request: [String: Any], in state: WorkspaceState) async throws -> Data {
        guard let url = Bundle.main.url(forResource: "agent-history", withExtension: "py") else { throw CommandError("The agent history reader is missing from this build.") }
        let script = try String(contentsOf: url, encoding: .utf8)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let command = TerminalCommand.environment + "command -v python3 >/dev/null 2>&1 || { echo 'Python 3 is required on this host to read CLI session history.' >&2; exit 1; }; exec python3 -c " + TerminalCommand.quote(script) + " " + TerminalCommand.quote(json)
        let output: String
        #if os(macOS)
        if !state.snapshot.workspace.isRemote {
            output = try await ReverseSSHCommand.run("/bin/sh", ["-c", command], operation: "Agent history")
        } else if let ssh = state.systemSSH, state.remote?.isConnected == true {
            output = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-T"] + ssh.multiplexArguments + ["sh -c " + TerminalCommand.quote(command)], operation: "Agent history")
        } else {
            guard let remote = state.remote, remote.isConnected else { throw FileFailure.disconnected }
            output = try await remote.workspaceCommand(command, operation: "Agent history")
        }
        #else
        guard state.snapshot.workspace.isRemote, let remote = state.remote, remote.isConnected else { throw CommandError("Select a connected SSH host to read its CLI sessions.") }
        output = try await remote.workspaceCommand(command, operation: "Agent history")
        #endif
        return Data(output.utf8)
    }
    static func list(in state: WorkspaceState) async throws -> AgentHistoryResult {
        try JSONDecoder().decode(AgentHistoryResult.self, from: await run(["workspace": state.snapshot.rootPath], in: state))
    }
    static func delete(_ entry: AgentHistoryEntry, in state: WorkspaceState) async throws {
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
        _ = try await run(["workspace": state.snapshot.rootPath, "action": "delete", "session": value], in: state)
    }
}

struct AgentHistoryPanel: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [AgentHistoryEntry] = []
    @State private var warnings: [String] = []
    @State private var expanded: Set<String> = []
    @State private var search = ""
    @State private var loading = false
    @State private var deleting = false
    @State private var error: String?
    @State private var refreshID = 0
    @State private var deletion: AgentHistoryEntry?
    @State private var loadedState: WorkspaceState?
    private var scope: String { "\(model.selectedWorkspaceID)-\(model.current.snapshot.rootPath)-\(model.current.remote?.isConnected == true)-\(refreshID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.workspaceFolderName(model.current.snapshot.rootPath)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                if loading || deleting { ProgressView().controlSize(.small) }
                Button { refreshID += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh agent sessions").disabled(loading || deleting)
                    .accessibilityIdentifier("crow.history.refresh")
            }.padding(.horizontal, 12).padding(.top, 12)
            TextField("Search sessions", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 12)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal, 12) }
            ForEach(warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(CrowTheme.textDim).padding(.horizontal, 12) }
            if entries.isEmpty && !loading && error == nil {
                Text("No saved agent sessions in this folder.").font(.system(size: 12)).foregroundStyle(CrowTheme.textDim).padding(12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries.filter { search.isEmpty || ($0.title + " " + ($0.recent.last?.text ?? "")).localizedCaseInsensitiveContains(search) }, id: \.key) { entry in
                        sessionRow(entry)
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("crow.history.panel")
            .task(id: scope) {
                let state = model.current
                loadedState = state; entries = []; error = nil; warnings = []; expanded = []; deletion = nil; loading = true
                while !Task.isCancelled {
                    do {
                        let result = try await AgentHistoryService.list(in: state); try Task.checkCancellation()
                        entries = result.sessions; warnings = result.warnings; error = nil
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                    if !Task.isCancelled { loading = false }
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
            .alert("Delete saved session?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { entry in
                Button("Delete Session", role: .destructive) { delete(entry) }
                Button("Cancel", role: .cancel) {}
            } message: { entry in Text("Delete “\(entry.title)” from \(entry.provider.title)'s saved conversation history. Project files are kept.") }
    }

    private func sessionRow(_ entry: AgentHistoryEntry) -> some View {
        let open = expanded.contains(entry.key)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if open { expanded.remove(entry.key) } else { expanded.insert(entry.key) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        AgentProviderIcon(provider: entry.provider, size: 13)
                        Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Spacer(minLength: 0)
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    }
                    Text(entry.recent.last?.text ?? entry.first.text).font(.system(size: 11)).foregroundStyle(CrowTheme.textDim).lineLimit(2)
                }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                message(entry.first, title: "First prompt")
                ForEach(Array(entry.recent.enumerated()), id: \.offset) { _, item in
                    message(item, title: item.role == "user" ? "You" : entry.provider.title)
                }
            }
            HStack(spacing: 8) {
                Button { resume(entry, fork: false) } label: { Image(systemName: "play") }
                    .help("Resume session").accessibilityLabel("Resume session")
                Button { resume(entry, fork: true) } label: { Image(systemName: "arrow.triangle.branch") }
                    .help("Resume in a new conversation").accessibilityLabel("Resume in a new conversation")
                Spacer(minLength: 0)
                Text(Date(timeIntervalSince1970: entry.modified), style: .relative).font(.system(size: 9)).foregroundStyle(CrowTheme.textDim).lineLimit(1)
                Button { deletion = entry } label: { Image(systemName: "trash").foregroundStyle(CrowTheme.textDim) }
                    .help("Delete saved session").accessibilityLabel("Delete saved session")
            }.font(.system(size: 12)).buttonStyle(.plain).disabled(deleting || loading)
        }.padding(10).background(CrowTheme.bg2, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("crow.history.session." + entry.key)
    }

    private func message(_ item: AgentHistoryMessage, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(CrowTheme.textDim)
            Text(item.text).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.padding(.leading, 12).padding(.vertical, 4)
    }
    private func resume(_ entry: AgentHistoryEntry, fork: Bool) {
        guard let state = loadedState, state === model.current else { return }
        if !fork, let agent = state.snapshot.agentTerminals.first(where: { $0.provider == entry.provider && $0.sessionID == entry.id && $0.forkSession != true }), state.terminals[agent.id]?.running == true {
            model.openAgentTerminal(agent.id, workspaceID: state.id); return
        }
        guard let id = model.newAgentTerminal(entry.provider), let index = state.snapshot.agentTerminals.firstIndex(where: { $0.id == id }) else { return }
        state.snapshot.agentTerminals[index].name = entry.title
        state.snapshot.agentTerminals[index].sessionID = entry.id
        state.snapshot.agentTerminals[index].forkSession = fork
        // A session view may already have been created while opening the tab.
        state.terminals[id]?.launchCommand = state.snapshot.agentTerminals[index].command
        model.schedulePersist()
    }
    private func delete(_ entry: AgentHistoryEntry) {
        guard let state = loadedState, state === model.current else { return }
        guard !state.snapshot.agentTerminals.contains(where: { $0.provider == entry.provider && $0.sessionID == entry.id && state.terminals[$0.id]?.running == true }) else {
            error = "Close this session's terminal before deleting its history."; return
        }
        deleting = true; error = nil
        Task {
            defer { deleting = false }
            do {
                try await AgentHistoryService.delete(entry, in: state)
                if state === loadedState { entries.removeAll { $0.key == entry.key }; refreshID += 1 }
            } catch { if state === loadedState { self.error = error.localizedDescription } }
        }
    }
}
