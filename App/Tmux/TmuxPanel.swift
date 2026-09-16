import CrowCore
import SwiftUI

struct TmuxPanel: View {
    @Environment(AppModel.self) private var model
    var workspace: WorkspaceState?
    var onAttach: (() -> Void)?
    private var expansionKey: String { target.snapshot.workspace.hostID?.rawValue.uuidString ?? "local" }
    private var expanded: Bool {
        get { model.tmuxExpansionStates[expansionKey]?.expanded ?? false }
        nonmutating set { model.tmuxExpansionStates[expansionKey, default: .init()].expanded = newValue }
    }
    @State private var sessions: [TmuxSession] = []
    @State private var busy = false
    @State private var error: String?
    @State private var editing = false
    @State private var renaming: TmuxSession?
    @State private var name = ""
    @State private var closing: CloseTarget?
    @State private var installWorkspace: WorkspaceState?
    private var collapsedSessions: Set<String> {
        get { model.tmuxExpansionStates[expansionKey]?.collapsedSessions ?? [] }
        nonmutating set { model.tmuxExpansionStates[expansionKey, default: .init()].collapsedSessions = newValue }
    }
    private var collapsedWindows: Set<String> {
        get { model.tmuxExpansionStates[expansionKey]?.collapsedWindows ?? [] }
        nonmutating set { model.tmuxExpansionStates[expansionKey, default: .init()].collapsedWindows = newValue }
    }

    private struct CloseTarget {
        let location: TmuxLocation
        let name: String
        var kind: String { location.paneID != nil ? "pane" : location.windowID != nil ? "window" : "session" }
        func command() throws -> String {
            if let pane = location.paneID { return try TmuxCommand.killPane(id: pane) }
            if let window = location.windowID { return try TmuxCommand.killWindow(sessionID: location.sessionID, windowID: window) }
            return try TmuxCommand.kill(id: location.sessionID)
        }
    }
    @State private var task: Task<Void, Never>?

    private var target: WorkspaceState { workspace ?? model.current }
    private var selectedLocation: TmuxLocation? {
        model.current.snapshot.workspace.hostID == target.snapshot.workspace.hostID ? model.selectedTmuxLocation : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                        Image(systemName: "rectangle.split.2x2")
                        Text("tmux").font(.system(size: 11))
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.accessibilityLabel(expanded ? "Collapse tmux" : "Expand tmux")
                if busy { ProgressView().controlSize(.small) }
                Button { if expanded { refresh() } else { expanded = true } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 28).contentShape(Rectangle())
                }.help("Refresh sessions").accessibilityLabel("Refresh sessions")
                Button { renaming = nil; name = ""; editing = true } label: {
                    Image(systemName: "plus").frame(width: 24, height: 28).contentShape(Rectangle())
                }.help("New tmux session").accessibilityLabel("New tmux session")
            }.buttonStyle(.plain).disabled(busy).font(.system(size: 11)).padding(.horizontal, 10).frame(height: 34)
            if let error {
                HStack(alignment: .center, spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    if error.contains("tmux is not installed") {
                        Button { installWorkspace = target } label: {
                            Text("Download").underline().font(.caption).fixedSize()
                        }.buttonStyle(.plain)
                            .help("Install tmux on this host").accessibilityLabel("Install tmux")
                            .accessibilityIdentifier("crow.tmux.install")
                    }
                }.padding(10)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    if sessions.isEmpty && !busy && error == nil {
                        Text("No tmux sessions. Use + to create one.").font(.caption).foregroundStyle(CrowTheme.textDim).padding(10)
                    }
                    ForEach(sessions) { session in sessionGroup(session) }
                }.disabled(busy)
                    .task(id: "\(target.id)-\(target.snapshot.workspace.connection)") { refresh() }
            }
        }.foregroundStyle(CrowTheme.text)
            .accessibilityIdentifier("crow.tmux.panel")
            .windowDragExcluded()
            .onDisappear { task?.cancel() }
            .alert("Install tmux?", isPresented: Binding(get: { installWorkspace != nil }, set: { if !$0 { installWorkspace = nil } }), presenting: installWorkspace) { state in
                Button("Install") {
                    guard model.states.contains(where: { $0 === state }) else { return }
                    guard !state.snapshot.workspace.isRemote || state.remote?.isConnected == true else {
                        error = "Connect this host before installing tmux."; return
                    }
                    model.activateWorkspace(state.id, reconnect: false)
                    model.openCommandTerminal(command: Self.installCommand)
                    onAttach?()
                }.keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { installWorkspace = nil }
            } message: { state in
                let device = state.snapshot.workspace.hostID.flatMap { id in model.hosts.first { $0.id == id }?.userAtHost } ?? "Local"
                Text("Install tmux on \(device) using its package manager?")
            }
            .alert(renaming == nil ? "New tmux session" : "Rename tmux session", isPresented: $editing) {
                TextField("Session name", text: $name)
                Button("Save") {
                    do {
                        let command = try renaming.map { try TmuxCommand.rename(id: $0.id, name: name) }
                            ?? TmuxCommand.create(name: name, directory: target.snapshot.rootPath)
                        perform(command)
                    } catch { self.error = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Close tmux \(closing?.kind ?? "session")?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
                Button("Close \(closing?.kind ?? "session")", role: .destructive) {
                    if let closing {
                        do { perform(try closing.command()) }
                        catch { self.error = error.localizedDescription }
                    }
                    closing = nil
                }.keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { closing = nil }
            } message: {
                Text("This ends the processes in “\(closing?.name ?? "")” for all attached clients. Closing the last pane also closes its window; closing the last window ends its session.")
            }
    }

    static let installCommand = TerminalCommand.environment + """
    if command -v tmux >/dev/null 2>&1; then tmux -V;
    elif command -v brew >/dev/null 2>&1; then brew install tmux;
    elif command -v apt-get >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y tmux;
    elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y tmux;
    elif command -v yum >/dev/null 2>&1; then sudo yum install -y tmux;
    elif command -v pacman >/dev/null 2>&1; then sudo pacman -S --needed tmux;
    elif command -v apk >/dev/null 2>&1; then sudo apk add tmux;
    elif command -v zypper >/dev/null 2>&1; then sudo zypper install tmux;
    else printf '%s\\n' 'Install a package manager (Homebrew on macOS), then install tmux.'; fi
    printf '\\n%s\\n' 'Return to the tmux panel and refresh after installation.'
    exec "${SHELL:-/bin/sh}" -l
    """

    private func sessionGroup(_ session: TmuxSession) -> some View {
        let location = TmuxLocation(sessionID: session.id)
        let selected = selectedLocation?.sessionID == session.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                disclosure(session.name, collapsed: collapsedSessions.contains(session.id)) {
                    toggle(session.id, in: &collapsedSessions)
                }
                Circle().fill(session.clients > 0 ? Color.green : CrowTheme.textDim).frame(width: 7, height: 7)
                Button { attach(location) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name).font(.system(size: 12)).lineLimit(1)
                        Text("\(session.windows) windows · \(session.clients) clients")
                            .font(.system(size: 10)).foregroundStyle(CrowTheme.textDim)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                Button { createWindow(in: session) } label: {
                    Image(systemName: "plus").frame(width: 22, height: 24).contentShape(Rectangle())
                }.help("New window").accessibilityLabel("New window in " + session.name)
                CrowMenu {
                    Button("New Window") { createWindow(in: session) }
                    Button("Attach") { attach(location) }
                    Button("Rename…") { renaming = session; name = session.name; editing = true }
                    Button("Close Session…", role: .destructive) { closing = .init(location: location, name: session.name) }
                } label: { Image(systemName: "ellipsis").frame(width: 22, height: 24) }
                    .fixedSize()
            }.padding(8)
                .background(selectedLocation == location ? CrowTheme.bg3 : .clear, in: RoundedRectangle(cornerRadius: 5))
            if !collapsedSessions.contains(session.id) {
                ForEach(session.windowList) { window in windowRow(window, session: session) }
            }
        }.buttonStyle(.plain).padding(3)
            .background(selected ? CrowTheme.bg2 : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6)
    }

    private func windowRow(_ window: TmuxWindow, session: TmuxSession) -> some View {
        let location = TmuxLocation(sessionID: session.id, windowID: window.id)
        let key = session.id + ":" + window.id
        let label = "\(window.index): \(window.name)"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                disclosure(label, collapsed: collapsedWindows.contains(key)) { toggle(key, in: &collapsedWindows) }
                Image(systemName: "macwindow").foregroundStyle(CrowTheme.textDim)
                Button { attach(location) } label: {
                    Text(label).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                if window.isActive { Circle().fill(CrowTheme.textDim).frame(width: 4, height: 4).help("Active window in tmux") }
                if let pane = window.panes.first(where: \.isActive) ?? window.panes.first {
                    splitButtons(.init(sessionID: session.id, windowID: window.id, paneID: pane.id))
                }
                closeButton(location, name: label)
            }.padding(.vertical, 5).padding(.horizontal, 8)
                .background(selectedLocation == location ? CrowTheme.bg3 : .clear, in: RoundedRectangle(cornerRadius: 5))
            if !collapsedWindows.contains(key) {
                ForEach(window.panes) { pane in
                    paneRow(pane, window: window, session: session).padding(.leading, 18)
                }
            }
        }.font(.system(size: 11)).padding(.leading, 18)
    }

    private func paneRow(_ pane: TmuxPane, window: TmuxWindow, session: TmuxSession) -> some View {
        let location = TmuxLocation(sessionID: session.id, windowID: window.id, paneID: pane.id)
        let label = "\(pane.index): \(pane.command)"
        return HStack(spacing: 6) {
            Image(systemName: "rectangle.split.2x1").foregroundStyle(CrowTheme.textDim)
            Button { attach(location) } label: {
                Text(label).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            if pane.isActive { Circle().fill(CrowTheme.textDim).frame(width: 4, height: 4).help("Active pane in tmux") }
            splitButtons(location)
            closeButton(location, name: "\(session.name) / \(window.index) / \(label)")
        }.padding(.vertical, 5).padding(.horizontal, 8)
            .background(selectedLocation == location ? CrowTheme.bg3 : .clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private func splitButtons(_ location: TmuxLocation) -> some View {
        HStack(spacing: 0) {
            Button { split(location, direction: .sideBySide) } label: {
                Image(systemName: "rectangle.split.2x1").frame(width: 22, height: 22).contentShape(Rectangle())
            }.help("Split pane left / right").accessibilityLabel("Split pane left / right")
            Button { split(location, direction: .stacked) } label: {
                Image(systemName: "rectangle.split.1x2").frame(width: 22, height: 22).contentShape(Rectangle())
            }.help("Split pane top / bottom").accessibilityLabel("Split pane top / bottom")
        }.font(.system(size: 10))
    }

    private func createWindow(in session: TmuxSession) {
        do { create(try TmuxCommand.newWindow(sessionID: session.id), sessionID: session.id) }
        catch { self.error = error.localizedDescription }
    }

    private func split(_ location: TmuxLocation, direction: TmuxCommand.SplitDirection) {
        do { create(try TmuxCommand.splitPane(location, direction: direction), sessionID: location.sessionID) }
        catch { self.error = error.localizedDescription }
    }

    private func create(_ command: String, sessionID: String) {
        task?.cancel()
        let state = target
        let selection = model.selectedWorkspaceID
        busy = true; error = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let output = try await model.runTmux(command, in: state)
                try Task.checkCancellation()
                let location = try TmuxCommand.parseCreated(output, sessionID: sessionID)
                guard model.selectedWorkspaceID == selection else { return }
                collapsedSessions.remove(sessionID)
                if let window = location.windowID { collapsedWindows.remove(sessionID + ":" + window) }
                try await model.attachTmux(location, in: state)
                let list = try await model.runTmux(TmuxCommand.list, in: state)
                try Task.checkCancellation()
                sessions = try TmuxCommand.parse(list)
                onAttach?()
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func closeButton(_ location: TmuxLocation, name: String) -> some View {
        Button { closing = .init(location: location, name: name) } label: {
            Image(systemName: "xmark").font(.system(size: 9)).frame(width: 22, height: 22).contentShape(Rectangle())
        }.help(location.paneID == nil ? "Close window" : "Close pane")
            .accessibilityLabel("Close \(name)")
    }

    private func disclosure(_ name: String, collapsed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 22).contentShape(Rectangle())
        }.accessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(name)")
    }

    private func toggle(_ id: String, in set: inout Set<String>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func attach(_ location: TmuxLocation) {
        let state = target
        task?.cancel()
        busy = true; error = nil
        task = Task { @MainActor in
            defer { busy = false }
            do { try await model.attachTmux(location, in: state); onAttach?() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    private func refresh() { perform(nil) }
    private func perform(_ command: String?) {
        task?.cancel()
        guard model.states.contains(where: { $0 === target }) else { return }
        let state = target
        busy = true; error = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                if let command { _ = try await model.runTmux(command, in: state) }
                let output = try await model.runTmux(TmuxCommand.list, in: state)
                try Task.checkCancellation()
                sessions = try TmuxCommand.parse(output)
                expanded = true
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription; sessions = [] } }
        }
    }
}
