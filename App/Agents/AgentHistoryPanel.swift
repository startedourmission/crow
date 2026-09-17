import CrowCore
import SwiftUI

struct AgentHistoryMessage: Codable, Sendable, Equatable {
    let role: String
    let text: String
}

struct AgentHistoryEntry: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let provider: AgentProvider
    let path: String
    let title: String
    let modified: Double
    let size: Int
    let first: AgentHistoryMessage
    let recent: [AgentHistoryMessage]
    let tokens: Int?
    var started: Double? = nil
    var key: String { provider.rawValue + ":" + id }
}

struct AgentHistoryResult: Decodable {
    let sessions: [AgentHistoryEntry]
    let warnings: [String]
    var signature: String? = nil
    var unchanged: Bool? = nil
    var server_time: Double? = nil
}

@MainActor enum AgentHistoryService {
    static func run(_ request: [String: Any], in state: WorkspaceState, operation: String = "Agent history", timeout: TimeInterval = 12) async throws -> Data {
        guard let url = Bundle.main.url(forResource: "agent-history", withExtension: "py") else { throw CommandError("The agent history reader is missing from this build.") }
        let script = try String(contentsOf: url, encoding: .utf8)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let command = TerminalCommand.environment + "command -v python3 >/dev/null 2>&1 || { echo 'Python 3 is required on this host to read agent data.' >&2; exit 1; }; exec python3 -c " + TerminalCommand.quote(script) + " " + TerminalCommand.quote(json)
        let output: String
        #if os(macOS)
        if !state.snapshot.workspace.isRemote {
            output = try await ReverseSSHCommand.run("/bin/sh", ["-c", command], operation: operation)
        } else if let ssh = state.systemSSH, state.remote?.isConnected == true {
            output = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-T"] + ssh.multiplexArguments + ["sh -c " + TerminalCommand.quote(command)], operation: operation)
        } else {
            guard let remote = state.remote, remote.isConnected else { throw FileFailure.disconnected }
            output = try await remote.workspaceCommand(command, operation: operation, timeout: timeout)
        }
        #else
        guard state.snapshot.workspace.isRemote, let remote = state.remote, remote.isConnected else { throw CommandError("Select a connected SSH host to read its agent data.") }
        output = try await remote.workspaceCommand(command, operation: operation, timeout: timeout)
        #endif
        return Data(output.utf8)
    }
    static func list(in state: WorkspaceState, workspacePath: String? = nil, knownSignature: String? = nil) async throws -> AgentHistoryResult {
        var request: [String: Any] = ["workspace": workspacePath ?? state.agentHistoryPath]
        if let knownSignature { request["known_signature"] = knownSignature }
        return try JSONDecoder().decode(AgentHistoryResult.self, from: await run(request, in: state))
    }
    static func delete(_ entry: AgentHistoryEntry, in state: WorkspaceState, workspacePath: String? = nil, closedTab: Bool = false) async throws {
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
        _ = try await run(["workspace": workspacePath ?? state.agentHistoryPath, "action": "delete", "session": value, "closed_tab": closedTab], in: state)
    }
}

extension AppModel {
    /// Bind a newly created CLI record only when both sides are unambiguous.
    /// Start time excludes old conversations that happen to have the same prompt.
    func reconcileAgentHistory(_ entries: [AgentHistoryEntry], source: WorkspaceState, path: String, serverTime: Double) {
        var matches: [(WorkspaceState, Int, String)] = []
        let clockOffset = serverTime - Date().timeIntervalSince1970
        let hostID = source.snapshot.workspace.hostID
        for state in states {
            for (index, agent) in state.snapshot.agentTerminals.enumerated() {
                guard agent.currentSessionID == nil, state.snapshot.terminalIDs.contains(agent.id),
                      (agent.reverseHostID ?? state.snapshot.workspace.hostID) == hostID,
                      (agent.reverseServerDirectory ?? agent.directory) == path,
                      let created = agent.createdAt,
                      let prompt = agent.firstPrompt, !prompt.isEmpty else { continue }
                let candidates = entries.filter { entry in
                    guard entry.provider == agent.provider, let started = entry.started,
                          started >= created.timeIntervalSince1970 + clockOffset - 2 else { return false }
                    return entry.first.text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt
                }
                if candidates.count == 1 { matches.append((state, index, candidates[0].id)) }
            }
        }
        var changed = false
        for (state, index, id) in matches {
            let provider = state.snapshot.agentTerminals[index].provider
            guard matches.filter({ $0.2 == id && $0.0.snapshot.agentTerminals[$0.1].provider == provider }).count == 1,
                  !states.contains(where: { owner in owner.snapshot.agentTerminals.contains {
                      $0.provider == provider && $0.currentSessionID == id && ($0.reverseHostID ?? owner.snapshot.workspace.hostID) == hostID
                  } }) else { continue }
            state.snapshot.agentTerminals[index].historySessionID = id; changed = true
        }
        if changed { schedulePersist() }
    }

    func agentHistoryTabIDs(_ entry: AgentHistoryEntry, source: WorkspaceState) -> [UUID] {
        let hostID = source.snapshot.workspace.hostID
        return states.flatMap { state in state.snapshot.agentTerminals.filter {
            $0.provider == entry.provider && $0.currentSessionID == entry.id
                && ($0.reverseHostID ?? state.snapshot.workspace.hostID) == hostID
                && state.snapshot.terminalIDs.contains($0.id)
        }.map(\.id) }
    }
    @discardableResult func closeAgentHistoryTabs(_ entry: AgentHistoryEntry, source: WorkspaceState) -> Int {
        let ids = agentHistoryTabIDs(entry, source: source)
        for id in ids { closeTerminal(id) }
        return ids.count
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
    @State private var loadedPath: String?
    @State private var loadedExecutionState: WorkspaceState?
    @State private var loadedExecutionPath: String?
    @State private var loadedReverseHost: HostID?
    @State private var loadedContext: String?
    @State private var historySignature: String?
    @State private var automaticRefreshPaused = false
    private var focusedAgent: AgentTerminal? { model.current.snapshot.agentTerminals.first { $0.id == model.current.focusedTerminalID } }
    private var focusedTerminal: TerminalSession? { model.current.focusedTerminalID.flatMap { model.current.terminals[$0] } }
    private var context: String { "\(model.selectedWorkspaceID)-\(model.current.focusedTerminalID?.uuidString ?? "")-\(model.current.agentHistoryPath)-\(model.aiUsageSource.state?.remote?.isConnected == true)" }
    private var scope: String { context + "-\(refreshID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.workspaceFolderName(model.current.agentHistoryPath)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                if loading || deleting { ProgressView().controlSize(.small) }
                Button { refreshID += 1 } label: { PanelActionIcon(symbol: "arrow.clockwise") }
                    .buttonStyle(CrowButtonStyle()).windowDragExcluded()
                    .accessibilityLabel("Refresh agent sessions")
                    .help(automaticRefreshPaused ? "Refresh agent sessions · automatic refresh paused for this slow source" : "Refresh agent sessions").disabled(loading || deleting)
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
            .windowDragExcluded()
            .accessibilityIdentifier("crow.history.panel")
            .onChange(of: focusedAgent?.firstPrompt) { _, prompt in
                if prompt != nil, !automaticRefreshPaused { refreshID += 1 }
            }
            .onChange(of: focusedTerminal?.agentActivity) { before, after in
                if !automaticRefreshPaused, before == .working, after == .idle || after == .needsInput { refreshID += 1 }
            }
            .task(id: scope) {
                guard !deleting else { return }
                let state = model.current, path = model.current.agentHistoryPath
                if loadedContext != context {
                    loadedContext = context; historySignature = nil
                    loadedPath = path; loadedState = state; entries = []; warnings = []; expanded = []; deletion = nil
                    loadedExecutionState = nil; loadedExecutionPath = nil; loadedReverseHost = nil
                }
                error = nil; loading = entries.isEmpty
                // No continuous timer: only panel/folder changes, a first prompt,
                // a finished turn or explicit Refresh trigger a read. Allow two
                // short retries for the CLI to save its first conversation record.
                let retries = focusedAgent?.firstPrompt != nil && focusedAgent?.currentSessionID == nil ? 3 : 1
                for attempt in 0..<retries {
                    do { try await Task.sleep(for: .milliseconds(attempt == 0 ? 500 : 2000)) } catch { return }
                    guard !deleting else { return }
                    do {
                        let (source, sourcePath) = try model.agentHistorySource(for: state)
                        let started = ContinuousClock.now
                        let result = try await AgentHistoryService.list(in: source, workspacePath: sourcePath, knownSignature: historySignature); try Task.checkCancellation()
                        guard !deleting else { return }
                        automaticRefreshPaused = started.duration(to: .now) > .milliseconds(1500)
                        loadedExecutionState = source; loadedExecutionPath = sourcePath
                        loadedReverseHost = source === state ? nil : source.snapshot.workspace.hostID
                        historySignature = result.signature
                        if result.unchanged != true {
                            if entries != result.sessions { entries = result.sessions }
                            warnings = result.warnings
                        }
                        model.reconcileAgentHistory(entries, source: source, path: sourcePath, serverTime: result.server_time ?? Date().timeIntervalSince1970)
                        error = nil
                    } catch {
                        if !Task.isCancelled { self.error = error.localizedDescription; loading = false }
                        return
                    }
                    if !Task.isCancelled { loading = false }
                    if automaticRefreshPaused || focusedAgent?.currentSessionID != nil { break }
                }
            }
            .alert("Delete saved session?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { entry in
                Button("Delete Session", role: .destructive) { delete(entry) }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: { entry in Text("Delete “\(entry.title)” from \(entry.provider.title)'s saved conversation history and close its open agent tabs. Running work in those tabs will stop. Project files are kept.") }
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
        guard let state = loadedState, state === model.current, let path = loadedPath, path == state.agentHistoryPath else { return }
        if let hostID = loadedReverseHost, let pane = state.snapshot.layout?.activePaneID {
            model.reverseAgentRequest = ReverseAgentRequest(workspaceID: state.id, paneID: pane,
                directory: path, provider: entry.provider, hostID: hostID, sessionID: entry.id, fork: fork,
                tmuxTerminalID: model.tmuxLaunchTerminal(in: state, paneID: pane)?.id)
            return
        }
        if model.tmuxLaunchTerminal(in: state) == nil, !fork,
           let agent = state.snapshot.agentTerminals.first(where: { $0.provider == entry.provider && $0.currentSessionID == entry.id }), state.terminals[agent.id]?.running == true {
            model.openAgentTerminal(agent.id, workspaceID: state.id); return
        }
        model.newAgentTerminal(entry.provider, directory: path, sessionID: entry.id, fork: fork, conversationTitle: entry.title)
    }
    private func delete(_ entry: AgentHistoryEntry) {
        guard let state = loadedState, state === model.current, let path = loadedPath, path == state.agentHistoryPath else { return }
        guard let source = loadedExecutionState, let sourcePath = loadedExecutionPath else { return }
        deleting = true; error = nil
        let ids = Set(model.agentHistoryTabIDs(entry, source: source))
        let sessions = model.states.flatMap { state in state.terminals.filter { ids.contains($0.key) }.map(\.value) }
        let closed = model.closeAgentHistoryTabs(entry, source: source)
        Task {
            defer { deleting = false; historySignature = nil; refreshID += 1 }
            do {
                for session in sessions { try await session.waitUntilStopped() }
                try await AgentHistoryService.delete(entry, in: source, workspacePath: sourcePath, closedTab: closed > 0)
                if state === loadedState, loadedPath == path { entries.removeAll { $0.key == entry.key } }
            } catch { model.report(error) }
        }
    }
}

struct AgentSkillEntry: Decodable, Identifiable {
    let provider: AgentProvider
    let name: String
    let description: String
    let path: String
    let scope: String
    var id: String { provider.rawValue + ":" + path }
}

struct AgentSkillsResult: Decodable {
    let skills: [AgentSkillEntry]
    let warnings: [String]
}

struct AgentSkillsPanel: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("crow.skills.provider") private var providerID = AgentProvider.claude.rawValue
    @State private var entries: [AgentSkillEntry] = []
    @State private var warnings: [String] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var refreshID = 0
    @State private var loadedScope = ""
    private var providers: [AgentProvider] { model.settings.enabledAgentProviders }
    private var selectedProvider: AgentProvider? {
        providers.first { $0.rawValue == providerID } ?? providers.first
    }
    private var scope: String {
        "\(model.selectedWorkspaceID)-\(model.current.focusedTerminalID?.uuidString ?? "")-\(model.current.agentHistoryPath)-\(model.current.remote?.isConnected == true)-\(selectedProvider?.rawValue ?? "none")-\(refreshID)"
    }
    private var visibleEntries: [AgentSkillEntry] {
        guard loadedScope == scope else { return [] }
        return entries.filter { $0.provider == selectedProvider && (search.isEmpty || ($0.name + " " + $0.description).localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.workspaceFolderName(model.current.agentHistoryPath))
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .help(model.current.agentHistoryPath)
                Spacer(minLength: 0)
                if loading { ProgressView().controlSize(.small) }
                HStack(spacing: 2) {
                    ForEach(providers) { provider in
                        Button { providerID = provider.rawValue } label: {
                            AgentProviderIcon(provider: provider, size: 14)
                                .frame(width: 28, height: 28)
                                .background(selectedProvider == provider ? CrowTheme.bg3 : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .opacity(selectedProvider == provider ? 1 : 0.5)
                        }.buttonStyle(CrowButtonStyle())
                            .help("\(provider.title) skills").accessibilityLabel("\(provider.title) skills")
                            .accessibilityAddTraits(selectedProvider == provider ? .isSelected : [])
                            .accessibilityIdentifier("crow.skills.provider." + provider.rawValue)
                    }
                }
                Button { refreshID += 1 } label: { PanelActionIcon(symbol: "arrow.clockwise") }
                    .buttonStyle(CrowButtonStyle()).disabled(loading || selectedProvider == nil)
                    .help("Refresh skills").accessibilityLabel("Refresh skills")
                    .accessibilityIdentifier("crow.skills.refresh")
            }.padding(.horizontal, 12).padding(.top, 12)
            TextField("Search skills", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 12)
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal, 12)
            }
            ForEach(warnings, id: \.self) {
                Text($0).font(.caption).foregroundStyle(CrowTheme.textDim).padding(.horizontal, 12)
            }
            if visibleEntries.isEmpty && !loading && error == nil {
                Text(selectedProvider == nil ? "Enable an agent in Settings to view skills." : search.isEmpty ? "No skills found for this folder." : "No matching skills.")
                    .font(.system(size: 12)).foregroundStyle(CrowTheme.textDim).padding(12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleEntries) { entry in
                        Button {
                            guard loadedScope == scope else { return }
                            model.openFile(FileEntry(name: (entry.path as NSString).lastPathComponent, path: entry.path, isDirectory: false))
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                AgentProviderIcon(provider: entry.provider, size: 14).padding(.top, 1)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(entry.name).font(.system(size: 12)).lineLimit(2)
                                        Spacer(minLength: 0)
                                        Text(entry.scope).font(.system(size: 10)).foregroundStyle(CrowTheme.textDim)
                                    }
                                    if !entry.description.isEmpty {
                                        Text(entry.description).font(.system(size: 11))
                                            .foregroundStyle(CrowTheme.textDim).lineLimit(2)
                                    }
                                }
                            }
                            .multilineTextAlignment(.leading).padding(.horizontal, 8).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(CrowButtonStyle())
                        .help("\(entry.provider.title) · \(entry.path)")
                        .accessibilityLabel("\(entry.provider.title): \(entry.name), \(entry.scope)")
                    }
                }.padding(.horizontal, 4).padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .windowDragExcluded().accessibilityIdentifier("crow.skills.panel")
        .task(id: scope) {
            let requestScope = scope, state = model.current, path = model.current.agentHistoryPath
            entries = []; warnings = []; error = nil; loading = true; loadedScope = ""
            guard let selectedProvider else { loading = false; loadedScope = requestScope; return }
            do {
                // Debounce prompt/cwd updates; no scanner or agent process stays running.
                try await Task.sleep(for: .milliseconds(180))
                let data = try await AgentHistoryService.run(["action": "skills", "workspace": path, "providers": [selectedProvider.rawValue]], in: state, operation: "Agent skills")
                let result = try JSONDecoder().decode(AgentSkillsResult.self, from: data)
                try Task.checkCancellation()
                guard scope == requestScope else { return }
                entries = result.skills; warnings = result.warnings; loadedScope = requestScope
            } catch {
                guard !Task.isCancelled, scope == requestScope else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

#if os(macOS)
struct ReverseAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ReverseAgentRequest
    @State private var hostID: HostID?
    @State private var provider: AgentProvider = .claude
    @State private var status: String?
    @State private var error: String?
    @State private var launchTask: Task<Void, Never>?
    private var busy: Bool { launchTask != nil }
    private var providers: [AgentProvider] {
        request.sessionID != nil || request.replacingTerminalID != nil ? [request.provider] : model.settings.enabledAgentProviders
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reverse Agent").font(.title3.weight(.semibold))
            Text("Use the server’s agent login to work in the current local folder.")
                .font(.callout).foregroundStyle(CrowTheme.textDim)
            VStack(alignment: .leading, spacing: 7) {
                Text("Agent server").font(.caption).foregroundStyle(CrowTheme.textDim)
                CrowChoiceMenu(title: "Server", selection: $hostID,
                    choices: [("Choose an SSH server", nil as HostID?)] + model.hosts.map { ($0.userAtHost, Optional($0.id)) }, showTitle: false)
                    .disabled(busy || request.sessionID != nil || request.replacingTerminalID != nil)
                if model.hosts.isEmpty { Text("Add an SSH host in Workspaces first.").font(.caption).foregroundStyle(CrowTheme.textDim) }
            }
            HStack(spacing: 8) {
                ForEach(providers) { value in
                    Button { provider = value } label: {
                        HStack(spacing: 7) { AgentProviderIcon(provider: value, size: 16); Text(value.title) }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(provider == value ? CrowTheme.bg3 : CrowTheme.bg1, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
            }.disabled(busy || request.sessionID != nil || request.replacingTerminalID != nil)
            if let status {
                HStack(spacing: 8) { if busy { ProgressView().controlSize(.small) }; Text(status).font(.caption) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(CrowTheme.danger).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { launchTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open Agent") { launch() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(busy || hostID == nil || !providers.contains(provider))
            }
        }.padding(22).frame(width: 480).background(CrowTheme.bg0)
            .onAppear {
                provider = providers.contains(request.provider) ? request.provider : providers.first ?? request.provider
                let previous = UserDefaults.standard.string(forKey: "crow.reverse-agent-last-host").flatMap(UUID.init(uuidString:)).map(HostID.init(rawValue:))
                hostID = request.hostID ?? model.hosts.first(where: { $0.id == previous })?.id ?? model.hosts.first?.id
            }
            .onDisappear { launchTask?.cancel() }
            .onChange(of: providers) { _, values in
                if !values.contains(provider), let first = values.first { provider = first }
            }
            .interactiveDismissDisabled(busy)
    }

    private func launch() {
        guard let host = model.hosts.first(where: { $0.id == hostID }) else { return }
        var value = request; value.provider = provider
        error = nil
        launchTask = Task { @MainActor in
            defer { launchTask = nil }
            do {
                try await model.launchReverseAgent(value, host: host) { status = $0 }
                dismiss()
            } catch is CancellationError {} catch { self.error = error.localizedDescription; status = nil }
        }
    }
}
#endif
