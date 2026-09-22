import XCTest
import CrowCore
import SwiftTerm
import SwiftUI
import Observation
@testable import Crow
#if os(macOS)
import AppKit

final class AgentTerminalIntegrationTests: XCTestCase {
    @MainActor func testCrowmapAgentsKeepMapOwnershipAndHistoryScopeAcrossTabFocus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-map-agents-" + UUID().uuidString)
        let folder = root.appendingPathComponent(".crow/crowmap/Plan"), map = folder.appendingPathComponent("Plan.crowmap")
        let session = folder.appendingPathComponent(".sessions/selected-notes")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: map)
        let model = AppModel(vaultURL: root)
        model.crowmap = CrowmapStore(root: folder.deletingLastPathComponent())
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let owner = model.current, ownerID = owner.id
        let id = try XCTUnwrap(model.newAgentTerminal(.codex, directory: session.path, reuseTmux: false, crowmapPath: map.path))
        XCTAssertEqual(model.current.id, ownerID, "A map agent remains an ordinary tab")
        XCTAssertEqual(owner.selectedAgent?.crowmapDirectory, folder.path)
        XCTAssertEqual(owner.agentHistoryPath, folder.path)
        XCTAssertEqual(model.crowmapAgents(in: folder).map(\.id), [id])
        XCTAssertTrue(model.crowmapAgents(in: root.appendingPathComponent("Other")).isEmpty)
        XCTAssertEqual(model.sidebarPane, .workspaces, "Map agents retain the upper sidebar while their library remains below")
        let buffer = OpenBuffer(title: "Plan.crowmap", path: map.path, text: "{}", language: .markdown, isRemote: false)
        owner.snapshot.buffers.append(buffer); owner.snapshot.layout?.open(.file(buffer.id))
        XCTAssertEqual(owner.agentHistoryPath, folder.path)
        XCTAssertEqual(owner.focusedCrowmapPath, map.path)
        let index = try XCTUnwrap(owner.snapshot.agentTerminals.firstIndex { $0.id == id })
        owner.snapshot.agentTerminals[index].crowmapPath = nil
        model.openAgentTerminal(id, workspaceID: ownerID)
        XCTAssertEqual(owner.agentHistoryPath, folder.path, "Pre-fix sessions are inferred from their map session directory")
        XCTAssertEqual(model.crowmap.selected, map)
        owner.snapshot.agentTerminals[index].firstPrompt = "Read selected notes"
        let now = Date().timeIntervalSince1970
        func entry(_ name: String, cwd: String) -> AgentHistoryEntry {
            .init(id: name, provider: .codex, path: "/history/" + name, title: "Read selected notes", modified: now,
                  size: 100, first: .init(role: "user", text: "Read selected notes"), recent: [], tokens: nil, started: now, cwd: cwd)
        }
        model.reconcileAgentHistory([entry("other", cwd: folder.appendingPathComponent(".sessions/other").path), entry("selected", cwd: session.path)], source: owner, path: folder.path, serverTime: now)
        XCTAssertEqual(owner.snapshot.agentTerminals[index].currentSessionID, "selected")
    }

    @MainActor func testAgentLaunchFromFocusedCrowmapUsesItsFolderAndOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-map-launch-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let state = model.current
        let first = root.appendingPathComponent(".crow/crowmap/First/First.crowmap")
        let second = root.appendingPathComponent(".crow/crowmap/Second/Second.crowmap")
        for map in [first, second] { try FileManager.default.createDirectory(at: map.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("{}".utf8).write(to: map) }
        model.newTab(); let pane = try XCTUnwrap(state.snapshot.layout?.activePaneID)
        let mapBuffers = [first, second].map { OpenBuffer(title: $0.lastPathComponent, path: $0.path, text: "{}", language: .markdown, isRemote: false) }
        state.snapshot.buffers.append(contentsOf: mapBuffers)
        for provider in AgentProvider.allCases {
            state.snapshot.layout?.open(.file(mapBuffers[0].id), in: pane)
            let id = try XCTUnwrap(model.newAgentTerminal(provider, in: pane))
            let agent = try XCTUnwrap(state.snapshot.agentTerminals.first { $0.id == id })
            XCTAssertEqual(agent.directory, first.deletingLastPathComponent().path)
            XCTAssertEqual(agent.crowmapPath, first.path)
            XCTAssertEqual(model.terminal(id, in: state).launchCommand, provider.command(directory: first.deletingLastPathComponent().path))
            XCTAssertEqual(state.agentHistoryPath, first.deletingLastPathComponent().path)
            XCTAssertTrue(model.crowmapAgents(in: first.deletingLastPathComponent()).contains { $0.id == id })
            XCTAssertEqual(state.contextRootPath, root.path, "Explorer context stays at the workspace root")
        }
        state.snapshot.layout?.open(.file(mapBuffers[1].id), in: pane)
        let secondID = try XCTUnwrap(model.newAgentTerminal(.codex))
        XCTAssertEqual(state.snapshot.agentTerminals.first { $0.id == secondID }?.crowmapPath, second.path)
        XCTAssertEqual(model.crowmap.selected, second)
        state.snapshot.layout?.open(.file(mapBuffers[0].id), in: pane)
        let explicit = root.appendingPathComponent("Explicit").path
        let explicitID = try XCTUnwrap(model.newAgentTerminal(.claude, directory: explicit))
        XCTAssertEqual(state.snapshot.agentTerminals.first { $0.id == explicitID }?.directory, explicit)
        XCTAssertNil(state.snapshot.agentTerminals.first { $0.id == explicitID }?.crowmapPath)
        let ordinary = OpenBuffer(title: "Note.md", path: root.appendingPathComponent("docs/Note.md").path, text: "", language: .markdown, isRemote: false)
        state.snapshot.buffers.append(ordinary); state.snapshot.layout?.open(.file(ordinary.id), in: pane)
        let ordinaryID = try XCTUnwrap(model.newAgentTerminal(.codex))
        XCTAssertEqual(state.snapshot.agentTerminals.first { $0.id == ordinaryID }?.directory, root.path)
        XCTAssertNil(state.snapshot.agentTerminals.first { $0.id == ordinaryID }?.crowmapPath)
    }

    @MainActor func testDockCrowmapAgentLaunchAndHistoryIgnoreSelectedRemoteWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-dock-agent-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.crowmap = CrowmapStore(root: root.appendingPathComponent("Maps")); model.createCrowmap()
        let map = try XCTUnwrap(model.crowmapTabs.first), local = model.current
        let host = HostID(rawValue: UUID())
        let remote = WorkspaceState(.init(workspace: .init(name: "Remote", kind: .remote(hostID: host, path: "/project"), connection: .disconnected), rootPath: "/project"))
        model.states.append(remote); model.selectWorkspace(remote.id)
        let layout = remote.snapshot.layout
        model.openCrowmap(map.url)
        XCTAssertTrue(model.current === remote, "Opening a local map never switches the upper workspace")
        XCTAssertEqual(remote.snapshot.layout, layout)
        let history = try model.agentHistorySource(for: remote)
        XCTAssertFalse(history.0.snapshot.workspace.isRemote)
        XCTAssertEqual(history.1, map.store.noteRoot.path)
        XCTAssertEqual(history.0.crowmapHistoryDirectory, map.store.noteRoot.path)
        XCTAssertFalse(model.states.contains { $0 === history.0 }, "History does not create a workspace")
        let id = try XCTUnwrap(model.newAgentTerminal(.codex))
        XCTAssertTrue(model.current === local)
        let agent = try XCTUnwrap(local.snapshot.agentTerminals.first { $0.id == id })
        XCTAssertEqual(agent.directory, map.store.noteRoot.path)
        XCTAssertEqual(agent.crowmapPath, map.id)
        XCTAssertEqual(model.crowmapPanel.selectedPath, map.id)
        XCTAssertTrue(model.crowmapPanel.visible)
        XCTAssertNil(model.focusedPanelCrowmap, "The new agent terminal owns keyboard focus")
        XCTAssertTrue(remote.snapshot.agentTerminals.isEmpty)
    }

    @MainActor func testHistoryDeletionWaitsForTerminalProcessToExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-history-exit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready"), finished = root.appendingPathComponent("finished")
        let session = TerminalSession(id: UUID(), workspace: .init(name: "Fixture", kind: .local, connection: .local), directory: root.path, remote: nil, fontSize: 14)
        session.shellEnvironment = ["PATH=/usr/bin:/bin", "HOME=" + root.path, "ZDOTDIR=" + root.path]
        let flush = "trap '' TERM HUP; sleep 0.2; touch " + TerminalCommand.quote(finished.path) + "; exit"
        session.launchCommand = "exec /bin/sh -c " + TerminalCommand.quote("trap " + TerminalCommand.quote(flush) + " TERM HUP; touch " + TerminalCommand.quote(ready.path) + "; while :; do sleep 0.05; done")
        session.start()
        defer { session.stop() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        session.stop()
        try await session.waitUntilStopped()
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path), "Wait for the agent's final history flush, not just its tab closing")
    }

    @MainActor func testNewAgentHistoryBindingRejectsOldAndAmbiguousConversations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-history-binding-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.newAgentTerminal(.codex))
        let state = model.current, index = try XCTUnwrap(state.snapshot.agentTerminals.firstIndex { $0.id == id })
        state.snapshot.agentTerminals[index].firstPrompt = "Fix the editor"
        let serverNow = Date().timeIntervalSince1970 + 3600
        func entry(_ id: String, started: Double) -> AgentHistoryEntry {
            .init(id: id, provider: .codex, path: "/history/" + id, title: "Fix the editor", modified: serverNow,
                  size: 100, first: .init(role: "user", text: "Fix the editor"), recent: [], tokens: nil, started: started)
        }
        let old = entry("old", started: serverNow - 600), fresh = entry("fresh", started: serverNow)
        model.reconcileAgentHistory([old], source: state, path: state.snapshot.agentTerminals[index].directory, serverTime: serverNow)
        XCTAssertNil(state.snapshot.agentTerminals[index].currentSessionID)
        model.reconcileAgentHistory([fresh, entry("ambiguous", started: serverNow)], source: state,
                                    path: state.snapshot.agentTerminals[index].directory, serverTime: serverNow)
        XCTAssertNil(state.snapshot.agentTerminals[index].currentSessionID)
        model.reconcileAgentHistory([old, fresh], source: state, path: state.snapshot.agentTerminals[index].directory, serverTime: serverNow)
        XCTAssertEqual(state.snapshot.agentTerminals[index].currentSessionID, "fresh")
        XCTAssertEqual(model.closeAgentHistoryTabs(fresh, source: state), 1)
        XCTAssertFalse(state.snapshot.terminalIDs.contains(id))
    }

    @MainActor func testDeletingHistoryClosesMatchingTabsAcrossWorkspacesButNotOtherHostsOrForks() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-history-close-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let firstHost = HostID(rawValue: UUID()), otherHost = HostID(rawValue: UUID())
        let source = WorkspaceState(.init(workspace: .init(name: "Source", kind: .remote(hostID: firstHost, path: "/project"), connection: .disconnected), rootPath: "/project"))
        let other = WorkspaceState(.init(workspace: .init(name: "Other", kind: .remote(hostID: otherHost, path: "/project"), connection: .disconnected), rootPath: "/project"))
        model.states.append(contentsOf: [source, other])
        func add(_ state: WorkspaceState, provider: AgentProvider = .codex, reverse: HostID? = nil, fork: Bool = false) -> UUID {
            var agent = AgentTerminal(provider: provider, directory: "/project")
            agent.sessionID = "session"; agent.reverseHostID = reverse; agent.forkSession = fork
            state.snapshot.agentTerminals.append(agent); state.snapshot.terminalIDs.append(agent.id)
            return agent.id
        }
        let remote = add(source), reverse = add(model.current, reverse: firstHost)
        let unrelated = add(other), fork = add(source, fork: true), claude = add(source, provider: .claude)
        let entry = AgentHistoryEntry(id: "session", provider: .codex, path: "/history", title: "Conversation", modified: 0,
                                      size: 1, first: .init(role: "user", text: "Prompt"), recent: [], tokens: nil)
        XCTAssertEqual(model.closeAgentHistoryTabs(entry, source: source), 2)
        XCTAssertFalse(source.snapshot.terminalIDs.contains(remote))
        XCTAssertFalse(model.current.snapshot.terminalIDs.contains(reverse))
        XCTAssertTrue(other.snapshot.terminalIDs.contains(unrelated))
        XCTAssertTrue(source.snapshot.terminalIDs.contains(fork))
        XCTAssertTrue(source.snapshot.terminalIDs.contains(claude))
        XCTAssertNil(model.terminalCloseRequest, "The history deletion confirmation already covers closing the tabs")
    }

    @MainActor func testReverseAgentKeepsLocalContextAndRoutesHistoryToServer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-context-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let state = model.current, host = HostID(rawValue: UUID())
        var agent = AgentTerminal(provider: .codex, directory: "/client/workspace")
        agent.reverseHostID = host; agent.reverseServerDirectory = "/server/crow/session"
        state.snapshot.agentTerminals.append(agent)
        state.snapshot.terminalIDs.append(agent.id); state.snapshot.selectedTerminalID = agent.id
        state.snapshot.layout?.open(.terminal(agent.id))
        let terminal = model.terminal(agent.id, in: state)
        terminal.view.feed(text: "\u{1b}]7;file://server/server/crow/session\u{7}")
        XCTAssertEqual(state.agentHistoryPath, "/client/workspace")
        XCTAssertEqual(state.contextRootPath, "/client/workspace")
        XCTAssertEqual(state.contextDirectoryPath, "/client/workspace")
        XCTAssertFalse(state.snapshot.workspace.isRemote)
        XCTAssertNotNil(terminal.startupUnavailableMessage, "Restored tabs must never run the server agent locally")
        XCTAssertNil(terminal.launchCommand)
        XCTAssertThrowsError(try model.agentHistorySource(for: state), "A disconnected server must not fall back to local history")
        XCTAssertEqual(model.aiUsageSource.hostID, host)
        XCTAssertNil(model.aiUsageSource.state, "A missing reverse server must never show the client's account usage")
        let remote = WorkspaceState(.init(workspace: Workspace(name: "Server", kind: .remote(hostID: host, path: "/server"), connection: .disconnected), rootPath: "/server"))
        model.states.append(remote)
        XCTAssertTrue(model.aiUsageSource.state === remote)
        let roundTrip = try JSONDecoder().decode(AgentTerminal.self, from: JSONEncoder().encode(agent))
        XCTAssertEqual(roundTrip.reverseHostID, host)
        XCTAssertEqual(roundTrip.reverseServerDirectory, "/server/crow/session")
        state.snapshot.selectedTerminalID = nil
        XCTAssertEqual(state.contextRootPath, state.snapshot.rootPath)
        XCTAssertNil(model.aiUsageSource.hostID)
        XCTAssertTrue(model.aiUsageSource.state === state)
    }

    @MainActor func testDisconnectedReverseAgentKeepsTheConversationAnchor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-anchor-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let state = model.current
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        var local = AgentTerminal(provider: .codex, directory: root.path)
        local.firstPrompt = "local prompt"
        local.createdAt = created
        state.snapshot.agentTerminals.append(local)
        let localSession = model.terminal(local.id, in: state)
        XCTAssertNil(localSession.startupUnavailableMessage)
        let rebound = try XCTUnwrap(state.snapshot.agentTerminals.first { $0.id == local.id })
        XCTAssertNil(rebound.firstPrompt)
        XCTAssertNotEqual(rebound.createdAt, created)
        var agent = AgentTerminal(provider: .claude, directory: "/client/workspace")
        agent.reverseHostID = HostID(rawValue: UUID())
        agent.reverseServerDirectory = "/server/crow/session"
        agent.firstPrompt = "Keep this conversation"
        agent.conversationTitle = "Cover"
        agent.createdAt = created
        state.snapshot.agentTerminals.append(agent)
        let session = model.terminal(agent.id, in: state)
        XCTAssertEqual(session.startupUnavailableMessage, "Reverse agent disconnected.")
        let restored = try XCTUnwrap(state.snapshot.agentTerminals.first { $0.id == agent.id })
        XCTAssertEqual(restored.firstPrompt, "Keep this conversation")
        XCTAssertEqual(restored.conversationTitle, "Cover")
        XCTAssertEqual(restored.createdAt, created)
    }

    @MainActor func testReverseReconnectResumesTheTabsOwnConversation() throws {
        let directory = "/server/crow/session"
        let serverNow = Date().timeIntervalSince1970 + 3600
        let created = Date()
        func entry(_ id: String, prompt: String, title: String? = nil, started: Double, modified: Double? = nil) -> AgentHistoryEntry {
            .init(id: id, provider: .codex, path: "/history/" + id, title: title ?? prompt, modified: modified ?? started,
                  size: 20, first: .init(role: "user", text: prompt), recent: [], tokens: nil, started: started, cwd: directory)
        }
        let fresh = entry("fresh", prompt: "Fix the cover", started: serverNow, modified: serverNow + 10)
        let older = entry("older", prompt: "Older work", started: serverNow - 600, modified: serverNow + 50)
        let samePrompt = entry("same", prompt: "Fix the cover", started: serverNow + 5)
        let cover = entry("cover", prompt: "Layout", title: "Cover", started: serverNow - 30, modified: serverNow)
        XCTAssertEqual(ReverseSessionResume.sessionID(provider: .codex, directory: directory + "/", createdAt: created,
            firstPrompt: "Fix the cover", conversationTitle: nil, entries: [older, fresh, samePrompt], serverTime: serverNow,
            claimed: [], unboundSibling: false), "fresh", "Two matching prompts stay unresolved, so the newest session born with this tab wins")
        XCTAssertEqual(ReverseSessionResume.sessionID(provider: .codex, directory: directory, createdAt: created,
            firstPrompt: "Fix the cover", conversationTitle: "Cover", entries: [older, fresh, cover], serverTime: serverNow,
            claimed: ["fresh"], unboundSibling: true), "cover", "A stored title still identifies the tab when its prompt session is already claimed")
        XCTAssertNil(ReverseSessionResume.sessionID(provider: .codex, directory: directory, createdAt: created,
            firstPrompt: nil, conversationTitle: nil, entries: [older, fresh], serverTime: serverNow,
            claimed: [], unboundSibling: true))
        XCTAssertEqual(ReverseSessionResume.sessionID(provider: .codex, directory: directory, createdAt: Date(timeIntervalSince1970: serverNow + 5_000),
            firstPrompt: nil, conversationTitle: nil, entries: [older, fresh], serverTime: serverNow,
            claimed: [], unboundSibling: false), "older", "A relaunch that lost the prompt still reopens the newest session in this folder")
        XCTAssertEqual(ReverseSessionResume.sessionID(provider: .codex, directory: directory, createdAt: created,
            firstPrompt: nil, conversationTitle: nil, entries: [entry("parent", prompt: "Parent", started: serverNow - 50), fresh],
            serverTime: serverNow, claimed: [], unboundSibling: false, excluding: "parent"), "fresh")
        XCTAssertNil(ReverseSessionResume.sessionID(provider: .codex, directory: directory, createdAt: created,
            firstPrompt: nil, conversationTitle: nil, entries: [entry("parent", prompt: "Parent", started: serverNow)],
            serverTime: serverNow, claimed: [], unboundSibling: false, excluding: "parent"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-resume-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let host = HostID(rawValue: UUID())
        var agent = AgentTerminal(provider: .codex, directory: "/client/workspace")
        agent.reverseHostID = host
        agent.reverseServerDirectory = directory
        agent.name = "Cover pass"
        agent.isPinned = true
        agent.conversationTitle = "Cover"
        agent.firstPrompt = "Fix the cover"
        agent.createdAt = created
        var sibling = AgentTerminal(provider: .codex, directory: "/client/workspace")
        sibling.reverseHostID = host
        sibling.reverseServerDirectory = directory
        sibling.historySessionID = "fresh"
        let state = model.current
        state.snapshot.agentTerminals.append(contentsOf: [agent, sibling])
        state.snapshot.terminalIDs.append(contentsOf: [agent.id, sibling.id])
        let claim = model.reverseSessionClaim(around: agent)
        XCTAssertEqual(claim.claimed, Set(["fresh"]))
        XCTAssertFalse(claim.unboundSibling)
        let resumed = model.resolvedReverseResume(previous: agent, provider: .codex, fallbackSessionID: nil,
            entries: [older, fresh, cover], serverTime: serverNow)
        XCTAssertEqual(resumed.sessionID, "cover")
        XCTAssertFalse(resumed.fork)
        var known = agent
        known.historySessionID = "kept"
        XCTAssertEqual(model.resolvedReverseResume(previous: known, provider: .codex, fallbackSessionID: nil, entries: [fresh], serverTime: serverNow).sessionID, "kept")
        var fork = agent
        fork.sessionID = "parent"
        fork.forkSession = true
        let child = model.resolvedReverseResume(previous: fork, provider: .codex, fallbackSessionID: "parent",
            entries: [entry("parent", prompt: "Parent", started: serverNow - 50), entry("child", prompt: "Fix the cover", title: "Child", started: serverNow)],
            serverTime: serverNow)
        XCTAssertEqual(child.sessionID, "child")
        XCTAssertFalse(child.fork)
        sibling.historySessionID = nil
        sibling.sessionID = nil
        state.snapshot.agentTerminals[1] = sibling
        var blank = agent
        blank.firstPrompt = nil
        blank.conversationTitle = nil
        XCTAssertNil(model.resolvedReverseResume(previous: blank, provider: .codex, fallbackSessionID: nil,
            entries: [older, fresh], serverTime: serverNow).sessionID)
        let kept = ReverseSessionResume.reconnectedAgent(agent, provider: .codex, directory: "/client/workspace",
            hostID: host, serverDirectory: directory, sessionID: "older", fork: false)
        XCTAssertEqual(kept.id, agent.id)
        XCTAssertEqual(kept.name, "Cover pass")
        XCTAssertTrue(kept.isPinned)
        XCTAssertEqual(kept.conversationTitle, "Cover")
        XCTAssertEqual(kept.firstPrompt, "Fix the cover")
        XCTAssertEqual(kept.createdAt, created)
        XCTAssertEqual(kept.historySessionID, "older")
        XCTAssertEqual(kept.currentSessionID, "older")
        let restarted = ReverseSessionResume.reconnectedAgent(agent, provider: .codex, directory: "/client/workspace",
            hostID: host, serverDirectory: directory, sessionID: nil, fork: false)
        XCTAssertEqual(restarted.id, agent.id)
        XCTAssertEqual(restarted.name, "Cover pass")
        XCTAssertTrue(restarted.isPinned)
        XCTAssertNil(restarted.conversationTitle)
        XCTAssertNil(restarted.firstPrompt)
        XCTAssertNil(restarted.historySessionID)
    }

    @MainActor func testReverseClientToolsOverRealSSH() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-tools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await ReverseSSHServer.create()
        defer { server.stop() }
        let knownHosts = root.appendingPathComponent("known_hosts")
        try "[127.0.0.1]:\(server.port) \(try server.hostPublicKey)".write(to: knownHosts, atomically: true, encoding: .utf8)
        let script = try XCTUnwrap(Bundle.main.url(forResource: "agent-history", withExtension: "py"))
        let python = try await ReverseSSHCommand.run("/bin/sh", ["-c", TerminalCommand.environment + "command -v python3"])
        let request = String(decoding: try JSONSerialization.data(withJSONObject: ["action": "reverse-tools", "workspace": root.path]), as: UTF8.self)
        let command = "exec " + TerminalCommand.quote(python.trimmingCharacters(in: .whitespacesAndNewlines)) + " " + TerminalCommand.quote(script.path) + " " + TerminalCommand.quote(request)
        let calls: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "write_file", "arguments": ["path": "client.txt", "text": "client-side"]]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "shell", "arguments": ["command": "pwd"]]]
        ]
        let input = try calls.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        let output = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-T", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + knownHosts.path,
            "-i", server.directory.appendingPathComponent("identity").path, "-p", String(server.port), server.username + "@127.0.0.1", command], input: Data(input.utf8))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("client.txt"), encoding: .utf8), "client-side")
        let replies = try output.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(replies.count, 3)
        let result = try XCTUnwrap(replies.last?["result"] as? [String: Any])
        XCTAssertNil(result["isError"])
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

    @MainActor func testBundledSkillsReaderUsesRequestedDirectoryAndDecodesProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-skills-" + UUID().uuidString)
        let project = root.appendingPathComponent("project")
        let skill = project.appendingPathComponent(".claude/skills/crow-fixture/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "---\nname: crow-fixture\ndescription: Fixture for the focused directory\n---\nBody".write(to: skill, atomically: true, encoding: .utf8)
        let model = AppModel(vaultURL: root.appendingPathComponent("vault"))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let data = try await AgentHistoryService.run(["action": "skills", "workspace": project.path], in: model.current, operation: "Agent skills")
        let result = try JSONDecoder().decode(AgentSkillsResult.self, from: data)
        let entry = try XCTUnwrap(result.skills.first { $0.name == "crow-fixture" })
        XCTAssertEqual(entry.provider, .claude)
        XCTAssertEqual(entry.scope, "Project")
        XCTAssertEqual(URL(fileURLWithPath: entry.path).resolvingSymlinksInPath(), skill.resolvingSymlinksInPath())
        XCTAssertEqual(entry.description, "Fixture for the focused directory")
    }

    @MainActor func testResourceSampling() {
        let status = DeviceStatusState()
        status.sampleResources()
        XCTAssertGreaterThan(status.memory, 0)
        XCTAssertGreaterThanOrEqual(status.cpu, 0)
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

    @MainActor func testAgentSessionTitlesFollowCLIAndPreserveCustomNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-agent-titles-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        for provider in AgentProvider.allCases {
            let id = try XCTUnwrap(model.newAgentTerminal(provider))
            let state = model.current
            let session = model.terminal(id, in: state)
            let index = try XCTUnwrap(state.snapshot.agentTerminals.firstIndex { $0.id == id })
            XCTAssertEqual(state.snapshot.agentTerminals[index].title, "New conversation")
            session.view.feed(text: "\u{1b}]2;\(provider.title)\u{7}")
            XCTAssertEqual(state.snapshot.agentTerminals[index].title, "New conversation")
            session.running = true
            let marker = provider == .claude ? "❯" : "›"
            session.view.feed(text: "\u{1b}[2J\u{1b}[H\(marker) /help")
            session.send(source: session.view, data: [13][...])
            XCTAssertEqual(state.snapshot.agentTerminals[index].title, "New conversation", "Commands are not conversation titles")
            session.view.feed(text: "\u{1b}[2J\u{1b}[H\(marker) 클립보드 동기화 수정")
            session.send(source: session.view, data: [13][...])
            XCTAssertEqual(state.snapshot.agentTerminals[index].title, "클립보드 동기화 수정")
            session.view.feed(text: "\u{1b}]2;\(provider.title): SSH 클립보드 수정\u{7}")
            XCTAssertEqual(state.snapshot.agentTerminals[index].title, "SSH 클립보드 수정")
            session.view.feed(text: "\u{1b}]2;\(provider.title)\u{7}")
            XCTAssertEqual(state.snapshot.agentTerminals[index].title, "SSH 클립보드 수정", "A generic CLI title must not erase the conversation name")
            model.renameAgentTerminal(id, workspaceID: state.id, name: "내 작업")
            session.view.feed(text: "\u{1b}]2;Updated title\u{7}")
            XCTAssertEqual(state.snapshot.agentTerminals[index].title, "내 작업")
            let restored = try JSONDecoder().decode(AgentTerminal.self, from: JSONEncoder().encode(state.snapshot.agentTerminals[index]))
            XCTAssertEqual(restored.conversationTitle, "Updated title")
            XCTAssertEqual(restored.title, "내 작업")
        }
    }

    @MainActor func testAgentHistoryFollowsTerminalDirectoryAndTabFocus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-history-cwd-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let state = model.current
        XCTAssertEqual(state.agentHistoryPath, root.path)
        model.newTerminal()
        let firstID = try XCTUnwrap(state.snapshot.selectedTerminalID)
        let first = model.terminal(firstID, in: state)
        let pane = try XCTUnwrap(state.snapshot.layout?.activePaneID)
        first.view.feed(text: "\u{1b}]7;file://localhost/tmp/project-one\u{7}")
        XCTAssertEqual(state.agentHistoryPath, "/tmp/project-one")
        first.view.feed(text: "\u{1b}]7;file://localhost/tmp/project-one/subfolder\u{7}")
        XCTAssertEqual(state.agentHistoryPath, "/tmp/project-one/subfolder", "cd must change the history scope without changing tabs")
        model.newTerminal()
        let secondID = try XCTUnwrap(state.snapshot.selectedTerminalID)
        let second = model.terminal(secondID, in: state)
        second.view.feed(text: "\u{1b}]7;file://localhost/tmp/project-two\u{7}")
        XCTAssertEqual(state.agentHistoryPath, "/tmp/project-two")
        model.selectTab(.terminal(firstID), in: pane)
        XCTAssertEqual(state.agentHistoryPath, "/tmp/project-one/subfolder")
        second.view.feed(text: "\u{1b}]7;file://localhost/tmp/background-tab\u{7}")
        XCTAssertEqual(state.agentHistoryPath, "/tmp/project-one/subfolder", "Output from an unfocused terminal must not change the list")
        let path = state.agentHistoryPath
        let agentID = try XCTUnwrap(model.newAgentTerminal(.codex, directory: path))
        let agent = try XCTUnwrap(state.snapshot.agentTerminals.first { $0.id == agentID })
        XCTAssertEqual(agent.directory, path, "History resumes must run in the folder used to load the list")
        let resumed = model.terminal(agentID, in: state)
        XCTAssertEqual(resumed.workingDirectory, path, "An agent has the right initial path even before it emits OSC 7")
        XCTAssertEqual(state.agentHistoryPath, path)
        XCTAssertEqual(state.snapshot.rootPath, root.path)
    }

    @MainActor func testRealShellCdUpdatesObservedHistoryScopeWithoutTabChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-live-cwd-" + UUID().uuidString)
        let folder = root.appendingPathComponent("한글 # percent% folder")
        let rc = root.appendingPathComponent("rc")
        for directory in [root, folder, rc] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        // A login startup file can replace prompt hooks after .zshrc has run.
        try Data("precmd_functions=()\n".utf8).write(to: rc.appendingPathComponent(".zlogin"))
        let bridge = try SystemSSHBridge(startupDirectory: rc.path)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); bridge.stop(); try? FileManager.default.removeItem(at: root) }
        model.newTerminal()
        let state = model.current, id = try XCTUnwrap(state.snapshot.selectedTerminalID)
        let session = model.terminal(id, in: state)
        session.shellEnvironment = bridge.environment
        session.start()
        for _ in 0..<100 where session.currentDirectory == nil { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertNotNil(session.currentDirectory)
        let changed = expectation(description: "History path observation invalidates on cd")
        withObservationTracking { _ = state.agentHistoryPath } onChange: { changed.fulfill() }
        session.view.send(txt: "cd -- " + TerminalCommand.quote(folder.path) + "\r")
        await fulfillment(of: [changed], timeout: 3)
        for _ in 0..<100 where state.agentHistoryPath != folder.path { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(state.agentHistoryPath, folder.path)
        XCTAssertEqual(state.snapshot.selectedTerminalID, id)
        XCTAssertEqual(state.snapshot.rootPath, root.path)
    }

    @MainActor func testSSHInteractiveStartupReportsRealCdForBashAndZsh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-ssh-cwd-" + UUID().uuidString)
        let folder = root.appendingPathComponent("한글 ' # % folder"), rc = root.appendingPathComponent("rc")
        for directory in [root, folder, rc] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("precmd_functions=()\n".utf8).write(to: rc.appendingPathComponent(".zlogin"))
        for shell in ["/bin/zsh", "/bin/bash"] {
            let session = TerminalSession(id: UUID(), workspace: Workspace(name: "Fixture", kind: .local, connection: .local), directory: root.path, remote: nil, fontSize: 14)
            session.shellEnvironment = ["PATH=/usr/bin:/bin", "HOME=" + rc.path, "ZDOTDIR=" + rc.path, "SHELL=" + shell]
            session.launchCommand = "exec /bin/sh -c " + TerminalCommand.quote(SSHCommand.interactiveShellCommand(directory: root.path))
            session.start()
            defer { session.stop() }
            for _ in 0..<100 where session.currentDirectory == nil { try await Task.sleep(for: .milliseconds(30)) }
            XCTAssertEqual(session.currentDirectory, root.path, shell)
            session.view.send(txt: "cd -- " + TerminalCommand.quote(folder.path) + "\r")
            for _ in 0..<100 where session.currentDirectory != folder.path { try await Task.sleep(for: .milliseconds(30)) }
            XCTAssertEqual(session.currentDirectory, folder.path, shell)
            session.view.send(txt: "exit\r")
            for _ in 0..<100 where session.running { try await Task.sleep(for: .milliseconds(30)) }
            XCTAssertFalse(session.running, "Startup wrapper must exit with the shell")
        }
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
        XCTAssertEqual(state.agentHistoryPath, folder.path)
        // The outer shell's OSC directory must not override the focused tmux pane.
        session.view.feed(text: "\u{1b}]7;file://localhost/tmp/outer-shell\u{7}")
        XCTAssertEqual(state.agentHistoryPath, folder.path)
        XCTAssertEqual(state.explorer.rootPath, folder.path)
        XCTAssertEqual(state.snapshot.rootPath, original)
        XCTAssertEqual(session.tmuxLocation, focus.location)
        // Launching from a start page still creates a separate agent tab.
        let paneID = try XCTUnwrap(state.snapshot.layout?.activePaneID)
        state.snapshot.layout?.open(.start(UUID()), in: paneID)
        let agentID = try XCTUnwrap(model.newAgentTerminal(.codex, in: paneID))
        XCTAssertEqual(state.snapshot.agentTerminals.first { $0.id == agentID }?.directory, folder.path)
        model.applyTmuxFocus(.init(location: focus.location, directory: "/stale"), in: state, terminalID: id)
        XCTAssertEqual(state.contextRootPath, folder.path, "Ignore a result for a terminal that lost focus")
        model.clearTmuxContext(in: state)
        XCTAssertEqual(state.agentHistoryPath, folder.path, "The newly opened agent retains its own launch folder")
        model.newTerminal()
        XCTAssertEqual(state.agentHistoryPath, original, "A normal terminal must not inherit another terminal's tmux context")
        XCTAssertEqual(state.contextRootPath, original)
        XCTAssertEqual(state.explorer.rootPath, original)
    }

    @MainActor func testDocumentFocusOverridesTmuxAndReverseAgentContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-document-context-" + UUID().uuidString)
        let folder = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("note.md")
        try "document".write(to: file, atomically: true, encoding: .utf8)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let state = model.current
        model.newTerminal()
        let terminalID = try XCTUnwrap(state.snapshot.selectedTerminalID)
        let terminal = model.terminal(terminalID, in: state)
        terminal.running = true; terminal.tmuxLocation = .init(sessionID: "$0", windowID: "@0", paneID: "%0")
        state.tmuxContextDirectory = "/previous-agent"
        terminal.tmuxCurrentDirectory = "/previous-agent"
        model.openFile(.init(name: "note.md", path: file.path, isDirectory: false))
        let pane = try XCTUnwrap(state.snapshot.layout?.activePane)
        let tab = try XCTUnwrap(pane.selected)
        model.selectTab(tab, in: pane.id)
        XCTAssertNil(state.focusedTerminalID)
        XCTAssertNil(state.selectedAgent)
        XCTAssertEqual(state.agentHistoryPath, folder.path)
        XCTAssertEqual(state.contextRootPath, root.path)
        model.refreshFiles()
        XCTAssertEqual(state.explorer.rootPath, root.path)
        model.applyTmuxFocus(.init(location: terminal.tmuxLocation!, directory: "/stale-result"), in: state, terminalID: terminalID)
        XCTAssertEqual(state.contextRootPath, root.path)
        let source = try model.agentHistorySource(for: state)
        XCTAssertTrue(source.0 === state); XCTAssertEqual(source.1, folder.path)
        model.selectTab(.terminal(terminalID), in: pane.id)
        XCTAssertEqual(state.agentHistoryPath, "/previous-agent")
        XCTAssertEqual(state.snapshot.rootPath, root.path)
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

    @MainActor func testAgentLaunchKeepsTheSelectedTmuxTerminal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-tmux-agent-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.newTerminal()
        let state = model.current
        let id = try XCTUnwrap(state.snapshot.selectedTerminalID)
        let terminal = model.terminal(id, in: state)
        terminal.running = true; terminal.tmuxLocation = .init(sessionID: "$3", windowID: "@2", paneID: "%9")
        let tabs = state.snapshot.terminalIDs
        XCTAssertEqual(model.newAgentTerminal(.claude), id)
        XCTAssertEqual(state.snapshot.terminalIDs, tabs)
        XCTAssertTrue(state.snapshot.agentTerminals.isEmpty, "The tmux client must not become a standalone agent on restoration")
        let pane = try XCTUnwrap(state.snapshot.layout?.activePaneID)
        model.requestReverseAgent(in: pane)
        XCTAssertEqual(model.reverseAgentRequest?.tmuxTerminalID, id)
        // Cancel the queued launch before yielding; this test must never contact a user tmux server.
        terminal.running = false
        XCTAssertNil(model.tmuxLaunchTerminal(in: state, paneID: pane))
    }

    @MainActor func testTmuxAgentCommandUsesOnlyItsPaneAndReturnsToShell() async throws {
        let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tmux else { throw XCTSkip("tmux is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-tmux-run-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = "crow-test-" + UUID().uuidString
        let wrapper = root.appendingPathComponent("tmux")
        try ("#!/bin/sh\nexec " + TerminalCommand.quote(tmux) + " -L " + TerminalCommand.quote(socket) + " -f /dev/null \"$@\"\n").write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        defer {
            let process = Process(); process.executableURL = URL(fileURLWithPath: tmux)
            process.arguments = ["-L", socket, "kill-server"]; try? process.run(); process.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        func run(_ command: String) async throws -> String {
            try await ReverseSSHCommand.run("/bin/sh", ["-c", "export PATH=" + TerminalCommand.quote(root.path) + ":$PATH; " + command])
        }
        let output = try await run("tmux new-session -d -s fixture -P -F 'CROW_CREATED|#{session_id}|#{window_id}|#{pane_id}' /bin/sh")
        let location = try TmuxCommand.parseCreated(output, sessionID: "$0")
        _ = try await run("tmux split-window -d -t '%0' /bin/sh")
        let result = root.appendingPathComponent("한글 ' result")
        let command = "printf '%s' 'literal $HOME; #{pane_id}' > " + TerminalCommand.quote(result.path)
        _ = try await run(TmuxCommand.run(command, in: location))
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: result.path) { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "literal $HOME; #{pane_id}")
        let panes = try await run("tmux list-panes -F '#{pane_id}|#{pane_current_command}'")
        XCTAssertEqual(Set(panes.split(separator: "\n").map { String($0.split(separator: "|")[0]) }), Set(["%0", "%1"]))
        XCTAssertTrue(panes.split(separator: "\n").allSatisfy { $0.hasSuffix("|sh") || $0.hasSuffix("|bash") }, panes)
        _ = try await run("tmux send-keys -t '%0' 'sleep 30' Enter")
        try await Task.sleep(for: .milliseconds(150))
        do { _ = try await run(TmuxCommand.run("printf should-not-run", in: location)); XCTFail("A busy pane must reject agent input") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Return to the shell prompt"), error.localizedDescription) }
    }

    @MainActor func testTmuxReverseRunSurvivesClientCloseAndCleansUpOnExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-tmux-lifetime-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.newTerminal()
        let state = model.current, id = try XCTUnwrap(state.snapshot.selectedTerminalID)
        let runID = UUID(), completed = root.appendingPathComponent("completed")
        var cleanups = 0
        let run = TmuxAgentRun(hostID: HostID(), completed: completed) { [weak state] in
            cleanups += 1; state?.tmuxAgentRuns.removeValue(forKey: runID)
        }
        state.tmuxAgentRuns[runID] = run
        model.closeTerminal(id)
        XCTAssertEqual(cleanups, 0)
        XCTAssertNotNil(state.tmuxAgentRuns[runID])
        try Data().write(to: completed)
        for _ in 0..<50 where cleanups == 0 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(cleanups, 1)
        XCTAssertNil(state.tmuxAgentRuns[runID])
        run.stop()
        XCTAssertEqual(cleanups, 1, "Cleanup must only run once")
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

    @MainActor func testReverseSSHRejectsUnsupportedHostsBeforeRunningConnector() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-platform-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let uname = root.appendingPathComponent("uname"), ssh = root.appendingPathComponent("ssh")
        try "#!/bin/sh\nprintf CROW_TEST_SSH_STARTED\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let environment = ["PATH": root.path + ":/usr/bin:/bin"]
        let script = ReverseSSHConnector.script(path: root.path, port: 2222, username: "fixture")
        for system in ["Linux", "MINGW64_NT", "FreeBSD", "Darwin"] {
            try ("#!/bin/sh\nprintf '%s\\n' '" + system + "'\n").write(to: uname, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: uname.path)
            let output = try await ReverseSSHCommand.run("/bin/sh", ["-c", ReverseSSHConnector.supportedHostCommand], environment: environment)
            XCTAssertEqual(ReverseSSHConnector.supportsHost(output), system == "Darwin")
            if system == "Darwin" {
                let connected = try await ReverseSSHCommand.run("/bin/sh", ["-c", script], environment: environment)
                XCTAssertEqual(connected, "CROW_TEST_SSH_STARTED")
            } else {
                do {
                    _ = try await ReverseSSHCommand.run("/bin/sh", ["-c", script], environment: environment)
                    XCTFail("Unsupported hosts must not execute ssh")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("only between macOS devices"))
                    XCTAssertFalse(error.localizedDescription.contains("CROW_TEST_SSH_STARTED"))
                }
            }
        }
        XCTAssertTrue(ReverseSSHConnector.supportsHost("Welcome\r\nCROW_REVERSE_MACOS\r\n"))
        for output in ["", "Darwin", "CROW_REVERSE_MACOS\nCROW_REVERSE_UNSUPPORTED", "CROW_REVERSE_MACOS\nCROW_REVERSE_MACOS"] {
            XCTAssertFalse(ReverseSSHConnector.supportsHost(output))
        }
    }

    @MainActor func testRetiredReverseAgentDoesNotRelaunchUnderLoginAccount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-retired-agent-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.newAgentTerminal(.codex))
        let index = try XCTUnwrap(model.current.snapshot.agentTerminals.firstIndex { $0.id == id })
        model.current.snapshot.agentTerminals[index].isManagedReverse = true
        model.current.terminals.removeValue(forKey: id)?.stop()
        let terminal = model.terminal(id, in: model.current)
        terminal.start()
        XCTAssertFalse(terminal.running)
        XCTAssertTrue(terminal.status.contains("Open a new agent tab"))
    }

    @MainActor func testReverseToggleStartsWithoutExtraCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-toggle-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let host = SSHHost(name: "Fixture", hostname: "192.0.2.1", username: "fixture")
        model.hosts = [host]
        // No saved command or credentials: startup may fail asynchronously, but must
        // enter the existing SSH connection path without opening password settings.
        model.setReverseSSH(true, for: host)
        let session = try XCTUnwrap(model.reverseSSHConnections[host.id])
        XCTAssertTrue(session.isEnabled)
        XCTAssertFalse(model.settingsVisible)
        model.setReverseSSH(false, for: host)
        XCTAssertFalse(session.isEnabled)
        XCTAssertNil(session.connectCommand)
        await session.stopAndWait()
    }

    @MainActor func testLastReverseAgentTabStopsOnlyItsHostAcrossWorkspaces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-lifetime-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let host = SSHHost(name: "First", hostname: "192.0.2.1", username: "first")
        let other = SSHHost(name: "Second", hostname: "192.0.2.1", username: "second")
        let manual = SSHHost(name: "Manual", hostname: "192.0.2.2", username: "fixture")
        for host in [host, other, manual] { model.setReverseSSH(true, for: host) }
        let first = model.current
        let second = WorkspaceState(.init(workspace: Workspace(name: "Second", kind: .local, connection: .local), rootPath: root.path))
        model.states.append(second)
        func add(_ host: SSHHost, to state: WorkspaceState) -> UUID {
            var agent = AgentTerminal(provider: .codex, directory: root.path)
            agent.reverseHostID = host.id
            state.snapshot.agentTerminals.append(agent); state.snapshot.terminalIDs.append(agent.id)
            return agent.id
        }
        let a = add(host, to: first), b = add(host, to: second)
        _ = add(other, to: second)
        model.closeTerminal(a)
        XCTAssertEqual(model.reverseSSHConnections[host.id]?.isEnabled, true, "Another workspace still uses this server")
        model.closeTerminal(b)
        XCTAssertEqual(model.reverseSSHConnections[host.id]?.isEnabled, false)
        XCTAssertEqual(model.reverseSSHConnections[other.id]?.isEnabled, true, "Same IP with a different account is independent")
        XCTAssertTrue(model.removeWorkspace(second.id))
        XCTAssertEqual(model.reverseSSHConnections[other.id]?.isEnabled, false, "Removing a workspace also closes its last agent")
        XCTAssertEqual(model.reverseSSHConnections[manual.id]?.isEnabled, true, "Manual tunnels without agent tabs stay enabled")
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

    @MainActor func testWorkspaceDragOrderPersistsAndStaysWithinHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reorder-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let first = model.current; first.snapshot.workspace.name = "Alpha"
        let second = WorkspaceState(.init(workspace: Workspace(name: "Beta", kind: .local, connection: .local), rootPath: root.appendingPathComponent("Beta").path))
        let third = WorkspaceState(.init(workspace: Workspace(name: "Gamma", kind: .local, connection: .local), rootPath: root.appendingPathComponent("Gamma").path))
        model.states += [second, third]
        XCTAssertEqual(model.orderedWorkspaces(on: nil).map(\.id), [first.id, second.id, third.id])
        XCTAssertTrue(model.moveWorkspace(third.id, relativeTo: first.id, after: false))
        XCTAssertEqual(model.orderedWorkspaces(on: nil).map(\.id), [third.id, first.id, second.id])
        model.workspaceSearch = "Beta"
        XCTAssertTrue(model.moveWorkspace(third.id, relativeTo: second.id, after: true))
        XCTAssertEqual(model.orderedWorkspaces(on: nil).map(\.id), [first.id, second.id, third.id])
        model.pinWorkspace(first.id)
        XCTAssertTrue(model.moveWorkspace(third.id, relativeTo: first.id, after: false))
        XCTAssertTrue(third.snapshot.isPinned)
        let hostID = HostID()
        let remote = WorkspaceState(.init(workspace: Workspace(name: "Remote", kind: .remote(hostID: hostID, path: "/tmp"), connection: .disconnected), rootPath: "/tmp"))
        model.states.append(remote)
        XCTAssertFalse(model.moveWorkspace(third.id, relativeTo: remote.id, after: true))
        XCTAssertFalse(model.moveWorkspace(first.id, relativeTo: first.id, after: false))
        model.persist()
        let restored = AppModel(vaultURL: root); defer { restored.shutdown() }
        XCTAssertEqual(restored.orderedWorkspaces(on: nil).map(\.id), [third.id, first.id, second.id])
        XCTAssertTrue(try XCTUnwrap(restored.states.first { $0.id == third.id }).snapshot.isPinned)
        XCTAssertEqual(restored.orderedWorkspaces(on: hostID).map(\.id), [remote.id])
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
