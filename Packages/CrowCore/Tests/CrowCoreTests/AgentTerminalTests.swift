import XCTest
@testable import CrowCore

final class AgentTerminalTests: XCTestCase {
    func testWorkspaceMetadataRoundTripAndLegacyDefault() throws {
        var snapshot = WorkspaceSnapshot(workspace: Workspace(name: "Project", kind: .local, connection: .local), rootPath: "/tmp/project")
        var agent = AgentTerminal(provider: .claude, directory: snapshot.rootPath)
        agent.name = "Fix login"; agent.isPinned = true
        snapshot.isPinned = true; snapshot.lastOpenedAt = Date(timeIntervalSince1970: 1000)
        snapshot.agentTerminals = [agent]; snapshot.terminalIDs.append(agent.id)
        snapshot.relocateRoot(to: "/tmp/renamed")
        XCTAssertEqual(snapshot.agentTerminals.first?.directory, "/tmp/renamed")
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertTrue(restored.isPinned)
        XCTAssertEqual(restored.lastOpenedAt, snapshot.lastOpenedAt)
        XCTAssertEqual(restored.agentTerminals.first?.id, agent.id)
        XCTAssertEqual(restored.agentTerminals.first?.title, "Fix login")
        XCTAssertEqual(restored.agentTerminals.first?.isPinned, true)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "agentTerminals")
        legacy.removeValue(forKey: "isPinned"); legacy.removeValue(forKey: "lastOpenedAt")
        let old = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(old.isPinned); XCTAssertNil(old.lastOpenedAt)
        XCTAssertTrue(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy)).agentTerminals.isEmpty)
    }
    func testInteractiveLaunchAndShellQuoting() {
        for provider in AgentProvider.allCases {
            let command = provider.command(directory: "~/a b/'$(touch bad)")
            XCTAssertTrue(command.contains("cd \"$HOME\"/"))
            XCTAssertTrue(command.contains(" && exec '\(provider.rawValue)'"))
            XCTAssertFalse(command.contains("app-server"))
            XCTAssertFalse(command.contains("stream-json"))
        }
        XCTAssertEqual(TerminalCommand.quote("a'b"), "'a'\\''b'")
    }
    func testTmuxParsesIDsAndRefusesAmbiguousTargets() throws {
        let sessions = try TmuxCommand.parse("CROW_TMUX_BEGIN\nCROW_TMUX|$0|2|1|work\nCROW_TMUX|$12|1|0|work long\nCROW_TMUX_END")
        XCTAssertEqual(sessions.map(\.id), ["$0", "$12"])
        XCTAssertEqual(sessions.map(\.clients), [1, 0])
        XCTAssertTrue(try TmuxCommand.attach(id: sessions[0].id).hasSuffix("attach-session -t '$0'"))
        XCTAssertTrue(try TmuxCommand.kill(id: sessions[1].id).hasSuffix("kill-session -t '$12'"))
        XCTAssertThrowsError(try TmuxCommand.kill(id: "work"))
        XCTAssertThrowsError(try TmuxCommand.attach(id: "$0; kill-server"))
        XCTAssertThrowsError(try TmuxCommand.parse("$0\twrong\t0\twork"))
        XCTAssertEqual(try TmuxCommand.parse("CROW_TMUX_BEGIN\nCROW_TMUX_END"), [])
    }
    func testTmuxIgnoresLoginMessagesAndPreservesUnicodeAndSeparators() throws {
        let output = "Welcome to the server\r\nCROW_TMUX_BEGIN\r\nCROW_TMUX|$7|2|1|한글 | project\r\nCROW_TMUX_END\r\nlogout\r\n"
        let sessions = try TmuxCommand.parse(output)
        XCTAssertEqual(sessions.first?.name, "한글 | project")
        XCTAssertEqual(sessions.first?.id, "$7")
        XCTAssertThrowsError(try TmuxCommand.parse("CROW_TMUX_BEGIN\nCROW_TMUX|$7|2|1|partial"))
        XCTAssertFalse(TmuxCommand.list.contains("\t"))
        XCTAssertTrue(TmuxCommand.list.contains("tmux -u list-sessions"))
    }
    func testTmuxRejectsCommandSeparatorsAndFormatExpansionInNames() throws {
        for name in ["", "  ", "foo;", "a:b", "a.b", "$(id)", "#{session_id}", "line\nbreak"] {
            XCTAssertThrowsError(try TmuxCommand.create(name: name, directory: "/tmp"))
            XCTAssertThrowsError(try TmuxCommand.rename(id: "$0", name: name))
        }
        let command = try TmuxCommand.create(name: "한글 work-1", directory: "/tmp/#{literal};")
        XCTAssertTrue(command.contains("cd '/tmp/#{literal};' && tmux -u new-session"))
        XCTAssertFalse(command.contains(" -c "))
    }
    func testTmuxHierarchyKeepsLinkedWindowsUnderTheirSession() throws {
        let sessions = try TmuxCommand.parse("""
        CROW_TMUX_BEGIN
        CROW_TMUX|$0|2|1|한글
        CROW_TMUX|$1|1|0|linked
        CROW_WINDOW|$0|@2|3|0|second | window
        CROW_WINDOW|$0|@1|0|1|first
        CROW_WINDOW|$1|@1|7|1|first
        CROW_PANE|$0|@1|%4|1|0|claude
        CROW_PANE|$0|@1|%3|0|1|zsh
        CROW_PANE|$1|@1|%3|0|1|zsh
        CROW_PANE|$1|@1|%4|1|0|claude
        CROW_PANE|$0|@2|%5|0|1|codex
        CROW_TMUX_END
        """)
        XCTAssertEqual(sessions[0].windowList.map(\.id), ["@1", "@2"])
        XCTAssertEqual(sessions[0].windowList[1].name, "second | window")
        XCTAssertEqual(sessions[0].windowList[0].panes.map(\.id), ["%3", "%4"])
        XCTAssertEqual(sessions[1].windowList[0].index, 7)
        XCTAssertEqual(sessions[1].windowList[0].panes.count, 2)
        XCTAssertTrue(sessions[0].windowList[0].panes[0].isActive)
        let location = TmuxLocation(sessionID: "$0", windowID: "@2", paneID: "%5")
        let focus = try TmuxCommand.select(location)
        XCTAssertTrue(focus.contains("has-session -t '$0' && tmux select-window -t '$0:@2' && tmux select-pane -t '%5'"))
        XCTAssertFalse(focus.contains("attach-session"))
        let command = try TmuxCommand.attach(location)
        XCTAssertTrue(command.contains("select-window -t '$0:@2' && tmux select-pane -t '%5' && exec tmux -u attach-session"))
        XCTAssertTrue(try TmuxCommand.killWindow(sessionID: "$0", windowID: "@2").hasSuffix("kill-window -t '$0:@2'"))
        XCTAssertTrue(try TmuxCommand.killPane(id: "%5").hasSuffix("kill-pane -t '%5'"))
        XCTAssertThrowsError(try TmuxCommand.killPane(id: "%5; kill-server"))
        XCTAssertThrowsError(try TmuxCommand.killWindow(sessionID: "$0", windowID: "name"))
        XCTAssertThrowsError(try TmuxCommand.attach(.init(sessionID: "$0", paneID: "%5")))
        XCTAssertThrowsError(try TmuxCommand.parse("CROW_TMUX_BEGIN\nCROW_PANE|$0|@1|%3|0|2|zsh\nCROW_TMUX_END"))
    }

    func testTerminalEnvironmentRepairsNonUTF8AndPreservesValidLocales() {
        for original in [[:], ["LANG": "C"], ["LANG": "ko_KR.UTF-8", "LC_ALL": "C"], ["LC_CTYPE": "POSIX"]] {
            let environment = TerminalCommand.utf8Environment(original)
            XCTAssertEqual(environment["LC_CTYPE"], "en_US.UTF-8")
            XCTAssertEqual(environment["TERM"], "xterm-256color")
            if original["LC_ALL"] != nil { XCTAssertEqual(environment["LC_ALL"], "en_US.UTF-8") }
        }
        let original = ["LANG": "ko_KR.UTF-8", "PATH": "/bin", "SSH_AUTH_SOCK": "/tmp/agent"]
        let environment = TerminalCommand.utf8Environment(original)
        for (key, value) in original { XCTAssertEqual(environment[key], value) }
    }

    func testActivityDistinguishesWorkingIdleAndQuestionsWithoutUsingSilenceAlone() {
        for provider in AgentProvider.allCases {
            func activity(_ lines: [String], recent: Bool = false) -> AgentActivity {
                AgentActivityDetector.detect(provider: provider, lines: lines, cursorRow: lines.count - 1, outputIsRecent: recent)
            }
            XCTAssertEqual(activity(["Working (42s • esc to interrupt)", "❯ "]), .working)
            XCTAssertEqual(activity(["Finished the change.", "❯ "]), .idle)
            XCTAssertEqual(activity(["Which project should I use?", "❯ "]), .needsInput)
            XCTAssertEqual(activity(["Do you want to proceed?", "❯ 1. Yes", "2. No"]), .needsInput)
            XCTAssertEqual(activity(["Choose a project", "❯ 1. App", "Enter to select · Tab to navigate"]), .needsInput)
            XCTAssertEqual(activity(["Running a long tool without terminal output"]), .unknown)
            XCTAssertEqual(activity(["Streaming text"], recent: true), .working)
            XCTAssertEqual(activity(["Here is an example question?", "The answer is 42.", "❯ "]), .idle)
            XCTAssertEqual(activity(["Do you want to proceed?", "This is a quote from a log."]), .unknown)
            XCTAssertEqual(activity(["Do you want to proceed?", "❯ 1. Yes", "2. No", "Completed.", "❯ "]), .idle)
            XCTAssertEqual(AgentActivityDetector.detect(provider: provider,
                lines: ["Working (42s • esc to interrupt)", "❯ "] + Array(repeating: "", count: 30),
                cursorRow: 1, outputIsRecent: false), .working)
        }
    }

    func testTmuxCreationTargetsAndReturnedLocations() throws {
        let location = TmuxLocation(sessionID: "$2", windowID: "@4", paneID: "%7")
        XCTAssertTrue(try TmuxCommand.newWindow(sessionID: "$2").contains("-t '$2:'"))
        let split = try TmuxCommand.splitPane(location, direction: .sideBySide)
        XCTAssertTrue(split.contains("split-window -d -h"))
        XCTAssertTrue(split.contains("-t '$2:@4.%7'"))
        XCTAssertTrue(split.contains("-c '#{pane_current_path}'"))
        XCTAssertTrue(try TmuxCommand.splitPane(location, direction: .stacked).contains("split-window -d -v"))
        XCTAssertEqual(try TmuxCommand.parseCreated("Welcome\r\nCROW_CREATED|$2|@5|%8\r\n", sessionID: "$2"),
            .init(sessionID: "$2", windowID: "@5", paneID: "%8"))
        XCTAssertThrowsError(try TmuxCommand.newWindow(sessionID: "name"))
        XCTAssertThrowsError(try TmuxCommand.splitPane(.init(sessionID: "$2"), direction: .stacked))
        XCTAssertThrowsError(try TmuxCommand.splitPane(.init(sessionID: "$2", windowID: "@4", paneID: "%7;bad"), direction: .stacked))
        for output in ["", "CROW_CREATED|$3|@5|%8", "CROW_CREATED|$2|name|%8", "CROW_CREATED|$2|@5|%8\nCROW_CREATED|$2|@6|%9"] {
            XCTAssertThrowsError(try TmuxCommand.parseCreated(output, sessionID: "$2"))
        }
    }

}
