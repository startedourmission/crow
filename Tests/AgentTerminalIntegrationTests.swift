import XCTest
import CrowCore
import SwiftTerm
import SwiftUI
@testable import Crow
#if os(macOS)
import AppKit
import Network
import CryptoKit

final class AgentTerminalIntegrationTests: XCTestCase {
    func testManagedPairingRejectsInvalidSecretsAndVersions() throws {
        let pairing = ManagedPairing(id: UUID(), secret: Data(repeating: 7, count: 32), port: 44822)
        XCTAssertEqual(try ManagedPairing.decode(pairing.code).secret, pairing.secret)
        XCTAssertThrowsError(try ManagedPairing.decode("not-a-pairing-code"))
        XCTAssertThrowsError(try ManagedPairing(id: UUID(), secret: Data(), port: 44822).validated())
        var obsolete = pairing; obsolete.version = 2
        XCTAssertThrowsError(try obsolete.validated())
    }

    func testManagedEnrollmentNeverExportsPlaintextSecret() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let other = Curve25519.KeyAgreement.PrivateKey()
        let pairing = ManagedPairing(id: UUID(), secret: Data(repeating: 79, count: 32), port: 44822)
        let envelope = try ManagedPairingEnvelope.seal(pairing, to: key.publicKey.rawRepresentation)
        let encoded = try envelope.code
        let decoded = try ManagedPairingEnvelope.decode(encoded)
        XCTAssertEqual(try decoded.open(using: key).secret, pairing.secret)
        XCTAssertThrowsError(try decoded.open(using: other), "A copied server clipboard code must be useless on another Mac")
        let json = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains(pairing.secret.base64EncodedString()))
        XCTAssertEqual(decoded.fingerprint, ManagedPairingEnvelope.fingerprint(pairing.secret))
        var damaged = decoded.ciphertext; damaged[damaged.startIndex] ^= 1
        let changed = ManagedPairingEnvelope(version: 1, recipient: decoded.recipient, ephemeral: decoded.ephemeral,
            ciphertext: damaged, fingerprint: decoded.fingerprint)
        XCTAssertThrowsError(try changed.open(using: key))
        let wrongFingerprint = ManagedPairingEnvelope(version: 1, recipient: decoded.recipient, ephemeral: decoded.ephemeral,
            ciphertext: decoded.ciphertext, fingerprint: String(repeating: "0", count: 32))
        XCTAssertThrowsError(try wrongFingerprint.open(using: key))
        XCTAssertThrowsError(try ManagedPairingEnvelope.decode(pairing.code), "Legacy plaintext codes are not accepted")
    }

    func testManagedTLSAcceptsOnlyPairedClient() throws {
        let pairing = ManagedPairing(id: UUID(), secret: Data(repeating: 37, count: 32), port: 44822)
        let parameters = try ManagedWire.parameters(pairing)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "TLS listener ready")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            DispatchQueue.global().async {
                let wire = ManagedWire(connection); defer { wire.close() }
                do { try wire.begin(); let request = try wire.receive(); try wire.send(.init(kind: "pong", text: request.text)) }
                catch { /* A different pairing key must be rejected during TLS authentication. */ }
            }
        }
        listener.start(queue: .global()); defer { listener.cancel() }
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let accepted = ManagedWire(NWConnection(host: "127.0.0.1", port: port, using: try ManagedWire.parameters(pairing)))
        defer { accepted.close() }
        try accepted.begin(); try accepted.send(.init(kind: "ping", text: "한글 frame"))
        XCTAssertEqual(try accepted.receive().text, "한글 frame")
        let wrong = ManagedPairing(id: pairing.id, secret: Data(repeating: 38, count: 32), port: pairing.port)
        let rejected = ManagedWire(NWConnection(host: "127.0.0.1", port: port, using: try ManagedWire.parameters(wrong)))
        defer { rejected.close() }
        XCTAssertThrowsError(try rejected.begin())
    }

    func testManagedReverseUsesKernelPeerIdentity() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { descriptors.forEach { Darwin.close($0) } }
        XCTAssertTrue(ManagedUnix.authorizedPeer(descriptors[0], uid: geteuid()))
        XCTAssertFalse(ManagedUnix.authorizedPeer(descriptors[0], uid: geteuid() + 1), "A different execution UID cannot use the agent's connection")
        XCTAssertFalse(ManagedUnix.authorizedPeer(-1, uid: geteuid()))
    }

    func testManagedFileAccessRejectsEscapesAndClosesOnRevocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-managed-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("allowed")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.linkItem(at: outside, to: folder.appendingPathComponent("hard-link"))
        let access = try ManagedLocalAccess(root: folder.path, commandsAllowed: false)
        _ = try access.perform(.init(kind: "reverse", data: Data("한글".utf8), arguments: ["write", "message.md"]))
        let read = try access.perform(.init(kind: "reverse", arguments: ["read", "message.md"]))
        XCTAssertEqual(String(decoding: read.data ?? Data(), as: UTF8.self), "한글")
        for path in ["../outside", outside.path, "escape", "hard-link"] {
            XCTAssertThrowsError(try access.perform(.init(kind: "reverse", arguments: ["read", path])))
            XCTAssertThrowsError(try access.perform(.init(kind: "reverse", data: Data("bad".utf8), arguments: ["write", path])))
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
        XCTAssertThrowsError(try access.perform(.init(kind: "reverse", arguments: ["exec", "pwd"])))
        access.close()
        XCTAssertThrowsError(try access.perform(.init(kind: "reverse", arguments: ["list"])))
    }

    func testManagedLocalCommandsAreBoundedAndCancellable() throws {
        let result = try ManagedCommand().run("/bin/sh", ["-c", "printf 'hello\\n'"])
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "hello\n")
        XCTAssertThrowsError(try ManagedCommand().run("/bin/sleep", ["10"], timeout: 0.15))
        let command = ManagedCommand(); command.cancel()
        XCTAssertThrowsError(try command.run("/usr/bin/true", []))
    }

    func testManagedMetadataSurvivesRestoreWithoutSecrets() throws {
        var agent = AgentTerminal(provider: .codex, directory: "/Users/server/project")
        agent.isManagedReverse = true
        let data = try JSONEncoder().encode(agent)
        let restored = try JSONDecoder().decode(AgentTerminal.self, from: data)
        XCTAssertEqual(restored.isManagedReverse, true)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
    }

    func testManagedProjectACLGrantRevokesWithoutFollowingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-managed-acl-" + UUID().uuidString).resolvingSymlinksInPath()
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("file")
        let outside = root.appendingPathComponent("outside")
        try Data("inside".utf8).write(to: file); try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("symlink"), withDestinationURL: outside)
        try FileManager.default.linkItem(at: outside, to: project.appendingPathComponent("hard-link"))
        let identity = UUID()
        let canonical = try XCTUnwrap(realpath(project.path, nil)); defer { free(canonical) }
        let grant = try ManagedProjectGrant(path: String(cString: canonical), uid: geteuid(), owner: geteuid(), identity: identity)
        defer { grant.revoke() }
        func hasEntry(_ path: URL) throws -> Bool {
            let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EIO) }; defer { Darwin.close(fd) }
            guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return false }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?, cursor = Int32(ACL_FIRST_ENTRY.rawValue)
            while acl_get_entry(acl, cursor, &entry) == 0, let entry {
                cursor = Int32(ACL_NEXT_ENTRY.rawValue)
                if let value = acl_get_qualifier(entry) {
                    let matches = withUnsafeBytes(of: identity.uuid) { memcmp(value, $0.baseAddress!, 16) == 0 }
                    acl_free(value); if matches { return true }
                }
            }
            return false
        }
        // System-managed temporary ancestors reject ACL changes even by their owner.
        // Exercise the owned project; parent traversal grants require the privileged server check.
        try grant.grantProject()
        XCTAssertTrue(try hasEntry(project)); XCTAssertTrue(try hasEntry(file))
        XCTAssertFalse(try hasEntry(outside), "Links inside a project must not grant access outside it")
        grant.revoke()
        XCTAssertFalse(try hasEntry(project)); XCTAssertFalse(try hasEntry(file))
    }

    @MainActor func testManagedRestoredTerminalCannotFallbackToOrdinarySSH() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-managed-restore-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.newAgentTerminal(.codex))
        let index = try XCTUnwrap(model.current.snapshot.agentTerminals.firstIndex { $0.id == id })
        model.current.snapshot.agentTerminals[index].isManagedReverse = true
        model.current.terminals.removeValue(forKey: id)?.stop()
        let terminal = model.terminal(id, in: model.current)
        XCTAssertTrue(terminal.requiresManagedAgent)
        XCTAssertNil(terminal.managedLaunch)
        terminal.start()
        XCTAssertFalse(terminal.running)
        XCTAssertTrue(terminal.status.contains("Open a new reverse agent"))
    }

    @MainActor func testManagedPairingRevocationIncludesOtherWindowsAndPendingLaunches() {
        let host = HostID(rawValue: UUID()), otherHost = HostID(rawValue: UUID())
        let sessions = (0..<3).map { _ in
            let session = TerminalSession(id: UUID(), workspace: Workspace(name: "Fixture", kind: .local, connection: .local),
                directory: "/tmp", remote: nil, fontSize: 14)
            session.requiresManagedAgent = true; session.managedLaunch = "fixture"
            return session
        }
        defer { sessions.forEach { $0.stop() }; AppModel.revokeManagedAgents(hostID: otherHost) }
        AppModel.registerManagedAgent(sessions[0], hostID: host)
        AppModel.registerManagedAgent(sessions[1], hostID: host)
        AppModel.registerManagedAgent(sessions[2], hostID: otherHost)
        AppModel.revokeManagedAgents(hostID: host)
        XCTAssertNil(sessions[0].managedLaunch); XCTAssertNil(sessions[1].managedLaunch)
        XCTAssertEqual(sessions[2].managedLaunch, "fixture")
    }

    func testManagedAdministrationRequiresRoot() throws {
        guard geteuid() != 0 else { throw XCTSkip("Run this rejection test without administrator privileges") }
        XCTAssertThrowsError(try ManagedSystem.requireRoot())
        XCTAssertThrowsError(try ManagedSystem.setup())
        XCTAssertThrowsError(try ManagedSystem.config())
        XCTAssertThrowsError(try ManagedSystem.resetPairing())
        XCTAssertThrowsError(try ManagedSystem.installAgent(provider: .codex, source: "/usr/bin/true"))
    }

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

    @MainActor func testTmuxFocusUpdatesFolderWithoutChangingSavedWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-tmux-context-" + UUID().uuidString)
        let folder = root.appendingPathComponent("pane-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let state = model.current, original = state.snapshot.rootPath
        model.newTerminal()
        let id = try XCTUnwrap(state.snapshot.selectedTerminalID)
        let session = model.terminal(id, in: state)
        session.running = true; session.tmuxLocation = .init(sessionID: "$3")
        let focus = TmuxFocus(location: .init(sessionID: "$3", windowID: "@2", paneID: "%9"), directory: folder.path)
        model.applyTmuxFocus(focus, in: state, terminalID: id)
        XCTAssertEqual(state.contextRootPath, folder.path)
        XCTAssertEqual(state.explorer.rootPath, folder.path)
        XCTAssertEqual(state.snapshot.rootPath, original)
        XCTAssertEqual(session.tmuxLocation, focus.location)
        let agentID = try XCTUnwrap(model.newAgentTerminal(.codex))
        XCTAssertEqual(state.snapshot.agentTerminals.first { $0.id == agentID }?.directory, folder.path)
        model.applyTmuxFocus(.init(location: focus.location, directory: "/stale"), in: state, terminalID: id)
        XCTAssertEqual(state.contextRootPath, folder.path, "Ignore a result for a terminal that lost focus")
        model.clearTmuxContext(in: state)
        XCTAssertEqual(state.contextRootPath, original)
        XCTAssertEqual(state.explorer.rootPath, original)
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

    @MainActor func testLegacyReverseConnectorCannotRunOnAnyHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-platform-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let uname = root.appendingPathComponent("uname"), ssh = root.appendingPathComponent("ssh")
        try "#!/bin/sh\nprintf CROW_TEST_SSH_STARTED\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let environment = ["PATH": root.path + ":/usr/bin:/bin"]
        let script = ReverseSSHConnector.script(path: root.path, port: 2222, username: "fixture", passwordRequired: true)
        for system in ["Linux", "MINGW64_NT", "FreeBSD", "Darwin"] {
            try ("#!/bin/sh\nprintf '%s\\n' '" + system + "'\n").write(to: uname, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: uname.path)
            let output = try await ReverseSSHCommand.run("/bin/sh", ["-c", ReverseSSHConnector.supportedHostCommand], environment: environment)
            XCTAssertEqual(ReverseSSHConnector.supportsHost(output), system == "Darwin")
            do {
                _ = try await ReverseSSHCommand.run("/bin/sh", ["-c", script], environment: environment)
                XCTFail("Legacy connectors must not execute ssh on any OS")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(ReverseSSHAccessPolicy.unavailableMessage))
                XCTAssertFalse(error.localizedDescription.contains("CROW_TEST_SSH_STARTED"))
            }
        }
        XCTAssertTrue(ReverseSSHConnector.supportsHost("Welcome\r\nCROW_REVERSE_MACOS\r\n"))
        for output in ["", "Darwin", "CROW_REVERSE_MACOS\nCROW_REVERSE_UNSUPPORTED", "CROW_REVERSE_MACOS\nCROW_REVERSE_MACOS"] {
            XCTAssertFalse(ReverseSSHConnector.supportsHost(output))
        }
    }

    @MainActor func testLegacyReverseAccessCannotStartEvenWithSavedPassword() async throws {
        let account = "reverse-password-test-" + UUID().uuidString
        defer { try? SecureStore.remove(account) }
        let access = ReverseSSHAccessSettings(account: account)
        try access.save("previous access password")
        let password = try XCTUnwrap(access.password())
        let session = ReverseSSHSession()
        defer { session.stop() }
        var requestedConnection = false, copiedCommand = false
        session.start(password: password, onReady: { _ in copiedCommand = true }) {
            requestedConnection = true
            throw CommandError("Must not connect")
        }
        await Task.yield()
        XCTAssertFalse(requestedConnection)
        XCTAssertFalse(copiedCommand)
        XCTAssertFalse(session.isEnabled)
        XCTAssertNil(session.connectCommand)
        XCTAssertEqual(session.status, ReverseSSHAccessPolicy.unavailableMessage)
        for credential in [nil, Optional(password)] {
            do {
                let server = try await ReverseSSHServer.create(password: credential)
                server.stop()
                XCTFail("Must not open a reverse SSH listener")
            } catch {
                XCTAssertEqual(error.localizedDescription, ReverseSSHAccessPolicy.unavailableMessage)
            }
        }
    }

    @MainActor func testLegacyReverseHostActionsCannotIssueAccessCommands() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-disabled-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { model.shutdown(); pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        model.reverseSSHPasteboard = pasteboard
        pasteboard.setString("existing clipboard", forType: .string)
        let host = SSHHost(name: "Fixture", hostname: "192.0.2.1", username: "fixture")
        model.hosts = [host]
        model.setReverseSSH(true, for: host)
        XCTAssertTrue(model.reverseSSHConnections.isEmpty)
        XCTAssertFalse(model.settingsVisible)
        XCTAssertEqual(model.statusMessage, ReverseSSHAccessPolicy.unavailableMessage)
        model.copyReverseSSHCommand(for: host)
        XCTAssertEqual(pasteboard.string(forType: .string), "existing clipboard")
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
