import XCTest
import CrowCore
import SwiftTerm
import SwiftUI
@testable import Crow
#if os(macOS)
import AppKit

final class AgentTerminalIntegrationTests: XCTestCase {
    @MainActor func testCommandRunnerInheritsEnvironmentUnlessExplicitlyOverridden() async throws {
        let inheritedHome = try XCTUnwrap(ProcessInfo.processInfo.environment["HOME"])
        let inheritedPath = try XCTUnwrap(ProcessInfo.processInfo.environment["PATH"])
        let arguments = ["-c", "printf '%s\\n%s' \"$HOME\" \"$PATH\""]
        let output = try await ReverseSSHCommand.run("/bin/sh", arguments)
        XCTAssertEqual(output, inheritedHome + "\n" + inheritedPath)
        let overridden = try await ReverseSSHCommand.run("/bin/sh", arguments,
            environment: ["HOME": "/tmp/crow-command-fixture", "PATH": "/usr/bin:/bin"])
        XCTAssertEqual(overridden, "/tmp/crow-command-fixture\n/usr/bin:/bin")
    }

    @MainActor func testReverseSSHUsesConnectedProjectInsteadOfFirstHostWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-route-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let host = SSHHost(name: "Server", hostname: "192.0.2.39", username: "fixture")
        let other = SSHHost(name: "Other", hostname: "192.0.2.40", username: "fixture")
        func state(_ host: SSHHost, _ path: String, _ connection: ConnectionState, _ socket: String) -> WorkspaceState {
            let value = WorkspaceState(.init(workspace: Workspace(name: path, kind: .remote(hostID: host.id, path: path), connection: connection), rootPath: path))
            value.systemSSH = SystemSSHSpec(host: host, socket: socket, arguments: [], directory: root.path)
            return value
        }
        let stale = state(host, "/home/fixture", .disconnected, "/tmp/crow-stale-test.socket")
        let live = state(host, "/home/fixture/project", .connected, "/tmp/crow-live-test.socket")
        model.states.append(contentsOf: [state(other, "/home/other", .connected, "/tmp/crow-other-test.socket"), stale, live])
        XCTAssertEqual(model.connectedSystemSSH(for: host.id)?.socket, live.systemSSH?.socket)
        stale.snapshot.workspace.connection = .failed("Old connection failed")
        XCTAssertEqual(model.connectedSystemSSH(for: host.id)?.socket, live.systemSSH?.socket)
        live.snapshot.workspace.connection = .disconnected
        XCTAssertNil(model.connectedSystemSSH(for: host.id), "Never fall back to a stale socket or another host")
    }
    @MainActor func testBundledHistoryReaderStaysInRequestedWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-history-empty-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let result = try await AgentHistoryService.list(in: model.current)
        XCTAssertTrue(result.sessions.isEmpty, "Other folders' conversations must not appear in this workspace")
    }

    @MainActor func testResourceSamplingAndSleepAssertionLifecycle() {
        let status = DeviceStatusState()
        status.sampleResources()
        XCTAssertGreaterThan(status.memory, 0)
        XCTAssertGreaterThanOrEqual(status.cpu, 0)
        status.toggleAwake()
        XCTAssertTrue(status.awake); XCTAssertNil(status.error)
        if status.awake { status.toggleAwake() }
        XCTAssertFalse(status.awake)
    }
    @MainActor func testOnlyWorkingSessionsAskBeforeClosing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-close-state-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.newTerminal()
        let ready = try XCTUnwrap(model.current.snapshot.selectedTerminalID)
        model.requestTerminalClose(ready)
        XCTAssertNil(model.terminalCloseRequest); XCTAssertFalse(model.current.snapshot.terminalIDs.contains(ready))
        let id = try XCTUnwrap(model.newAgentTerminal(.claude))
        let session = model.terminal(id, in: model.current); session.running = true
        session.view.feed(text: "Working (esc to interrupt)\r\n")
        model.requestTerminalClose(id)
        XCTAssertEqual(model.terminalCloseRequest, id); XCTAssertTrue(model.current.snapshot.terminalIDs.contains(id))
        session.view.feed(text: "\u{1b}[2J\u{1b}[HDo you want to proceed?\r\n❯ 1. Yes\r\n2. No\r\n")
        model.terminalCloseRequest = nil
        model.requestTerminalClose(id)
        XCTAssertNil(model.terminalCloseRequest); XCTAssertFalse(model.current.snapshot.terminalIDs.contains(id))
    }

    @MainActor func testRemovingHostAlsoRemovesItsWorkspaces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-remove-host-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let host = SSHHost(name: "Test", hostname: "192.0.2.50", username: "fixture")
        model.hosts = [host]
        for path in ["/first", "/second"] { model.states.append(WorkspaceState(.init(workspace: .init(name: path, kind: .remote(hostID: host.id, path: path), connection: .disconnected), rootPath: path))) }
        model.removeHost(host)
        XCTAssertFalse(model.hosts.contains { $0.id == host.id })
        XCTAssertFalse(model.workspaceHostIDs.contains(host.id))
        XCTAssertFalse(model.states.contains { $0.snapshot.workspace.hostID == host.id })
    }

    func testSSHPasswordSelectionOverridesConfigWithoutChangingDestination() throws {
        let line = try SSHCommandView.connectionCommand("ssh -p 2222 user@host", authentication: "password", identityPath: "")
        let args = try SSHCommand(line).arguments
        XCTAssertEqual(Array(args.suffix(3)), ["-p", "2222", "user@host"])
        XCTAssertTrue(args.contains("PubkeyAuthentication=no")); XCTAssertTrue(args.contains("PreferredAuthentications=keyboard-interactive,password"))
    }
    @MainActor func testAgentUsesRegularTerminalLifecycleAndMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crow-agent-terminal-" + UUID().uuidString)
        let model = AppModel(vaultURL: directory)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        model.newTab()
        let paneID = try XCTUnwrap(model.current.snapshot.layout?.activePaneID)
        model.newAgentTerminal(.codex, in: paneID)
        let agent = try XCTUnwrap(model.current.snapshot.agentTerminals.last)
        XCTAssertEqual(model.current.snapshot.layout?.activePane?.selected, .terminal(agent.id))
        let session = model.terminal(agent.id, in: model.current)
        XCTAssertEqual(session.launchCommand, AgentProvider.codex.command(directory: directory.path))
        XCTAssertFalse(session.running)
        model.renameAgentTerminal(agent.id, workspaceID: model.current.id, name: "Task")
        model.pinAgentTerminal(agent.id, workspaceID: model.current.id)
        XCTAssertEqual(model.current.snapshot.agentTerminals.first?.title, "Task")
        XCTAssertEqual(model.current.snapshot.agentTerminals.first?.isPinned, true)
        model.closeTerminal(agent.id)
        XCTAssertTrue(model.current.snapshot.agentTerminals.isEmpty)
        XCTAssertNil(model.current.terminals[agent.id])
        XCTAssertFalse(model.current.snapshot.layout?.allTabs.contains(.terminal(agent.id)) ?? true)
    }

    @MainActor func testTmuxPanelDoesNotInterceptClicksForWindowDragging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-tmux-hit-test-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let hosting = NSHostingView(rootView: TmuxPanel().environment(model).windowDragBackground())
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.orderFront(nil)
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded()
        let surface = try XCTUnwrap(hosting.superview?.subviews.compactMap { $0 as? WindowMoveSurface }.first)
        let center = hosting.convert(NSPoint(x: hosting.bounds.midX, y: hosting.bounds.midY), to: surface)
        XCTAssertFalse(surface.containsRegion(center), "The tmux panel must receive clicks instead of starting a window drag")
    }

    @MainActor func testAgentActivityTracksRealPTYOutputAndStopsWithTheTerminal() async throws {
        let session = TerminalSession(id: UUID(), workspace: Workspace(name: "Agent", kind: .local, connection: .local),
            directory: "/tmp", remote: nil, fontSize: 16)
        session.agentProvider = .claude
        session.shellEnvironment = ["PATH=/usr/bin:/bin", "LANG=en_US.UTF-8", "ZDOTDIR=/tmp/crow-empty-zdotdir"]
        session.launchCommand = """
        printf '\\033[2J\\033[HWorking (1s · esc to interrupt)\\r\\n❯ '; read -r first
        printf '\\033[2J\\033[HDo you want to proceed?\\r\\n❯ 1. Yes\\r\\n2. No'; read -r second
        printf '\\033[2J\\033[HDone.\\r\\n❯ '; read -r third
        """
        session.start()
        defer { session.stop() }
        func wait(_ expected: AgentActivity) async throws {
            for _ in 0..<120 {
                if session.agentActivity == expected { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("Expected \(expected), got \(session.agentActivity)")
        }
        try await wait(.working)
        session.view.insertText("next\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await wait(.needsInput)
        session.view.insertText("next\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await wait(.idle)
        session.view.insertText("a draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(session.agentActivity, .idle, "Typing a draft must not mark the agent as working")
        session.stop()
        XCTAssertFalse(session.running)
        XCTAssertEqual(session.agentActivity, .unknown)
    }

    @MainActor func testAgentActivityIgnoresScrolledBackApprovalPrompts() {
        let session = TerminalSession(id: UUID(), workspace: Workspace(name: "Agent", kind: .local, connection: .local),
            directory: "/tmp", remote: nil, fontSize: 16)
        session.agentProvider = .claude; session.running = true
        session.view.feed(text: "Do you want to proceed?\r\n❯ 1. Yes\r\n2. No\r\n")
        session.view.feed(text: String(repeating: "Completed output\r\n", count: 100) + "Done.\r\n❯ ")
        let terminal = session.view.getTerminal()
        terminal.buffer.yDisp = 0
        session.updateAgentActivity(outputIsRecent: false)
        XCTAssertEqual(session.agentActivity, .idle)
        XCTAssertEqual(terminal.buffer.yDisp, 0, "Status detection must not move the user's scroll position")
        session.stop()
    }

    @MainActor func testSSHImportIgnoresSocketsFromFinishedTerminalCommands() async throws {
        let bridge = try SystemSSHBridge()
        defer { bridge.stop() }
        let request = bridge.root.appendingPathComponent("r.fixture")
        try FileManager.default.createDirectory(at: request, withIntermediateDirectories: false)
        let args = ["-F", "/dev/null", "-l", "fixture", "192.0.2.8"]
        try Data((args.joined(separator: "\0") + "\0").utf8).write(to: request.appendingPathComponent("args"))
        try Data("/tmp".utf8).write(to: request.appendingPathComponent("cwd"))
        try Data().write(to: request.appendingPathComponent("s"))
        var imported: [SystemSSHSpec] = []
        bridge.onConnection = { imported.append($0) }
        await bridge.poll()
        XCTAssertTrue(imported.isEmpty, "A lingering ControlPersist socket is not a live terminal connection")
        try Data().write(to: request.appendingPathComponent("active"))
        await bridge.poll()
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.host.hostname, "192.0.2.8")
        await bridge.poll()
        XCTAssertEqual(imported.count, 1, "The same live terminal must only be imported once")
    }

    @MainActor func testReversePasswordPersistsAndRevokesAllSessionsOnChange() async throws {
        let account = "reverse-password-test-" + UUID().uuidString
        defer { try? SecureStore.remove(account) }
        let access = ReverseSSHAccessSettings(account: account)
        XCTAssertNil(try access.password())
        try access.save("initial password")
        XCTAssertEqual(try ReverseSSHAccessSettings(account: account).password(), "initial password")
        let first = ReverseSSHSession(), second = ReverseSSHSession()
        defer { first.stop(); second.stop() }
        for session in [first, second] {
            session.start(password: "initial password") {
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }
        }
        XCTAssertThrowsError(try access.save("short"))
        XCTAssertThrowsError(try access.save("line one\nline two"))
        XCTAssertTrue(first.isEnabled)
        XCTAssertEqual(try access.password(), "initial password")
        try access.save("changed password")
        XCTAssertFalse(first.isEnabled)
        XCTAssertFalse(second.isEnabled)
        XCTAssertEqual(try access.password(), "changed password")
        await first.stopAndWait(); await second.stopAndWait()
    }

    @MainActor func testWorkspaceListSortsHostsByConnectionAndProjectsByName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-sort-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var older = SSHHost(name: "Older", hostname: "192.0.2.1", username: "fixture")
        var newer = SSHHost(name: "Newer", hostname: "192.0.2.2", username: "fixture")
        older.lastConnectedAt = Date(timeIntervalSince1970: 100)
        newer.lastConnectedAt = Date(timeIntervalSince1970: 200)
        model.hosts = [older, newer]
        let local = model.current
        local.snapshot.workspace.name = "zebra"
        for name in ["Zebra", "alpha", "Beta"] {
            let workspace = Workspace(name: name, kind: .remote(hostID: older.id, path: "/" + name), connection: .disconnected)
            let state = WorkspaceState(.init(workspace: workspace, rootPath: "/" + name))
            state.snapshot.lastOpenedAt = Date(timeIntervalSince1970: 999)
            model.states.append(state)
        }
        let otherLocal = WorkspaceState(.init(workspace: Workspace(name: "Alpha", kind: .local, connection: .local), rootPath: root.path))
        model.states.append(otherLocal)
        XCTAssertEqual(model.workspaceHostIDs, [newer.id, older.id])
        XCTAssertEqual(model.alphabetizedWorkspaces(on: older.id).map { $0.snapshot.workspace.name }, ["alpha", "Beta", "Zebra"])
        XCTAssertEqual(model.alphabetizedWorkspaces(on: nil).map { $0.snapshot.workspace.name }, ["Alpha", "zebra"])
        model.recordHostConnection(older.id)
        XCTAssertEqual(model.workspaceHostIDs, [older.id, newer.id])
        XCTAssertEqual(model.alphabetizedWorkspaces(on: older.id).map { $0.snapshot.workspace.name }, ["alpha", "Beta", "Zebra"])
    }

    @MainActor func testUnifiedTmuxRoutingNeverFallsBackToAnotherHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-host-routing-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let local = model.current
        let host = SSHHost(name: "Offline", hostname: "192.0.2.8", username: "fixture")
        model.hosts = [host]
        let remote = WorkspaceState(.init(workspace: Workspace(name: "Remote", kind: .remote(hostID: host.id, path: "/tmp"), connection: .disconnected), rootPath: "/tmp"))
        model.states.append(remote)
        XCTAssertTrue(model.tmuxWorkspace(on: nil) === local)
        XCTAssertNil(model.tmuxWorkspace(on: host.id), "A disconnected host must never use the local command runner")
        model.activateWorkspace(remote.id, reconnect: false)
        XCTAssertTrue(model.tmuxWorkspace(on: nil) === local, "Local tmux remains local while viewing an SSH workspace")
        XCTAssertNil(model.tmuxWorkspace(on: host.id))
        model.showWorkspaces()
        XCTAssertEqual(model.sidebarPane, .workspaces)
        XCTAssertEqual(model.compactSurface, .hosts)
    }

    @MainActor func testTmuxReusesOnlyLiveTerminalsInTheCurrentWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-tmux-routing-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let state = model.current
        let firstID = try XCTUnwrap(state.snapshot.selectedTerminalID)
        let first = model.terminal(firstID, in: state)
        first.tmuxLocation = .init(sessionID: "$0", windowID: "@1")
        first.running = true
        model.newTerminal()
        let secondID = try XCTUnwrap(state.snapshot.selectedTerminalID)
        let second = model.terminal(secondID, in: state)
        second.tmuxLocation = .init(sessionID: "$0", windowID: "@2")
        second.running = true
        XCTAssertTrue(model.attachedTmuxTerminal(for: "$0", in: state) === second)
        second.running = false
        XCTAssertTrue(model.attachedTmuxTerminal(for: "$0", in: state) === first)
        XCTAssertNil(model.attachedTmuxTerminal(for: "$1", in: state))
        let other = WorkspaceState(.init(workspace: Workspace(name: "Other host", kind: .local, connection: .local), rootPath: root.path))
        XCTAssertNil(model.attachedTmuxTerminal(for: "$0", in: other))
        model.closeTerminal(firstID)
        XCTAssertNil(model.attachedTmuxTerminal(for: "$0", in: state))
    }

    @MainActor func testWorkspaceSelectionRestoresTabsAndReusesLocalFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-workspace-selection-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let first = model.current
        let bufferID = try XCTUnwrap(model.selectedBufferID)
        model.updateBufferText(bufferID, "unsaved workspace text")
        let folder = root.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.openFolder(folder)
        let second = model.current
        XCTAssertFalse(first === second)
        model.newTerminal()
        let terminalID = try XCTUnwrap(second.snapshot.selectedTerminalID)
        let terminal = model.terminal(terminalID, in: second)
        model.sidebarPane = .workspaces
        model.activateWorkspace(first.id)
        XCTAssertEqual(model.selectedBufferID, bufferID)
        XCTAssertEqual(model.selectedBuffer?.text, "unsaved workspace text")
        XCTAssertEqual(model.sidebarPane, .workspaces)
        model.activateWorkspace(second.id)
        XCTAssertEqual(model.current.snapshot.selectedTerminalID, terminalID)
        XCTAssertTrue(model.terminal(terminalID, in: model.current) === terminal)
        model.openFolder(folder)
        XCTAssertEqual(model.current.id, second.id)
        XCTAssertEqual(model.states.count, 2)
        model.pinWorkspace(second.id)
        model.persist()
        let restored = AppModel(vaultURL: root)
        defer { restored.shutdown() }
        XCTAssertTrue(restored.current.snapshot.isPinned)
        XCTAssertNotNil(restored.current.snapshot.lastOpenedAt)
    }

    @MainActor func testLaunchCommandRunsOnceInsideRealPTY() async throws {
        let workspace = Workspace(name: "Local", kind: .local, connection: .local)
        let session = TerminalSession(id: UUID(), workspace: workspace, directory: "/tmp", remote: nil, fontSize: 16)
        session.launchCommand = "printf '__CROW_LAUNCH__'; test -t 0 && printf '__PTY__'; exec /bin/cat"
        session.start(); session.start()
        defer { session.stop() }
        for _ in 0..<100 {
            let terminal = session.view.getTerminal()
            let text = (0..<terminal.rows).compactMap { row in
                terminal.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true, characterProvider: terminal.getCharacter(for:))
            }.joined(separator: "\n")
            if text.contains("__CROW_LAUNCH____PTY__") {
                XCTAssertEqual(text.components(separatedBy: "__CROW_LAUNCH__").count, 2)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Launch command did not receive a PTY")
    }

    @MainActor func testCLIAndTmuxCommandsPreserveLiteralWorkingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-command-" + UUID().uuidString)
        let directory = root.appendingPathComponent("project '$(touch should-not-exist)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for executable in AgentProvider.allCases.map(\.rawValue) + ["tmux"] {
            let url = root.appendingPathComponent(executable)
            try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\"\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let prefix = "export PATH=" + TerminalCommand.quote(root.path) + ":$PATH; "
        for provider in AgentProvider.allCases {
            let output = try await ReverseSSHCommand.run("/bin/zsh", ["-lc", prefix + provider.command(directory: directory.path)])
            XCTAssertEqual(output.components(separatedBy: "\n"), [directory.resolvingSymlinksInPath().path] + provider.arguments)
        }
        let create = try TmuxCommand.create(name: "work space", directory: directory.path)
        let output = try await ReverseSSHCommand.run("/bin/zsh", ["-lc", prefix + create])
        XCTAssertEqual(Array(output.components(separatedBy: "\n").prefix(6)), [directory.resolvingSymlinksInPath().path, "-u", "new-session", "-d", "-s", "work space"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path))
    }

    @MainActor func testTmuxListRunnerHandlesEmptyServerAndErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crow-tmux-fixture-" + UUID().uuidString)
        let model = AppModel(vaultURL: directory.appendingPathComponent("vault"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("tmux")
        func fixture(_ body: String) throws {
            try ("#!/bin/sh\n" + body).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let command = "export PATH=" + TerminalCommand.quote(directory.path) + ":$PATH; " + TmuxCommand.list
        try fixture("printf '%s\\n' 'no server running on /tmp/test' >&2; exit 1")
        let empty = try await model.runTmux(command, in: model.current)
        XCTAssertEqual(try TmuxCommand.parse(empty), [])
        try fixture("""
        case "$2" in
          list-sessions) printf '%s\\n' 'CROW_TMUX|$3|1|1|project' ;;
          list-windows) printf '%s\\n' 'CROW_WINDOW|$3|@1|0|1|한글' ;;
          list-panes) printf '%s\\n' 'CROW_PANE|$3|@1|%2|0|1|zsh' ;;
        esac
        """)
        let populated = try await model.runTmux(command, in: model.current)
        let sessions = try TmuxCommand.parse(populated)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.windowList.first?.name, "한글")
        XCTAssertEqual(sessions.first?.windowList.first?.panes.first?.id, "%2")
        try fixture("printf '%s\\n' 'permission denied' >&2; exit 1")
        do { _ = try await model.runTmux(command, in: model.current); XCTFail("Expected error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("permission denied")) }
    }
}
#endif
