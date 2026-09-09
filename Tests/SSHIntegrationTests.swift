#if os(macOS)
import XCTest
import CrowCore
import SwiftTerm
@testable import Crow

final class SSHIntegrationTests: XCTestCase {
    @MainActor func testLoopbackSSHHostVerificationSFTPAndPTY() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-sshd-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ executable: String, _ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        let hostKey = root.appendingPathComponent("host-key").path
        let userKey = root.appendingPathComponent("user-key").path
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey])
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", userKey])
        let port = Int.random(in: 23000...45000)
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey)
        PidFile \(root.path)/sshd.pid
        AuthorizedKeysFile \(userKey).pub
        StrictModes no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        AllowUsers \(NSUserName())
        Subsystem sftp /usr/libexec/sftp-server
        LogLevel ERROR
        """
        let configURL = root.appendingPathComponent("sshd_config")
        try Data(config.utf8).write(to: configURL)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        server.arguments = ["-D", "-e", "-f", configURL.path]
        let logURL = root.appendingPathComponent("sshd.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        server.standardError = log; server.standardOutput = log
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() }; try? log.close() }
        try await Task.sleep(for: .milliseconds(300))
        guard server.isRunning else {
            XCTFail("Loopback sshd failed: \((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")"); return
        }
        var host = SSHHost(name: "Integration", hostname: "127.0.0.1", port: port, username: NSUserName(), remotePath: root.path)
        host.authentication = .ed25519
        let credential = HostCredential(privateKey: try String(contentsOfFile: userKey, encoding: .utf8))
        let account = "host-key:127.0.0.1:\(port)"
        let priorPin = try SecureStore.data(for: account)
        defer {
            if let priorPin { try? SecureStore.set(priorPin, for: account) }
            else { try? SecureStore.remove(account) }
        }
        try SecureStore.remove(account)
        let rejected = RemoteConnection()
        do {
            try await rejected.connect(host, credential: credential)
            XCTFail("An untrusted server must not connect")
        } catch let challenge as HostKeyChallenge {
            XCTAssertFalse(challenge.changed)
            XCTAssertTrue(challenge.fingerprint.hasPrefix("SHA256:"))
            try SecureStore.set(Data(challenge.key.utf8), for: account)
        }
        let connection = RemoteConnection()
        try await connection.connect(host, credential: credential)
        defer { Task { await connection.disconnect() } }
        let resolved = try await connection.realPath(root.path)
        XCTAssertEqual(URL(fileURLWithPath: resolved).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
        let path = root.appendingPathComponent("remote.txt").path
        try await connection.create(path, directory: false)
        let largeText = String(repeating: "한글-remote-data\n", count: 5000)
        try await connection.write(largeText, path: path, expected: "")
        let readBack = try await connection.read(path)
        XCTAssertEqual(readBack, largeText, "SFTP must read beyond a single packet")
        do {
            try await connection.write("wrong", path: path, expected: "stale")
            XCTFail("Remote conflicts must not overwrite the file")
        } catch FileFailure.conflict {}
        let listed = try await connection.list(root.path)
        XCTAssertTrue(listed.contains { $0.name == "remote.txt" })
        let renamed = root.appendingPathComponent("renamed.txt").path
        try await connection.rename(path, to: renamed)
        let trash = try await connection.trash(.init(name: "renamed.txt", path: renamed, isDirectory: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash))

        let session = TerminalSession(id: UUID(), workspace: Workspace(name: "SSH",
            kind: .remote(hostID: host.id, path: root.path), connection: .connected),
            directory: root.path, remote: connection, fontSize: 16)
        session.start(); defer { session.stop() }
        for _ in 0..<100 {
            if session.running { break }; try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(session.running, session.status)
        session.send(source: session.view, data: Array("printf '__SSH_%s__\\n' WORKS\n".utf8)[...])
        var found = false
        for _ in 0..<100 {
            let terminal = session.view.getTerminal()
            let screen = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined()
            if screen.contains("__SSH_WORKS__") { found = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(found, "The SSH PTY must execute commands and stream their output")
        session.stop(); await connection.disconnect()

        try SecureStore.set(Data("changed key".utf8), for: account)
        do {
            try await RemoteConnection().connect(host, credential: credential)
            XCTFail("Changed host keys must be rejected")
        } catch let challenge as HostKeyChallenge { XCTAssertTrue(challenge.changed) }
    }
}
#endif
