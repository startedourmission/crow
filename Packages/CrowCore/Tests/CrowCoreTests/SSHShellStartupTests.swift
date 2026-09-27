import XCTest
@testable import CrowCore

final class SSHShellStartupTests: XCTestCase {
    private func readyMarker(_ startup: SSHShellStartup) -> [UInt8] {
        Array("\u{1b}]1337;CrowReady=\(startup.token)\u{7}".utf8)
    }
    private func startupMarker(_ startup: SSHShellStartup) -> [UInt8] {
        Array("\u{1b}]1337;CrowStartup=\(startup.token)\u{7}".utf8)
    }

    func testStartupScriptIsReleasedOnlyAfterReadinessMarker() {
        var startup = SSHShellStartup(setup: "printf 'setup\\n'")
        XCTAssertTrue(startup.probe.hasSuffix("\n"))
        XCTAssertFalse(startup.probe.dropLast().contains("\n"), "The probe must be one short line")
        XCTAssertLessThan(startup.probe.utf8.count, 512, "The probe is typed ahead and must fit a canonical PTY line")
        XCTAssertFalse(startup.probe.contains("setup"), "Nothing but the probe may be typed before readiness")

        // Banners, the echoed probe (its escapes are still literal text) and a split
        // marker prefix must not release the startup script.
        for chunk in ["Last login: today\r\n", startup.probe.replacingOccurrences(of: "\n", with: "\r\n"), "\u{1b}]1337;CrowRea"] {
            let step = startup.receive(Array(chunk.utf8))
            XCTAssertNil(step.send, chunk); XCTAssertEqual(step.visible, [])
        }
        XCTAssertFalse(startup.isShellReady)

        var sent: [String] = []
        // SSH packets may split the marker at any byte.
        for byte in readyMarker(startup).dropFirst("\u{1b}]1337;CrowRea".utf8.count) {
            let step = startup.receive([byte])
            if let script = step.send { sent.append(script) }
            XCTAssertEqual(step.visible, [])
        }
        XCTAssertTrue(startup.isShellReady); XCTAssertFalse(startup.isReady)
        XCTAssertEqual(sent.count, 1)
        let script = sent.first ?? ""
        XCTAssertTrue(script.contains("printf 'setup\\n'"), script)
        XCTAssertTrue(script.hasSuffix("\n}\n\u{1f}"), "The script ends with the probe's read delimiter")

        // Echo of the startup group stays hidden; output after its marker is shown.
        XCTAssertNil(startup.receive(Array("{\r\n> printf\r\n".utf8)).send)
        let step = startup.receive(startupMarker(startup) + Array("visible".utf8))
        XCTAssertNil(step.send, "The startup script is sent exactly once")
        XCTAssertEqual(String(decoding: step.visible, as: UTF8.self), "visible")
        XCTAssertTrue(startup.isReady)
        XCTAssertEqual(startup.receive(Array("normal output".utf8)).visible, Array("normal output".utf8))
    }

    func testShellsWithoutReadDelimiterGetLineByLineStartup() {
        var startup = SSHShellStartup(setup: "printf 'setup\\n'")
        let marker = Array("\u{1b}]1337;CrowReadyLine=\(startup.token)\u{7}".utf8)
        var sent: [String] = []
        for byte in marker { if let script = startup.receive([byte]).send { sent.append(script) } }
        XCTAssertTrue(startup.isShellReady)
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent.first?.hasSuffix("printf 'setup\\n'\n}\n") == true, "No read delimiter for sh/dash")
    }

    func testReadinessTimeoutIsBoundedAndNeverSendsStartup() {
        let start = ContinuousClock.now
        var startup = SSHShellStartup(setup: "printf 'setup\\n'", timeout: .seconds(5), now: start)
        XCTAssertEqual(startup.deadline, start + .seconds(5))
        XCTAssertEqual(SSHShellStartup.readinessTimeout, .seconds(20))
        XCTAssertFalse(SSHShellStartup.readinessTimeoutMessage.isEmpty)

        // An authentication prompt or a program that never runs the probe.
        let step = startup.receive(Array("Password: ".utf8) + Array(startup.probe.utf8))
        XCTAssertNil(step.send); XCTAssertEqual(step.visible, [])
        XCTAssertFalse(startup.timedOut(at: start + .milliseconds(4_999)))
        XCTAssertTrue(startup.timedOut(at: start + .seconds(5)))
        XCTAssertTrue(startup.timedOut(at: start + .seconds(60)))
        XCTAssertFalse(startup.isShellReady)

        // Once the shell reported readiness, the deadline no longer applies.
        var ready = SSHShellStartup(setup: "true", timeout: .seconds(5), now: start)
        XCTAssertNotNil(ready.receive(readyMarker(ready)).send)
        XCTAssertFalse(ready.timedOut(at: start + .seconds(60)))
    }

    #if os(macOS)
    func testStartupWaitsForShellReadinessInRealPTY() throws {
        // Repeated because the bug this replaces (type-ahead corrupted by bash 3.2
        // readline on macOS PTYs) failed most, but not all, runs.
        for shell in ["/bin/bash", "/bin/zsh", "/bin/dash"] where FileManager.default.isExecutableFile(atPath: shell) {
            for run in 1...(shell == "/bin/dash" ? 5 : 20) {
                try assertReadyStartup(shell: shell, run: run)
            }
        }
    }

    private func assertReadyStartup(shell: String, run: Int) throws {
        let label = "\(shell) run \(run)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-ready-한글 ' " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = TerminalCommand.utf8Environment + "\n" + SSHCommand.remoteDirectoryCommand(root.path)
            + "\n" + SSHCommand.directoryTrackingCommand + "\nprintf 'visible-error\\n' >&2\n"
        let arguments = ["/bin/bash": ["--noprofile", "--norc"], "/bin/zsh": ["-f"]][shell] ?? []
        let pty = try PTYProcess([shell] + arguments)
        defer { pty.stop() }
        var startup = SSHShellStartup(setup: setup)
        try pty.write(startup.probe)
        var raw = Data(), visible: [UInt8] = [], sentScript = 0, sentExit = false
        let deadline = Date() + 10
        while Date() < deadline {
            let (chunk, finished) = pty.take()
            raw.append(chunk)
            for byte in chunk { // split every marker byte, as SSH packets may do
                let step = startup.receive([byte])
                visible += step.visible
                if let script = step.send {
                    XCTAssertTrue(startup.isShellReady, label)
                    sentScript += 1
                    try pty.write(script)
                }
            }
            if startup.isReady && !sentExit { sentExit = true; try pty.write("exit\n") }
            if finished { break }
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.005) } // poll interval, not a readiness wait
        }
        pty.process.waitUntilExit()
        let text = String(decoding: visible, as: UTF8.self)
        XCTAssertEqual(pty.process.terminationStatus, 0, label + ": " + String(decoding: raw, as: UTF8.self))
        XCTAssertEqual(sentScript, 1, label)
        XCTAssertTrue(startup.isReady, label + ": " + String(decoding: raw, as: UTF8.self))
        for hidden in ["crow_utf8_locale", "_crow_cwd(){", "CrowStartup=", "CrowReady=", "crow_startup", "command not found"] {
            XCTAssertFalse(text.contains(hidden), label + ": " + text)
        }
        XCTAssertTrue(text.contains("visible-error"), label + ": " + text)
        // The directory hook is bash/zsh only; sh/dash still get the group and its errors.
        guard shell != "/bin/dash" else { return }
        let start = try XCTUnwrap(text.range(of: "\u{1b}]7;"), label + ": " + text)
        let end = try XCTUnwrap(text[start.upperBound...].firstIndex(of: "\u{7}"), label)
        let path = try XCTUnwrap(SSHCommand.terminalDirectory(String(text[start.upperBound..<end])), label)
        XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath(), root.resolvingSymlinksInPath(), label)
    }

    func testReadinessTimeoutInRealPTYNeverTypesStartupIntoNonShell() throws {
        // `cat` stands in for anything that is not a ready shell (a password prompt,
        // a forced command, a menu): it echoes the probe but never executes it.
        let pty = try PTYProcess(["/bin/cat"])
        defer { pty.stop() }
        var startup = SSHShellStartup(setup: "printf 'setup-leaked\\n'", timeout: .milliseconds(700))
        try pty.write(startup.probe)
        var raw = Data(), sent = false
        let hardStop = Date() + 10
        while !startup.timedOut(), Date() < hardStop {
            let (chunk, finished) = pty.take()
            raw.append(chunk)
            if let script = startup.receive(Array(chunk)).send { sent = true; try pty.write(script) }
            if finished { break }
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertTrue(startup.timedOut(), "The readiness wait must end at its deadline")
        XCTAssertFalse(startup.isShellReady); XCTAssertFalse(startup.isReady); XCTAssertFalse(sent)
        let output = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(output.contains("CrowReady="), "The probe reached the program: " + output)
        XCTAssertFalse(output.contains("setup-leaked"), output)
    }
    #endif
}

#if os(macOS)
/// A shell (or other program) behind a real PTY, read without blocking the test.
private final class PTYProcess: @unchecked Sendable {
    let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var buffer = Data(), finished = false

    init(_ command: [String]) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null"] + command
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if data.isEmpty { self.finished = true; handle.readabilityHandler = nil } else { self.buffer.append(data) }
        }
        try process.run()
    }

    func write(_ text: String) throws { try input.fileHandleForWriting.write(contentsOf: Data(text.utf8)) }

    /// New output since the last call, and whether the PTY has closed.
    func take() -> (Data, Bool) {
        lock.lock(); defer { lock.unlock() }
        let data = buffer; buffer.removeAll()
        return (data, finished && data.isEmpty)
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}
#endif
