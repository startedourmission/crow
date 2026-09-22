import XCTest
import CrowCore
import SwiftTerm
@testable import Crow
#if os(macOS)
import AppKit

final class TerminalIntegrationTests: XCTestCase {
    @MainActor func testStreamingOutputPreservesDragAnchorLocallyAndOverSSH() throws {
        for local in [true, false] {
            let workspace = Workspace(name: "Streaming", kind: local ? .local : .remote(hostID: HostID(rawValue: UUID()), path: "/tmp"),
                connection: local ? .local : .connected)
            let session = TerminalSession(id: UUID(), workspace: workspace, directory: "/tmp", remote: nil, fontSize: 16)
            defer { session.stop() }
            let view = session.view
            func output(_ value: String) {
                let bytes = Array(value.utf8)
                if let pty = view as? LocalProcessTerminalView { pty.dataReceived(slice: bytes[...]) }
                else { view.feedProcessOutput(bytes[...]) }
            }
            output("Stable answer to copy\r\n")
            view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
            let anchor = view.selection.start
            for index in 0..<40 {
                output("\u{1b}[3;1H\u{1b}[2KWorking \(index)")
                XCTAssertTrue(view.selectionActive, "Streaming must not blink the selection off")
                XCTAssertEqual(view.getSelection(), "Stable")
            }
            view.selection.dragExtend(bufferPosition: Position(col: 13, row: 0))
            XCTAssertEqual(view.selection.start, anchor)
            XCTAssertEqual(view.getSelection(), "Stable answer")
            XCTAssertTrue(view.allowMouseReporting)
        }
    }

    @MainActor func testStreamingPreservesShiftSelectionWithoutDisablingTmuxMouseReports() {
        let session = TerminalSession(id: UUID(), workspace: Workspace(name: "tmux", kind: .local, connection: .local),
            directory: "/tmp", remote: nil, fontSize: 16)
        defer { session.stop() }
        let view = session.view
        view.feedProcessOutput(Array("Answer\r\n\u{1b}[?1002h\u{1b}[?1006h".utf8)[...])
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        let mode = view.getTerminal().mouseMode
        view.feedProcessOutput(Array("\u{1b}[3;1Hstill working".utf8)[...])
        XCTAssertEqual(view.getSelection(), "Answer")
        XCTAssertTrue(view.allowMouseReporting)
        XCTAssertEqual(view.getTerminal().mouseMode, mode)
        view.allowMouseReporting = false
        view.feedProcessOutput(Array(".".utf8)[...])
        XCTAssertFalse(view.allowMouseReporting, "Respect an explicitly disabled mouse setting")
    }

    @MainActor func testSynchronizedRedrawKeepsSelectionAcrossSplitOutput() {
        let session = TerminalSession(id: UUID(), workspace: Workspace(name: "Codex", kind: .local, connection: .local),
            directory: "/tmp", remote: nil, fontSize: 16)
        defer { session.stop() }
        let view = session.view
        view.feedProcessOutput(Array("Stable answer\r\n".utf8)[...])
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        view.feedProcessOutput(Array("\u{1b}[?2026h\u{1b}[3;1H\u{1b}[2K".utf8)[...])
        XCTAssertTrue(view.getTerminal().synchronizedOutputActive)
        view.feedProcessOutput(Array("새 답변".utf8)[...])
        XCTAssertTrue(view.selectionActive)
        view.feedProcessOutput(Array("\u{1b}[?2026l".utf8)[...])
        XCTAssertFalse(view.getTerminal().synchronizedOutputActive)
        XCTAssertEqual(view.getSelection(), "Stable")
    }

    @MainActor func testHangulCompositionFollowsEchoWithoutCoveringSyllable() throws {
        for local in [true, false] {
            let session = TerminalSession(id: UUID(), workspace: Workspace(name: "IME",
                kind: local ? .local : .remote(hostID: HostID(), path: "/tmp"), connection: local ? .local : .connected),
                directory: "/tmp", remote: nil, fontSize: 16)
            defer { session.stop() }
            let view = session.view
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            try view.setUseMetal(false) // Bitmap checks exercise the supported CPU fallback.
            defer { window.close() }
            view.feedProcessOutput(Array("$ ".utf8)[...])
            let originalColor = view.caretColor
            let range = NSRange(location: NSNotFound, length: 0)
            view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: range)
            let composition = try XCTUnwrap((view as? any MarkedTextTerminal)?.composition)
            let initial = try XCTUnwrap(composition.rect)
            XCTAssertEqual(view.caretColor, .clear)
            // The prior syllable's echo arrives after the next composition starts.
            view.feedProcessOutput(Array("국".utf8)[...])
            let advanced = try XCTUnwrap(composition.rect)
            XCTAssertGreaterThan(advanced.minX, initial.minX)
            XCTAssertEqual(view.caretColor, .clear)
            if local, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/crow-ime-review.png"))
            }
            view.unmarkText()
            XCTAssertNil(composition.rect); XCTAssertEqual(view.caretColor, originalColor)
            XCTAssertFalse(view.hasMarkedText())
        }
    }

    @MainActor func testModifiedArrowsReachTerminalBeforeSwiftUIFocusNavigation() throws {
        for local in [true, false] {
            let session = TerminalSession(id: UUID(), workspace: Workspace(name: "Keys",
                kind: local ? .local : .remote(hostID: HostID(), path: "/tmp"), connection: local ? .local : .connected),
                directory: "/tmp", remote: nil, fontSize: 16)
            defer { session.stop() }
            var sent: [UInt8] = []; session.onBytes = { sent += $0 }
            for mode in ["", "\u{1b}[>1u"] {
                session.view.feed(text: mode)
                for (code, scalar, suffix) in [(UInt16(123), 0xf702, "D"), (124, 0xf703, "C"), (125, 0xf701, "B"), (126, 0xf700, "A")] {
                    let text = String(UnicodeScalar(scalar)!)
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                        modifierFlags: [.shift, .numericPad, .function], timestamp: 0, windowNumber: 0,
                        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
                    sent = []
                    XCTAssertTrue(session.handleTerminalKey(event))
                    XCTAssertEqual(String(decoding: sent, as: UTF8.self), "\u{1b}[1;2" + suffix)
                }
            }
        }
    }

    @MainActor func testTerminalMetalRenderingCPUComparison() async throws {
        let session = TerminalSession(id: UUID(), workspace: Workspace(name: "Rendering", kind: .local, connection: .local),
            directory: "/tmp", remote: nil, fontSize: 14)
        defer { session.stop() }
        let view = session.view
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
        defer { window.close() }
        let terminal = view.getTerminal()
        for row in 1..<terminal.rows {
            view.feed(text: "\u{1b}[\(row);1H\u{1b}[\(31 + row % 7)m" + String(repeating: "Rendering text ", count: 12))
        }
        func cpuTime() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        for metal in [false, true] {
            try view.setUseMetal(metal)
            XCTAssertEqual(view.isUsingMetalRenderer, metal)
            try await Task.sleep(for: .milliseconds(100))
            let started = cpuTime()
            for frame in 0..<90 {
                view.feed(text: "\u{1b}[2;1H\u{1b}[0mWorking \(frame)   ")
                try await Task.sleep(for: .milliseconds(17))
                window.displayIfNeeded()
            }
            print("CROW_RENDER_CPU metal=\(metal) seconds=\(cpuTime() - started)")
            if metal { XCTAssertGreaterThan(view.metalRendererStatus.presentedFrameCount, 0) }
        }
    }

    @MainActor func testControlShortcutsWithKoreanInputSource() throws {
        let session = TerminalSession(id: UUID(), workspace: Workspace(name: "Keys", kind: .local, connection: .local),
            directory: "/tmp", remote: nil, fontSize: 16)
        defer { session.stop() }
        var sent: [UInt8] = []
        session.onBytes = { sent += $0 }
        for (code, korean, expected) in [(UInt16(0), "ㅁ", UInt8(1)), (8, "ㅊ", 3), (2, "ㅇ", 4),
                                        (14, "ㄷ", 5), (3, "ㄹ", 6), (37, "ㅣ", 12), (40, "ㅏ", 11), (35, "ㅔ", 16), (6, "ㅋ", 26)] {
            for flags in [NSEvent.ModifierFlags.control, [.control, .shift]] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: 0, windowNumber: 0, context: nil, characters: korean, charactersIgnoringModifiers: korean,
                    isARepeat: false, keyCode: code))
                sent = []
                XCTAssertTrue(session.handleTerminalKey(event))
                XCTAssertEqual(sent, [expected])
            }
        }
    }

    @MainActor func testDefaultTmuxPrefixAndCommandsWithKoreanInputSource() async throws {
        let tmux = "/opt/homebrew/bin/tmux"
        guard FileManager.default.isExecutableFile(atPath: tmux) else { throw XCTSkip("tmux is not installed") }
        let socket = "crow-keys-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func run(_ arguments: [String]) throws -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: tmux)
            process.arguments = ["-L", socket] + arguments
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let session = TerminalSession(id: UUID(), workspace: Workspace(name: "tmux", kind: .local, connection: .local),
            directory: root.path, remote: nil, fontSize: 16)
        defer { session.stop(); _ = try? run(["kill-server"]); try? FileManager.default.removeItem(at: root) }
        session.shellEnvironment = ["PATH=/usr/bin:/bin:/opt/homebrew/bin", "ZDOTDIR=" + root.path, "TERM=xterm-256color"]
        session.launchCommand = "exec " + tmux + " -T sync -L " + socket + " -f /dev/null new-session -s fixture /bin/sh"
        session.tmuxLocation = .init(sessionID: "$0")
        session.start()
        for _ in 0..<100 {
            if !(try run(["list-clients"])).isEmpty { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        func key(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code))
            XCTAssertTrue(session.handleTerminalKey(event))
        }
        let features = try run(["list-clients", "-F", "#{client_termfeatures}"])
        XCTAssertTrue(features.contains("sync"), "Crow tmux clients must negotiate synchronized output")
        try key(11, "ㅠ", .control); try key(8, "ㅊ")
        var windows = ""
        for _ in 0..<100 {
            windows = try run(["list-windows", "-F", "#{window_id}"])
            if windows.split(separator: "\n").count == 2 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(windows.split(separator: "\n").count, 2)
        try key(11, "b", .control); try key(23, "%", .shift)
        var panes = ""
        for _ in 0..<100 {
            panes = try run(["list-panes", "-F", "#{pane_id}"])
            if panes.split(separator: "\n").count == 2 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(panes.split(separator: "\n").count, 2)
    }

    @MainActor func testRealShellInputResizeAndWorkspaceRetention() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crow-pty-" + UUID().uuidString)
        let model = AppModel(vaultURL: directory)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let workspaceID = model.selectedWorkspaceID
        let terminalID = model.current.snapshot.selectedTerminalID!
        let session = model.terminal(terminalID, in: model.current)
        // Reproduce a GUI launch with a non-UTF-8 inherited locale.
        session.shellEnvironment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", "LC_ALL=C", "ZDOTDIR=\(directory.path)"]
        session.start()
        defer { session.stop() }
        XCTAssertTrue(session.running)
        let view = session.view
        func type(_ text: String) { view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        // Use terminal key callbacks, not direct output injection.
        type("printf '__CROW_%s__\\n' PTY; pwd\n")
        try await waitUntil { self.screen(view).contains("__CROW_PTY__") }
        try await waitUntil {
            self.screen(view).replacingOccurrences(of: "\n", with: "").contains(directory.resolvingSymlinksInPath().path)
        }
        type("printf '__DELETE_%s__\\n' abX")
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        type("c\n")
        try await waitUntil { self.screen(view).contains("__DELETE_abc__") }
        type("printf '__KOREAN_%s__\\n' 한글")
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        type("국\n")
        try await waitUntil { self.screen(view).contains("__KOREAN_한국__") }
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 350)
        let dimensions = view.getTerminal().getDims()
        type("printf '__SIZE__'; stty size\n")
        try await waitUntil { self.screen(view).contains("__SIZE__\(dimensions.rows) \(dimensions.cols)") }
        let other = WorkspaceState(.init(workspace: Workspace(name: "Other", kind: .local, connection: .local), rootPath: model.vaultURL.path))
        model.states.append(other)
        model.selectWorkspace(other.id)
        model.selectWorkspace(workspaceID)
        XCTAssertTrue(model.terminal(terminalID, in: model.current) === session)
        type("sleep 20\n")
        try await Task.sleep(for: .milliseconds(100))
        view.terminalDelegate?.send(source: view, data: [0x03])
        type("printf '__AFTER_%s__\\n' INTERRUPT\n")
        try await waitUntil { self.screen(view).contains("__AFTER_INTERRUPT__") }
        model.newTerminal()
        let second = model.terminal(model.current.snapshot.selectedTerminalID!, in: model.current)
        XCTAssertFalse(second === session)
        // A new tab in the same workspace must also work with no locale at all,
        // as when the app is opened from Finder rather than a UTF-8 shell.
        second.shellEnvironment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "ZDOTDIR=\(directory.path)"]
        second.start()
        second.view.insertText("printf '__READY_%s__\\n' SECOND\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil { self.screen(second.view).contains("__READY_SECOND__") }
        second.view.insertText("printf '__NEW_TAB_%s__\\n' 한글", replacementRange: NSRange(location: NSNotFound, length: 0))
        second.view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        second.view.insertText("국\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil { self.screen(second.view).contains("__NEW_TAB_한국__") }
    }

    @MainActor func testIMECommitOnlySendsCommittedBytes() {
        let workspace = Workspace(name: "Local", kind: .local, connection: .local)
        let session = TerminalSession(id: UUID(), workspace: workspace, directory: "/tmp", remote: nil, fontSize: 16)
        var sent: [UInt8] = []
        session.onBytes = { sent += $0 }
        session.view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(sent.isEmpty)
        session.view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(sent, Array("한".utf8))
        session.view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(sent, Array("한".utf8) + [0x7f])
    }

    @MainActor private func screen(_ view: TerminalView) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).compactMap { row in
            terminal.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
                characterProvider: terminal.getCharacter(for:))
        }.joined(separator: "\n")
    }

    @MainActor private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Terminal output did not arrive within 7.5 seconds", file: file, line: line)
    }

    @MainActor func testDeadProgramDoesNotKeepTypingMouseMotion() async throws {
        XCTAssertEqual(TerminalInputCapture.action(mouse: .anyEvent, foreground: .shell, prompted: false), .application)
        XCTAssertEqual(TerminalInputCapture.action(mouse: .buttonEventTracking, foreground: .shell, prompted: false), .application)
        XCTAssertEqual(TerminalInputCapture.action(mouse: .anyEvent, foreground: .unknown, prompted: true), .hover)
        XCTAssertEqual(TerminalInputCapture.action(mouse: .buttonEventTracking, foreground: .unknown, prompted: true), .none,
            "Button tracking belongs to tmux and must survive a shell prompt inside it")
        XCTAssertEqual(TerminalInputCapture.action(mouse: .anyEvent, foreground: .child, prompted: true), .none)
        let session = TerminalSession(id: UUID(), workspace: Workspace(name: "Mouse", kind: .local, connection: .local),
            directory: "/tmp", remote: nil, fontSize: 16)
        let view = session.view
        view.feedProcessOutput(Array("\u{1b}[?2004h\u{1b}[?1002h\u{1b}[?1006h\u{1b}]7;file://localhost/tmp\u{7}".utf8)[...])
        session.releaseAbandonedInputCapture()
        XCTAssertEqual(view.getTerminal().mouseMode, .buttonEventTracking)
        XCTAssertTrue(view.getTerminal().bracketedPasteMode)
        view.feedProcessOutput(Array("\u{1b}[?1003h\u{1b}[?1h\u{1b}[=1;1u\u{1b}]7;file://localhost/tmp\u{7}".utf8)[...])
        session.releaseAbandonedInputCapture()
        XCTAssertEqual(view.getTerminal().mouseMode, .off)
        XCTAssertTrue(view.getTerminal().bracketedPasteMode, "Shell paste mode is not part of the dead program's tracking")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crow-mouse-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let live = TerminalSession(id: UUID(), workspace: Workspace(name: "Mouse", kind: .local, connection: .local),
            directory: directory.path, remote: nil, fontSize: 16)
        live.shellEnvironment = ["PATH=/usr/bin:/bin", "LANG=en_US.UTF-8", "ZDOTDIR=" + directory.path, "TERM=xterm-256color"]
        live.start()
        defer { live.stop(); try? FileManager.default.removeItem(at: directory) }
        func type(_ text: String) { live.view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        type("printf '\\033[?1003h\\033[?1006h__SHELL_%s__\\n' DONE\n")
        try await waitUntil { self.screen(live.view).contains("__SHELL_DONE__") }
        XCTAssertEqual(live.view.getTerminal().mouseMode, .off, "The shell must not keep motion reports after it prints them")
        type("/bin/sh -c 'printf \"\\033[?1003h\\033[?1006h\"; sleep 1'\n")
        try await waitUntil { live.view.getTerminal().mouseMode == .anyEvent }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(live.view.getTerminal().mouseMode, .anyEvent, "A running program keeps motion tracking")
        try await waitUntil { live.view.getTerminal().mouseMode == .off }
    }
}
#endif

#if os(iOS)
import UIKit
import SwiftUI

private final class KoreanInputMode: UITextInputMode {
    override var primaryLanguage: String? { "ko-KR" }
}

private final class KoreanTerminalView: CrowIOSTerminalView {
    var koreanEnabled = true
    override var textInputMode: UITextInputMode? { koreanEnabled ? KoreanInputMode() : nil }
}

final class IOSTerminalIntegrationTests: XCTestCase {
    @MainActor
    func testPhoneAccessorySendsTerminalKeysAndResetsControl() throws {
        let view = CrowIOSTerminalView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        let original = view.inputAccessoryView
        let coordinator = TerminalCoordinator()
        view.terminalDelegate = coordinator
        var sent: [UInt8] = []
        coordinator.onBytes = { sent += $0 }
        view.setPhoneAccessory(true)
        let accessory = try XCTUnwrap(view.inputAccessoryView as? CrowKeyboardAccessory)
        accessory.configure(KeyboardBarKey.defaults + [KeyboardBarKey(key: "Tab", shift: true)])
        let scroll = try XCTUnwrap(accessory.subviews.compactMap { $0 as? UIScrollView }.first)
        let row = try XCTUnwrap(scroll.subviews.compactMap { $0 as? UIStackView }.first)
        func button(_ label: String) throws -> UIButton {
            try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label })
        }
        try button("esc").sendActions(for: .touchUpInside)
        try button("tab").sendActions(for: .touchUpInside)
        try button("shift+tab").sendActions(for: .touchUpInside)
        XCTAssertEqual(sent, [0x1b, 0x09, 0x1b, 0x5b, 0x5a])
        sent = []
        try button("ctrl").sendActions(for: .touchUpInside)
        XCTAssertTrue(view.controlModifier)
        view.insertText("c")
        XCTAssertEqual(sent, [0x03])
        XCTAssertFalse(view.controlModifier)
        XCTAssertFalse(try button("ctrl").isSelected)
        sent = []
        try button("←").sendActions(for: .touchUpInside)
        try button("→").sendActions(for: .touchUpInside)
        XCTAssertEqual(sent, Array("\u{1b}[D\u{1b}[C".utf8))
        sent = []
        view.getTerminal().applicationCursor = true
        try button("↑").sendActions(for: .touchUpInside)
        try button("↓").sendActions(for: .touchUpInside)
        XCTAssertEqual(sent, Array("\u{1b}OA\u{1b}OB".utf8))
        view.setPhoneAccessory(false)
        XCTAssertTrue(view.inputAccessoryView === original)
    }

    @MainActor
    func testVisibleSSHSessionReceivesPromptAndKeyboardInput() async throws {
        struct Fixture: Decodable {
            var port: Int
            var username: String
            var privateKey: String
            var directory: String
            var screenPort: Int
            var screenEvents: String
        }
        let fixtureURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("crow-ios-ssh-fixture.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Run python3 scripts/test-ios-ssh.py SIMULATOR_UDID to provide an isolated SSH server")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-ios-terminal-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        var host = SSHHost(name: "Loopback", hostname: "127.0.0.1", port: fixture.port,
            username: fixture.username, remotePath: fixture.directory)
        host.authentication = .ed25519
        let pin = "host-key:127.0.0.1:\(fixture.port)"
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let keyboard = PhoneKeyboardFocus()
        window.rootViewController = UIHostingController(rootView: CompactWorkspaceView(keyboard: keyboard).environment(model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            model.shutdown()
            try? SecureStore.remove(host.id.rawValue.uuidString)
            try? SecureStore.remove(pin)
            try? FileManager.default.removeItem(at: root)
        }
        try SecureStore.remove(pin)
        try model.storeHost(host, credential: HostCredential(privateKey: fixture.privateKey))
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail(message + ": " + model.statusMessage)
        }
        model.connect(host)
        try await wait("First connection must request host verification") { model.hostKeyChallenge != nil }
        let challenge = try XCTUnwrap(model.hostKeyChallenge)
        model.hostKeyChallenge = nil
        model.trustHostKey(challenge)
        try await wait("SSH connection did not finish") { model.connectionState(for: host) == .connected }
        let id = try XCTUnwrap(model.current.snapshot.selectedTerminalID)
        try await wait("Visible terminal did not start") { model.current.terminals[id]?.running == true }
        let session = try XCTUnwrap(model.current.terminals[id])
        let remote = try XCTUnwrap(model.current.remote)
        let repository = try await remote.gitStatus(path: fixture.directory)
        let projects = try await remote.gitProjects(path: fixture.directory)
        XCTAssertEqual(projects.paths, [repository.root], "A repository vault must be listed before selecting its status")
        XCTAssertTrue(repository.status.branch.contains("crow-fixture"))
        XCTAssertEqual(repository.remote?.displayAddress, "github.com/fixture/repository")
        XCTAssertEqual(repository.authorName, "iPad Fixture")
        XCTAssertEqual(repository.authorEmail, "fixture@example.org")
        XCTAssertTrue(repository.status.changes.contains { $0.path == "note.md" })
        func screen(_ target: TerminalSession? = nil) -> String {
            let terminal = (target ?? session).view.getTerminal()
            return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
        }
        session.view.insertText("printf '__IOS_%s__\\n' WORKS")
        session.view.insertText("\n")
        try await wait("SSH terminal did not execute UIKit input (\(session.status))") { screen().contains("__IOS_WORKS__") }
        let quotedFolder = "'" + fixture.directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        session.view.insertText("test \"$PWD\" -ef " + quotedFolder + " && printf '__FOLDER_%s__\\n' OK\n")
        try await wait("Terminal ignored the configured folder") { screen().contains("__FOLDER_OK__") }
        try await wait("Terminal did not report its current folder") { session.currentDirectory == repository.root }
        session.view.insertText("cd /tmp\n")
        try await wait("Terminal folder did not follow cd") { session.currentDirectory == "/tmp" }
        session.view.insertText("cd -- " + quotedFolder + "\n")
        try await wait("Terminal folder did not follow return to project") { session.currentDirectory == repository.root }
        XCTAssertNotNil(session.view.window, "The working terminal must be the one displayed on screen")
        keyboard.show(for: .terminal)
        model.compactSurface = .hosts
        try await wait("Leaving Terminal did not release keyboard focus") { !session.view.isFirstResponder }
        XCTAssertTrue(session.running, "Opening another screen must keep the SSH shell alive")
        model.compactSurface = .terminal
        XCTAssertNotNil(session.view.window, "Keep the terminal mounted so switching screens can transfer keyboard focus")
        XCTAssertTrue(model.current.terminals[id] === session)
        keyboard.show(for: .terminal)
        XCTAssertTrue(session.view.isFirstResponder)
        for _ in 0..<2 {
            _ = session.view.resignFirstResponder()
            XCTAssertFalse(session.view.isFirstResponder)
            keyboard.show(for: .terminal)
            XCTAssertTrue(session.view.isFirstResponder, "The bottom keyboard button must restore the displayed SSH terminal")
        }
        session.view.insertText("printf '__IOS_%s__\\n' RETURNED")
        session.view.insertText("\n")
        try await wait("Restored SSH terminal lost keyboard input") { screen().contains("__IOS_RETURNED__") }

        model.suspend()
        XCTAssertTrue(remote.isConnected)
        XCTAssertTrue(session.running)
        model.resume()
        session.view.insertText("printf '__BACKGROUND_%s__\\n' RETURNED\n")
        try await wait("A short background transition must preserve the original shell") { screen().contains("__BACKGROUND_RETURNED__") }
        XCTAssertTrue(model.current.remote === remote)
        XCTAssertTrue(model.current.terminals[id] === session)
        try await ScreenIntegrationChecks.verify(in: model.current, port: fixture.screenPort, events: fixture.screenEvents)

        let backgroundState = model.current
        let localID = try XCTUnwrap(model.states.first(where: { !$0.snapshot.workspace.isRemote })?.id)
        model.selectWorkspace(localID)
        model.compactSurface = .files
        model.suspend()
        await remote.disconnect() // Simulate a socket lost while iOS suspends the app.
        model.resume()
        try await wait("A lost background SSH connection must reconnect") {
            backgroundState.remote !== remote && backgroundState.snapshot.workspace.connection == .connected
        }
        XCTAssertEqual(model.selectedWorkspaceID, localID, "Recovery must not switch the selected workspace")
        XCTAssertEqual(model.compactSurface, .files, "Recovery must not force the terminal screen")
        model.selectWorkspace(backgroundState.id)
        model.compactSurface = .terminal

        // Every new shell starts in its workspace folder, independently of the host default.
        host.remotePath = "~"
        try model.storeHost(host, credential: HostCredential(privateKey: fixture.privateKey))
        model.reconnectCurrent()
        try await wait("Reconnect did not finish") { model.connectionState(for: host) == .connected }
        try await wait("Reconnected terminal did not start") {
            model.current.terminals[id]?.running == true && model.current.terminals[id] !== session
        }
        let reconnected = try XCTUnwrap(model.current.terminals[id])
        reconnected.view.insertText("test \"$PWD\" -ef " + quotedFolder + " && printf '__PROJECT_%s__\\n' OK\n")
        try await wait("Restored workspace did not set the terminal folder") { screen(reconnected).contains("__PROJECT_OK__") }
        XCTAssertEqual(model.current.snapshot.rootPath, fixture.directory, "The explorer should retain its selected project")

        // WSL workspaces follow the same folder rule.
        host.usesWSL = true
        try model.storeHost(host, credential: HostCredential(privateKey: fixture.privateKey))
        model.reconnectCurrent()
        try await wait("WSL-mode reconnect did not finish") { model.connectionState(for: host) == .connected }
        try await wait("WSL-mode terminal did not start") {
            model.current.terminals[id]?.running == true && model.current.terminals[id] !== reconnected
        }
        let wslSession = try XCTUnwrap(model.current.terminals[id])
        wslSession.view.insertText("test \"$PWD\" -ef " + quotedFolder + " && printf '__WSL_FOLDER_%s__\\n' OK\n")
        try await wait("WSL mode did not preserve the project-folder workaround") { screen(wslSession).contains("__WSL_FOLDER_OK__") }

        // Mount the detail component created when the user selects a project.
        // Its SwiftUI task must update the rendered state, not only the SSH API.
        let gitState = GitProjectStatusState()
        XCTAssertNil(gitState.repository)
        window.rootViewController = UIHostingController(rootView:
            GitProjectStatusView(path: repository.root, refreshID: UUID(), status: gitState).environment(model))
        try await wait("Selected SSH project did not load its status view") { gitState.repository != nil || gitState.error != nil }
        XCTAssertNil(gitState.error)
        XCTAssertEqual(gitState.repository?.status.branch, repository.status.branch)
        XCTAssertEqual(gitState.repository?.status.changes, repository.status.changes)
        let failedGitState = GitProjectStatusState()
        window.rootViewController = UIHostingController(rootView:
            GitProjectStatusView(path: repository.root + "/missing-project", refreshID: UUID(), status: failedGitState).environment(model))
        try await wait("Failed Git status must display an error instead of remaining blank") { failedGitState.error != nil }
        XCTAssertNil(failedGitState.repository)

        let imagePath = (fixture.directory as NSString).appendingPathComponent("download.png")
        model.openFile(.init(name: "download.png", path: imagePath, isDirectory: false))
        let image = try XCTUnwrap(model.selectedBuffer)
        XCTAssertTrue(image.isImage)
        let imageBytes = try await model.downloadOpenFile(image.id)
        XCTAssertEqual(imageBytes, InputToolsTests.png)
        let moveFolders = try await model.fileMoveFolders(image.id, at: fixture.directory)
        let destination = try XCTUnwrap(moveFolders.folders.first { $0.name == "Move Destination" })
        try await model.moveOpenFile(image.id, to: destination.path)
        XCTAssertEqual(model.selectedBuffer?.path, destination.path + "/download.png")
        let movedBytes = try await model.downloadOpenFile(image.id)
        XCTAssertEqual(movedBytes, imageBytes)


        model.suspend()
        model.disconnect(host)
        model.resume()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.connectionState(for: host), .disconnected, "An explicit disconnect must never auto-reconnect")

    }

    @MainActor
    func testCompoundVowelsUpdatePTYAndUIKitContext() {
        for (base, vowel, expected) in [
            ("도", "ㅏ", "돠"), ("도", "ㅐ", "돼"), ("도", "ㅣ", "되"),
            ("두", "ㅓ", "둬"), ("두", "ㅔ", "뒈"), ("두", "ㅣ", "뒤"), ("으", "ㅣ", "의"),
        ] {
            let view = KoreanTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
            let coordinator = TerminalCoordinator()
            view.terminalDelegate = coordinator
            var sent: [UInt8] = []
            coordinator.onBytes = { sent += $0 }
            view.insertText("앞😀" + base)
            view.insertText(vowel)
            XCTAssertEqual(sent, Array(("앞😀" + base).utf8) + [0x7f] + Array(expected.utf8))
            XCTAssertEqual(context(view), "앞😀" + expected)
            XCTAssertEqual(view.offset(from: view.beginningOfDocument, to: view.selectedTextRange!.end), 4)
            view.deleteBackward()
            XCTAssertEqual(context(view), "앞😀")
            XCTAssertEqual(sent.last, 0x7f)
        }
    }

    @MainActor
    func testMarkedCompoundVowelOnlySendsOnCommit() {
        let view = KoreanTerminalView(frame: .zero)
        let coordinator = TerminalCoordinator()
        view.terminalDelegate = coordinator
        var sent: [UInt8] = []
        coordinator.onBytes = { sent += $0 }
        for text in ["ㄷ", "두", "뒈"] {
            view.setMarkedText(text, selectedRange: NSRange(location: 1, length: 0))
            XCTAssertTrue(sent.isEmpty)
        }
        view.unmarkText()
        XCTAssertEqual(sent, Array("뒈".utf8))
        XCTAssertEqual(context(view), "뒈")
    }

    @MainActor
    func testPasteSpacesAndKeyboardSwitchDoNotMerge() {
        let view = KoreanTerminalView(frame: .zero)
        view.insertText("두ㅔ")
        XCTAssertEqual(context(view), "두ㅔ")
        view.insertText(" 도 ")
        view.insertText("ㅣ")
        XCTAssertEqual(context(view), "두ㅔ 도 ㅣ")
        view.insertText(" 도")
        view.koreanEnabled = false
        view.insertText("ㅣ")
        XCTAssertEqual(context(view), "두ㅔ 도 ㅣ 도ㅣ")
    }

    @MainActor
    func testCompoundVowelStillAcceptsFinalAndResyllabifies() {
        let view = KoreanTerminalView(frame: .zero)
        view.insertText("도")
        view.insertText("ㅣ")
        view.insertText("ㄴ")
        XCTAssertEqual(context(view), "된")
        view.insertText("ㅏ")
        XCTAssertEqual(context(view), "되나")
    }

    @MainActor
    func testMarkedTextAndSelectedReplacementDoNotMergeWithPreviousSyllable() {
        let view = KoreanTerminalView(frame: .zero)
        view.insertText("도")
        view.setMarkedText("ㅣ", selectedRange: NSRange(location: 1, length: 0))
        view.insertText("ㅣ")
        XCTAssertEqual(context(view), "도ㅣ")

        let start = view.position(from: view.beginningOfDocument, offset: 1)!
        view.selectedTextRange = view.textRange(from: start, to: view.endOfDocument)
        view.insertText("ㅐ")
        XCTAssertEqual(context(view), "도ㅐ")
    }

    @MainActor
    func testSessionUsesIOSTerminalView() {
        let session = TerminalSession(id: UUID(),
            workspace: Workspace(name: "Local", kind: .local, connection: .local),
            directory: "/tmp", remote: nil, fontSize: 16)
        XCTAssertTrue(session.view is CrowIOSTerminalView)
    }

    @MainActor
    private func context(_ view: TerminalView) -> String? {
        guard let range = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument) else { return nil }
        return view.text(in: range)
    }
}
#endif
