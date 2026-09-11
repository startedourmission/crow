import XCTest
import CrowCore
import SwiftTerm
@testable import Crow
#if os(macOS)
import AppKit

final class TerminalIntegrationTests: XCTestCase {
    @MainActor func testRealShellInputResizeAndWorkspaceRetention() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crow-pty-" + UUID().uuidString)
        let model = AppModel(vaultURL: directory)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let workspaceID = model.selectedWorkspaceID
        let terminalID = model.current.snapshot.selectedTerminalID!
        let session = model.terminal(terminalID, in: model.current)
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

    @MainActor private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Terminal output did not arrive within 7.5 seconds")
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
    func testVisibleSSHSessionReceivesPromptAndKeyboardInput() async throws {
        struct Fixture: Decodable {
            var port: Int
            var username: String
            var privateKey: String
            var directory: String
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
        window.rootViewController = UIHostingController(rootView: CompactWorkspaceView().environment(model))
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
        func screen() -> String {
            let terminal = session.view.getTerminal()
            return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
        }
        session.view.insertText("printf '__IOS_%s__\\n' WORKS")
        session.view.insertText("\n")
        try await wait("SSH terminal did not execute UIKit input (\(session.status))") { screen().contains("__IOS_WORKS__") }
        XCTAssertNotNil(session.view.window, "The working terminal must be the one displayed on screen")
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
