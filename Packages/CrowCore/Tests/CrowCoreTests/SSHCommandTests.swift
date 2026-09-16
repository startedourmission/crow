import XCTest
@testable import CrowCore

final class SSHCommandTests: XCTestCase {
    func testUserHostPortAndQuotedKey() throws {
        let parsed = try SSHCommand("ssh person@example.org -p 2222 -i '/a key/id_ed25519'")
        XCTAssertEqual(parsed.arguments, ["person@example.org", "-p", "2222", "-i", "/a key/id_ed25519"])
        XCTAssertTrue(SSHCommand.isInteractive(parsed.arguments))
        let (host, identity) = try parsed.portableHost(defaultUsername: "unused")
        XCTAssertEqual(host.username, "person"); XCTAssertEqual(host.hostname, "example.org")
        XCTAssertEqual(host.port, 2222); XCTAssertEqual(identity, "/a key/id_ed25519")
    }
    func testAliasIPv6AndAttachedOptions() throws {
        XCTAssertTrue(SSHCommand.isInteractive(try SSHCommand("ssh production").arguments))
        let (host, _) = try SSHCommand("ssh -p2200 -lperson '[::1]'").portableHost(defaultUsername: "")
        XCTAssertEqual(host.hostname, "::1"); XCTAssertEqual(host.username, "person"); XCTAssertEqual(host.port, 2200)
    }
    func testNeverEvaluatesShellSyntax() {
        for line in ["echo ssh host", "ssh host; touch x", "ssh $(whoami)@host", "ssh host | tee x", "ssh 'unfinished"] {
            XCTAssertThrowsError(try SSHCommand(line))
        }
    }
    func testNoninteractiveCommandsAreNotImported() throws {
        for line in ["ssh host uptime", "ssh -N -L 8080:localhost:80 host", "ssh -G host", "ssh -O exit host", "ssh -T host", "ssh -p"] {
            XCTAssertFalse(SSHCommand.isInteractive(try SSHCommand(line).arguments), line)
        }
        XCTAssertTrue(SSHCommand.isInteractive(try SSHCommand("ssh -v -p 2222 -o 'IdentityFile=/a key' person@host").arguments))
    }

    #if os(macOS)
    func testStartupHidesEchoInRealPTYAndPreservesDirectoryAndErrors() throws {
        for shell in ["/bin/bash", "/bin/zsh"] {
            var startup = SSHStartupOutput()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-startup-한글 ' " + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let setup = TerminalCommand.utf8Environment + "\n" + SSHCommand.remoteDirectoryCommand(root.path)
                + "\n" + SSHCommand.directoryTrackingCommand + "\nprintf 'visible-error\\n' >&2\n"
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", shell] + (shell == "/bin/bash" ? ["--noprofile", "--norc"] : ["-f"])
            process.standardInput = input; process.standardOutput = output; process.standardError = output
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            defer { timeout.cancel() }
            try input.fileHandleForWriting.write(contentsOf: Data((startup.command(setup) + "exit\n").utf8))
            try input.fileHandleForWriting.close()
            let raw = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, shell)
            // Deliberately split every marker byte, as SSH packets may do.
            let visible = raw.flatMap { startup.receive([$0]) }
            let text = String(decoding: visible, as: UTF8.self)
            XCTAssertTrue(startup.isReady, shell + ": " + String(decoding: raw, as: UTF8.self))
            XCTAssertFalse(text.contains("crow_utf8_locale"), text)
            XCTAssertFalse(text.contains("_crow_cwd(){"), text)
            XCTAssertFalse(text.contains("CrowStartup="), text)
            XCTAssertTrue(text.contains("visible-error"), text)
            let start = try XCTUnwrap(text.range(of: "\u{1b}]7;"))
            let end = try XCTUnwrap(text[start.upperBound...].firstIndex(of: "\u{7}"))
            let path = try XCTUnwrap(SSHCommand.terminalDirectory(String(text[start.upperBound..<end])))
            XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
            XCTAssertEqual(startup.receive(Array("normal output".utf8)), Array("normal output".utf8))
        }
    }

    func testDirectoryPromptHookTracksQuotedUnicodePathsAndPreservesHooks() throws {
        XCTAssertLessThan(SSHCommand.directoryTrackingCommand.utf8.count, 900,
            "The startup hook must fit in a PTY's canonical input buffer")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-cwd-" + UUID().uuidString)
        let folder = root.appendingPathComponent("한글 #' ? % folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for shell in ["/bin/bash", "/bin/zsh", "/bin/sh"] {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: shell)
            process.currentDirectoryURL = folder
            let previous = shell == "/bin/zsh" ? "precmd_functions=(existing_hook); " : "PROMPT_COMMAND='existing_hook'; "
            let inspect = shell == "/bin/zsh" ? "printf '%s' \"${precmd_functions[*]}\"" : "printf '%s' \"$PROMPT_COMMAND\""
            process.arguments = ["-c", previous + SSHCommand.directoryTrackingCommand + "; " + inspect]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, shell)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(text.contains("existing_hook"), shell)
            if let start = text.range(of: "\u{1b}]7;"), let end = text[start.upperBound...].firstIndex(of: "\u{7}") {
                let path = try XCTUnwrap(SSHCommand.terminalDirectory(String(text[start.upperBound..<end])), shell + ": " + text)
                XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath(), folder.resolvingSymlinksInPath(), shell)
            } else if shell != "/bin/sh" { XCTFail("No directory report from " + shell) }
        }
    }

    func testRemoteStartFolderUsesHomeAndPreservesLiteralPathCharacters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-shell-path-" + UUID().uuidString)
        let home = root.appendingPathComponent("home with ' spaces")
        let oldProject = root.appendingPathComponent("Dev/skills4rabbits")
        let child = home.appendingPathComponent("literal $(touch INJECTED) `touch ALSO_INJECTED` ' folder")
        for directory in [home, oldProject, child] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        for (requested, expected) in [("~", home), ("", home), ("~/" + child.lastPathComponent, child), (child.path, child)] {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.currentDirectoryURL = oldProject
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            process.environment = environment
            process.arguments = ["-c", SSHCommand.remoteDirectoryCommand(requested) + " && pwd -P"]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, requested)
            let actual = URL(fileURLWithPath: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            XCTAssertEqual(actual.resolvingSymlinksInPath().path,
                           expected.resolvingSymlinksInPath().path, requested)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldProject.appendingPathComponent("INJECTED").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldProject.appendingPathComponent("ALSO_INJECTED").path))
    }
    #endif

    func testTerminalDirectoryRejectsNonFileAndMalformedReports() {
        XCTAssertEqual(SSHCommand.terminalDirectory("file://localhost/tmp/a%20b%23%25%3F"), "/tmp/a b#%?")
        for report in [nil, "", "/tmp", "https://host/tmp", "file:relative", "file:///tmp#fragment", "file:///tmp?query", "file:///tmp%00", "file://user:pass@host/tmp"] as [String?] {
            XCTAssertNil(SSHCommand.terminalDirectory(report), report ?? "nil")
        }
    }

    func testHostStartFolderSeparatesWSLWorkaroundFromNormalSSH() throws {
        var host = SSHHost(name: "Server", hostname: "server", username: "user")
        let restoredProject = "/Users/user/Dev/skills4rabbits"
        XCTAssertEqual(host.terminalStartPath(projectPath: restoredProject), "~")
        host.remotePath = "~/Projects/My Project"
        XCTAssertEqual(host.terminalStartPath(projectPath: restoredProject), "~/Projects/My Project")
        host.usesWSL = true
        XCTAssertEqual(host.terminalStartPath(projectPath: restoredProject), restoredProject)
        let restored = try JSONDecoder().decode(SSHHost.self, from: JSONEncoder().encode(host))
        XCTAssertTrue(restored.usesWSL)
        XCTAssertEqual(restored.terminalStartPath(projectPath: restoredProject), restoredProject)

        // Hosts saved before the checkbox existed still decode as ordinary SSH hosts.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        legacy.removeValue(forKey: "usesWSL")
        let migrated = try JSONDecoder().decode(SSHHost.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(migrated.usesWSL)
        XCTAssertEqual(migrated.remotePath, host.remotePath)
    }
}
