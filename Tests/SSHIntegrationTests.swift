#if os(macOS)
import XCTest
import CrowCore
import SwiftTerm
@testable import Crow

final class SSHIntegrationTests: XCTestCase {
    func testAutomaticSSHDetectsExistingAgentKeysWithoutChangingThem() async throws {
        // Unix-domain socket paths are limited to 104 bytes on macOS.
        let root = URL(fileURLWithPath: "/tmp/crow-agent-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("agent").path
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", socket]
        agent.standardOutput = FileHandle.nullDevice; agent.standardError = FileHandle.nullDevice
        try agent.run()
        defer { if agent.isRunning { agent.terminate(); agent.waitUntilExit() } }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(agent.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket))
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = socket
        let empty = await SystemSSHBridge.hasAgentIdentities(environment: environment)
        XCTAssertFalse(empty)
        let keys = SSHKeyStore(account: "test-agent-keys-" + UUID().uuidString)
        defer { try? SecureStore.remove(keys.account) }
        let key = try keys.generate(name: "Agent fixture")
        _ = try await ReverseSSHCommand.run("/usr/bin/ssh-add", ["-"], input: Data(key.credential.privateKey.utf8), environment: environment)
        let populated = await SystemSSHBridge.hasAgentIdentities(environment: environment)
        XCTAssertTrue(populated)
        let identities = try await ReverseSSHCommand.run("/usr/bin/ssh-add", ["-L"], environment: environment)
        XCTAssertTrue(identities.contains(key.publicKey))
    }

    @MainActor private func verifyAutomaticSavedKeyConnection(host: SSHHost, credential: HostCredential, root: URL) async throws {
        let model = AppModel(vaultURL: root.appendingPathComponent("automatic-vault"))
        let key = try SSHKeyStore.shared.importKey(name: "Automatic loopback " + UUID().uuidString,
            privateKey: credential.privateKey, passphrase: credential.passphrase)
        var saved = host
        saved.commandArguments = ["-p", String(host.port), host.userAtHost]
        defer {
            model.shutdown()
            try? SecureStore.remove(saved.id.rawValue.uuidString)
            try? SSHKeyStore.shared.remove(key.id, hosts: [])
        }
        try model.storeHost(saved, credential: HostCredential(keyID: key.id))
        for attempt in 0..<2 {
            if attempt == 0 { try await model.connectCommand("ssh -p \(host.port) \(host.userAtHost)") }
            else { model.connect(try XCTUnwrap(model.hosts.first)) }
            for _ in 0..<200 where model.connectionState(for: saved) == .connecting {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(model.connectionState(for: saved), .connected, model.errorMessage ?? "")
            let state = try XCTUnwrap(model.states.first { $0.snapshot.workspace.hostID == saved.id })
            XCTAssertNil(state.systemSSH, "Automatic must use the Crow key rather than an empty system SSH identity list")
            let remote = try XCTUnwrap(state.remote)
            let output = try await remote.workspaceCommand("printf AUTO_KEY_OK")
            XCTAssertEqual(output, "AUTO_KEY_OK")
            XCTAssertEqual(try SecureStore.credential(saved).keyID, key.id)
            XCTAssertNil(model.hosts.first?.commandArguments)
            model.disconnect(saved)
        }
    }

    func testResolvedSSHConfigPreservesSystemKeysAndTransportFeatures() throws {
        let host = SSHHost(name: "Config", hostname: "example.invalid", username: "user")
        for option in ["proxycommand", "proxyjump", "localforward", "remoteforward", "dynamicforward",
                       "identityagent", "certificatefile", "controlpath", "remotecommand"] {
            XCTAssertTrue(SSHResolvedConfiguration(host: host, values: [option: ["configured"]]).requiresOpenSSH, option)
        }
        XCTAssertFalse(SSHResolvedConfiguration(host: host, values: ["proxycommand": ["none"], "forwardagent": ["no"]]).requiresOpenSSH)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-config-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("key"))
        let config = SSHResolvedConfiguration(host: host, values: ["identityfile": ["missing", "key"]])
        XCTAssertTrue(config.hasIdentityFile(directory: root.path), "Check all configured identities, not only the last one")
    }

    @MainActor private func verifyLaunchCommand(workspace: Workspace, directory: String, remote: RemoteConnection?, systemSSH: SystemSSHSpec? = nil) async throws {
        let session = TerminalSession(id: UUID(), workspace: workspace, directory: directory, remote: remote,
            fontSize: 16, useSystemSSH: systemSSH != nil)
        session.systemSSH = systemSSH
        session.launchCommand = "test -t 0 && printf '__LAUNCH_%s__' REMOTE; exec /bin/cat"
        session.start(); defer { session.stop() }
        for _ in 0..<100 {
            let terminal = session.view.getTerminal()
            let text = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined()
            if text.contains("__LAUNCH_REMOTE__") { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Remote launch command did not receive a PTY: \(session.status)")
    }

    @MainActor private func verifyTmuxRelay(remote: RemoteConnection, root: URL) async throws {
        let relay = TmuxSSHRelay(client: try XCTUnwrap(remote.client),
            command: "stty -echo; printf '__RELAY_READY__\\n'; read crow_line; printf '__INPUT_%s__\\n' \"$crow_line\"; stty size")
        let port = try await relay.start()
        defer { relay.stop() }
        let config = root.appendingPathComponent("relay.json")
        try JSONSerialization.data(withJSONObject: ["port": port, "token": relay.token]).write(to: config)
        let runtime = try XCTUnwrap(Bundle.main.url(forResource: "agent-history", withExtension: "py"))
        let request = String(decoding: try JSONSerialization.data(withJSONObject: ["action": "tmux-terminal", "config": config.path]), as: UTF8.self)
        let session = TerminalSession(id: UUID(), workspace: .init(name: "Relay", kind: .local, connection: .local),
                                      directory: root.path, remote: nil, fontSize: 14)
        session.launchCommand = TerminalCommand.environment + "python3 " + TerminalCommand.quote(runtime.path) + " " + TerminalCommand.quote(request)
        session.start()
        defer { session.stop() }
        func text() -> String {
            let terminal = session.view.getTerminal()
            return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true,
                skipNullCellsFollowingWide: true, characterProvider: terminal.getCharacter(for:)) }.joined(separator: "\n")
        }
        for _ in 0..<200 where !text().contains("__RELAY_READY__") { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(text().contains("__RELAY_READY__"), text())
        let local = try XCTUnwrap(session.view as? LocalProcessTerminalView)
        local.send(source: local, data: Array("한글 relay\n".utf8)[...])
        for _ in 0..<200 where !text().contains("__INPUT_한글 relay__") { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(text().contains("__INPUT_한글 relay__"), text())
        for _ in 0..<100 where session.running { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(session.running, "The pane relay must exit when its remote command exits")
        let output = try await remote.workspaceCommand("printf STILL_CONNECTED")
        XCTAssertEqual(output, "STILL_CONNECTED", "Closing the relay must preserve the authenticated SSH connection")
    }

    func testClosedSFTPPipeThrowsInsteadOfTerminatingApplication() throws {
        let pipe = Pipe()
        try SystemSFTP.protectWrites(to: pipe.fileHandleForWriting)
        XCTAssertEqual(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE), 1)
        try pipe.fileHandleForReading.close()
        defer { try? pipe.fileHandleForWriting.close() }
        XCTAssertThrowsError(try pipe.fileHandleForWriting.write(contentsOf: Data([1, 2, 3])))
    }
    @MainActor private func verifyNativeReverseSSH(host: SSHHost, credential: HostCredential, root: URL) async throws {
        let remote = RemoteConnection()
        try await remote.connect(host, credential: credential)
        let model = AppModel(vaultURL: root.appendingPathComponent("reverse-vault"))
        defer { model.shutdown() }
        let state = WorkspaceState(.init(workspace: Workspace(name: "Native SSH", kind: .remote(hostID: host.id, path: root.path),
            connection: .connected), rootPath: root.path))
        state.remote = remote
        model.states.append(state); model.hosts = [host]
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        model.reverseSSHPasteboard = board
        let session = ReverseSSHSession(bundleBasePath: root.path)
        model.reverseSSHConnections[host.id] = session
        defer { session.stop() }
        func ready(_ session: ReverseSSHSession) async throws -> String {
            for _ in 0..<400 where session.connectCommand == nil && session.isEnabled {
                try await Task.sleep(for: .milliseconds(50))
            }
            return try XCTUnwrap(session.connectCommand, "Native reverse startup: " + session.status)
        }
        XCTAssertNil(host.commandArguments, "Exercise a saved-key host without a terminal SSH command")
        model.setReverseSSH(true, for: host)
        let command = try await ready(session)
        XCTAssertNil(model.connectedSystemSSH(for: host.id), "Native reverse must not create or replace the terminal connection")
        XCTAssertTrue(state.remote === remote)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(board.string(forType: .string), command)
        let reply = try await remote.workspaceCommand(command + " -T 'printf NATIVE_REVERSE_OK'")
        XCTAssertEqual(reply, "NATIVE_REVERSE_OK")
        let piped = try await remote.workspaceCommand("printf '한글 👋' | " + command + " -T 'cat; printf EOF_OK'")
        XCTAssertEqual(piped, "한글 👋EOF_OK", "Reverse forwarding must keep output alive after stdin EOF")
        let other = ReverseSSHSession(bundleBasePath: root.path)
        defer { other.stop() }
        other.startOperation { try NativeReverseSSHOperation(remote: remote) }
        let second = try await ready(other)
        XCTAssertNotEqual(command, second)
        await other.stopAndWait()
        let survives = try await remote.workspaceCommand(command + " -T 'printf STILL_ALIVE'")
        XCTAssertEqual(survives, "STILL_ALIVE", "Stopping one native forward must preserve another on the same SSH connection")
        let bundle = String(command.dropFirst().dropLast())
        let script = try String(contentsOfFile: bundle, encoding: .utf8)
        let port = try XCTUnwrap(script.components(separatedBy: " -p ").last?.split(separator: " ").first)
        let marker = root.appendingPathComponent("reverse-live")
        var liveFinished = false
        let live = Task {
            _ = try? await remote.workspaceCommand(command + " -T " + SystemSSHBridge.quote("touch " + SystemSSHBridge.quote(marker.path) + "; sleep 20"))
            liveFinished = true
        }
        defer { live.cancel() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "A live native reverse session must start")
        let stopping = Task { await session.stopAndWait() }
        for _ in 0..<40 where !liveFinished { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(liveFinished, "Native Off must revoke already authenticated sessions immediately")
        await stopping.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: (bundle as NSString).deletingLastPathComponent), "Native Off must remove the temporary credentials")
        let closed = try await remote.workspaceCommand("if /usr/bin/nc -z -G 1 127.0.0.1 " + port + " 2>/dev/null; then printf OPEN; else printf CLOSED; fi")
        XCTAssertEqual(closed, "CLOSED", "Native Off must cancel the actual allocated remote listener")
        let normal = try await remote.workspaceCommand("printf NORMAL_SSH_ALIVE")
        XCTAssertEqual(normal, "NORMAL_SSH_ALIVE")
        // A real setup failure must reach the app's visible error, not only the tooltip.
        let storage = root.appendingPathComponent(".crow")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storage.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storage.path) }
        model.setReverseSSH(true, for: host)
        for _ in 0..<400 where session.isEnabled { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(session.isEnabled)
        XCTAssertTrue(model.errorMessage?.contains("permissions 700") == true, model.errorMessage ?? "No visible reverse failure")
        XCTAssertTrue(model.errorMessage?.contains(host.userAtHost) == true)
        XCTAssertNil(session.connectCommand)
        await session.stopAndWait()
        model.errorMessage = nil
        session.startOperation(onFailure: { _ in XCTFail("Turning Off during startup must not display an error") }) {
            try await Task.sleep(for: .seconds(5))
            return try NativeReverseSSHOperation(remote: remote)
        }
        await session.stopAndWait()
        XCTAssertFalse(session.isEnabled)
        XCTAssertNil(session.connectCommand)
    }

    @MainActor func testReverseSSHSetupTimeoutReportsFailureAndRevokes() async throws {
        final class StalledSetup: ReverseSSHOperation {
            var server: ReverseSSHServer? { nil }
            var connectCommand: String? { nil }
            var revoked = false
            var closed = false
            func open(bundleBasePath: String?, progress: (String) -> Void) async throws {
                progress("Preparing server access…")
                try await Task.sleep(for: .seconds(60))
            }
            func checkConnection() async throws {}
            func verify() async throws {}
            func revoke() { revoked = true }
            func close() async { closed = true }
        }
        let operation = StalledSetup()
        let session = ReverseSSHSession(setupTimeout: .milliseconds(50))
        var message: String?
        session.startOperation(onFailure: { message = $0 }) { operation }
        for _ in 0..<100 where message == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.isEnabled)
        XCTAssertTrue(message?.contains("Preparing server access") == true)
        XCTAssertTrue(message?.contains("timed out") == true)
        XCTAssertTrue(operation.revoked)
        await session.stopAndWait()
        XCTAssertTrue(operation.closed)
    }

    @MainActor func testLoopbackSSHHostVerificationSFTPAndPTY() async throws {
        try await verifyLoopbackSSH(relayOnly: false)
    }

    @MainActor func testTmuxAgentRelayUsesAuthenticatedConnection() async throws {
        try await verifyLoopbackSSH(relayOnly: true)
    }

    @MainActor private func verifyLoopbackSSH(relayOnly: Bool) async throws {
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
        let keys = SSHKeyStore(account: "test-loopback-keys-" + UUID().uuidString)
        defer { try? SecureStore.remove(keys.account) }
        let identity = try keys.generate(name: "Loopback")
        try Data((identity.publicKeyLine + "\n").utf8).write(to: URL(fileURLWithPath: userKey + ".pub"))
        XCTAssertTrue(FileManager.default.createFile(atPath: userKey,
            contents: Data(identity.credential.privateKey.utf8), attributes: [.posixPermissions: 0o600]))
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
        let credential = try HostCredential(keyID: identity.id).resolved(for: .ed25519, keys: keys)
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
        if relayOnly { try await verifyTmuxRelay(remote: connection, root: root); return }
        try await verifyAutomaticSavedKeyConnection(host: host, credential: credential, root: root)
        try await verifyNativeReverseSSH(host: host, credential: credential, root: root)
        let commandOutput = try await connection.workspaceCommand("printf '__COMMAND_OK__'")
        XCTAssertEqual(commandOutput, "__COMMAND_OK__")
        do {
            _ = try await connection.workspaceCommand("printf 'command error' >&2; exit 9")
            XCTFail("Remote management commands must propagate failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("command error")) }
        try await verifyLaunchCommand(workspace: Workspace(name: "SSH", kind: .remote(hostID: host.id, path: root.path), connection: .connected),
            directory: root.path, remote: connection)
        let resolved = try await connection.realPath(root.path)
        XCTAssertEqual(URL(fileURLWithPath: resolved).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
        let screenServer = Process()
        screenServer.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let fixtureScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/ScreenClient/vnc-fixture.py")
        let screenPortFile = root.appendingPathComponent("vnc-port")
        let screenEvents = root.appendingPathComponent("vnc-events").path
        screenServer.arguments = ["python3", fixtureScript.path, screenPortFile.path, screenEvents]
        try screenServer.run()
        defer { if screenServer.isRunning { screenServer.terminate(); screenServer.waitUntilExit() } }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: screenPortFile.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let screenPort = try XCTUnwrap(Int(String(contentsOf: screenPortFile, encoding: .utf8)))
        let screenState = WorkspaceState(.init(workspace: Workspace(name: "Screen fixture",
            kind: .remote(hostID: host.id, path: root.path), connection: .connected), rootPath: root.path))
        screenState.remote = connection
        try await ScreenIntegrationChecks.verify(in: screenState, port: screenPort, events: screenEvents)
        func verifyImage(_ path: String) throws {
            let url = URL(fileURLWithPath: path)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            XCTAssertEqual(try Data(contentsOf: url), InputToolsTests.png)
            let file = try FileManager.default.attributesOfItem(atPath: path)
            let directory = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        try verifyImage(await connection.uploadClipboardImage(InputToolsTests.png))
        try await ImagePreviewChecks.verifyRemote(connection, root: root)
        let repository = root.appendingPathComponent("repo with ' spaces")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try run("/usr/bin/git", ["init", "-q", "-b", "crow-fixture", repository.path])
        try Data("changed".utf8).write(to: repository.appendingPathComponent("changed file.txt"))
        try run("/usr/bin/git", ["-C", repository.path, "remote", "add", "origin", "https://fixture:never-display-this@github.com/owner/fixture.git"])
        try run("/usr/bin/git", ["-C", repository.path, "config", "user.name", "Crow Fixture"])
        try run("/usr/bin/git", ["-C", repository.path, "config", "user.email", "fixture@example.org"])
        let remoteGit = try await connection.gitStatus(path: repository.path)
        let localGit = try await GitRepository.read(path: repository.path)
        let discovered = try await connection.gitProjects(path: root.path)
        XCTAssertTrue(discovered.paths.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath() == repository.resolvingSymlinksInPath() })
        let selfDiscovered = try await connection.gitProjects(path: repository.path)
        XCTAssertEqual(selfDiscovered.paths.count, 1, "A repository vault must remain available as a selectable project")
        let deniedFolder = root.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: deniedFolder, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: deniedFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedFolder.path) }
        let partialProjects = try await connection.gitProjects(path: root.path)
        XCTAssertEqual(partialProjects.paths, discovered.paths)
        XCTAssertNotNil(partialProjects.warning)
        do {
            _ = try await connection.list(deniedFolder.path)
            XCTFail("An unreadable folder must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("SFTP 3"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(deniedFolder.path), error.localizedDescription)
        }
        XCTAssertEqual(URL(fileURLWithPath: remoteGit.root).resolvingSymlinksInPath(), repository.resolvingSymlinksInPath())
        XCTAssertEqual(remoteGit.status, localGit.status)
        XCTAssertEqual(remoteGit.remote, localGit.remote)
        XCTAssertEqual(remoteGit.remote?.displayAddress, "github.com/owner/fixture")
        XCTAssertEqual(remoteGit.authorName, "Crow Fixture")
        XCTAssertEqual(remoteGit.authorEmail, "fixture@example.org")
        XCTAssertTrue(remoteGit.status.branch.contains("crow-fixture"))
        XCTAssertTrue(remoteGit.status.changes.contains { $0.path == "changed file.txt" && $0.status == "??" })
        do {
            _ = try await connection.gitStatus(path: root.path)
            XCTFail("A non-repository must report a Git error")
        } catch { XCTAssertTrue(connection.isConnected, "A failed Git query must preserve the SSH connection") }
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
        let legacyTrash = root.appendingPathComponent(".crow-trash-" + UUID().uuidString + "-old.txt")
        try Data("old remote recovery".utf8).write(to: legacyTrash)
        let trash = try await connection.trash(.init(name: "renamed.txt", path: renamed, isDirectory: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash))
        XCTAssertTrue(trash.hasPrefix(root.appendingPathComponent(".crow/recovery").path + "/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyTrash.path))
        let recovered = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".crow/recovery"), includingPropertiesForKeys: nil)
        let migrated = try XCTUnwrap(recovered.first { $0.lastPathComponent.hasPrefix("legacy-") })
        XCTAssertEqual(try String(contentsOf: migrated, encoding: .utf8), "old remote recovery")

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
        var lastScreen = ""
        for _ in 0..<100 {
            let terminal = session.view.getTerminal()
            let screen = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined()
            lastScreen = screen
            if screen.contains("__SSH_WORKS__") { found = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(found, "The SSH PTY must execute commands and stream their output: \(session.status)\n\(lastScreen)")
        XCTAssertEqual(session.currentDirectory, root.path)
        session.stop(); await connection.disconnect()

        try SecureStore.set(Data("changed key".utf8), for: account)
        do {
            try await RemoteConnection().connect(host, credential: credential)
            XCTFail("Changed host keys must be rejected")
        } catch let challenge as HostKeyChallenge { XCTAssertTrue(challenge.changed) }

        // Type the ordinary OpenSSH command into a real zsh. Config/key/known-host
        // files belong to this fixture only, not the user's ~/.ssh directory.
        let knownHosts = root.appendingPathComponent("known_hosts")
        let publicKey = try String(contentsOfFile: hostKey + ".pub", encoding: .utf8)
        try Data("[127.0.0.1]:\(port) \(publicKey)".utf8).write(to: knownHosts)
        let clientConfig = root.appendingPathComponent("client_config")
        try Data("""
        Host crow-fixture
          HostName 127.0.0.1
          Port \(port)
          User \(NSUserName())
          IdentityFile \(userKey)
          IdentitiesOnly yes
          UserKnownHostsFile \(knownHosts.path)
          StrictHostKeyChecking yes
          BatchMode yes

        """.utf8).write(to: clientConfig)
        let model = AppModel(vaultURL: root.appendingPathComponent("vault"))
        defer { model.shutdown() }
        let localID = model.selectedWorkspaceID
        let localTerminal = model.terminal(model.current.snapshot.selectedTerminalID!, in: model.current)
        localTerminal.start()
        func type(_ text: String, in view: TerminalView) {
            view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }; try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("SSH workspace did not become ready: \(model.statusMessage)")
        }
        type("echo 'ssh not-a-connection@example.invalid'\n", in: localTerminal.view)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.workspaces.contains(where: \.isRemote), "Output text is never treated as a command")
        let command = "ssh -F \(SystemSSHBridge.quote(clientConfig.path)) crow-fixture"
        type(command + "\n", in: localTerminal.view)
        try await wait { model.states.contains { $0.snapshot.workspace.connection == .connected } }
        let imported = try XCTUnwrap(model.states.first { $0.snapshot.workspace.isRemote })
        XCTAssertEqual(model.selectedWorkspaceID, localID, "Import must not steal focus from the shell/password prompt")
        XCTAssertEqual(model.hosts.first?.hostname, "127.0.0.1")
        XCTAssertEqual(model.hosts.first?.port, port)
        XCTAssertFalse(model.hostEditorVisible)
        let native = try XCTUnwrap(imported.remote)
        let multiplexOutput = try await model.runTmux("printf '__MULTIPLEX_OK__'", in: imported)
        XCTAssertEqual(multiplexOutput, "__MULTIPLEX_OK__")
        try await verifyLaunchCommand(workspace: imported.snapshot.workspace, directory: root.path,
            remote: imported.remote, systemSSH: imported.systemSSH)

        try await ScreenIntegrationChecks.verify(in: imported, port: screenPort, events: screenEvents)
        try verifyImage(await native.uploadClipboardImage(InputToolsTests.png))
        try await ImagePreviewChecks.verifyRemote(native, root: root)
        XCTAssertNotNil(localTerminal.imagePasteContext?(), "A manually typed SSH command must associate image paste with its own terminal")
        let closedChannel = try SystemSFTP(spec: XCTUnwrap(imported.systemSSH))
        _ = try await closedChannel.list(root.path)
        closedChannel.close()
        for _ in 0..<100 where closedChannel.isConnected { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(closedChannel.isConnected)
        do {
            _ = try await closedChannel.list(root.path)
            XCTFail("A closed SFTP channel must report a connection error")
        } catch { /* Regression: this request previously terminated the app with signal 13. */ }
        XCTAssertTrue(localTerminal.running, "A failed file-list channel must not stop the user's SSH terminal")
        let nativePath = root.appendingPathComponent("native sftp.txt").path
        try await native.create(nativePath, directory: false)
        try await native.write(largeText, path: nativePath, expected: "")
        let nativeText = try await native.read(nativePath)
        XCTAssertEqual(nativeText, largeText)
        do {
            try await native.write("wrong", path: nativePath, expected: "stale")
            XCTFail("Native SFTP must reject stale writes")
        } catch FileFailure.conflict {}
        let nativeFiles = try await native.list(root.path)
        XCTAssertTrue(nativeFiles.contains { $0.name == "native sftp.txt" })
        let nativeRenamed = root.appendingPathComponent("renamed native.txt").path
        try await native.rename(nativePath, to: nativeRenamed)
        let nativeTrash = try await native.trash(.init(name: "renamed native.txt", path: nativeRenamed, isDirectory: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nativeTrash))
        XCTAssertTrue(nativeTrash.hasPrefix(root.appendingPathComponent(".crow/recovery").path + "/"))
        try await model.connectCommand(command)
        XCTAssertEqual(model.selectedWorkspaceID, imported.id)
        XCTAssertEqual(model.hosts.count, 1, "The one-line UI should reuse the imported host")
        let nativeTerminal = model.terminal(imported.snapshot.selectedTerminalID!, in: imported)
        nativeTerminal.start()
        type("printf '__MUX_%s__\\n' WORKS\n", in: nativeTerminal.view)
        try await wait {
            let terminal = nativeTerminal.view.getTerminal()
            return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined().contains("__MUX_WORKS__")
        }
        nativeTerminal.stop()

        let quickModel = AppModel(vaultURL: root.appendingPathComponent("quick-vault"))
        defer { quickModel.shutdown() }
        quickModel.sidebarPane = .workspaces
        try await quickModel.connectCommand(command)
        for _ in 0..<200 {
            if quickModel.current.snapshot.workspace.connection == .connected { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(quickModel.current.snapshot.workspace.connection, .connected, quickModel.statusMessage)
        XCTAssertTrue(quickModel.current.terminals.values.contains(where: \.running))
        XCTAssertFalse(quickModel.hostEditorVisible)
        XCTAssertNil(quickModel.credentialRequest, "Mac authentication stays inside OpenSSH, not an app password form")
        XCTAssertEqual(quickModel.sidebarPane, .workspaces, "Connecting must preserve the selected sidebar pane")
        XCTAssertEqual(quickModel.compactSurface, .terminal, "An explicit SSH connection opens the terminal")
        let initialTree = quickModel.current.explorer
        for _ in 0..<100 where initialTree.children[quickModel.current.snapshot.rootPath] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(initialTree.rootPath, quickModel.current.snapshot.rootPath)
        XCTAssertNotNil(initialTree.children[initialTree.rootPath], initialTree.errorMessage ?? "Remote root was not loaded")

        let project = root.appendingPathComponent("Project with spaces")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("# Remote note".utf8).write(to: project.appendingPathComponent("note.md"))
        let remoteID = quickModel.selectedWorkspaceID
        let sessions = quickModel.current.terminals
        let listing = try await quickModel.remoteDirectory(in: remoteID, at: root.path)
        let projectPath = (listing.path as NSString).appendingPathComponent(project.lastPathComponent)
        XCTAssertTrue(listing.folders.contains { $0.path == projectPath })
        // Browsing alone must not change the active project.
        XCTAssertNotEqual(quickModel.current.snapshot.rootPath, root.path)
        let original = quickModel.current
        let projectID = try await quickModel.openRemoteWorkspace(project.path, from: remoteID)
        XCTAssertNotEqual(projectID, remoteID)
        XCTAssertFalse(quickModel.current === original)
        XCTAssertNotEqual(original.snapshot.rootPath, projectPath)
        XCTAssertTrue(quickModel.current.remote === original.remote)
        let reopened = try await quickModel.openRemoteWorkspace(project.path + "/.", from: remoteID)
        XCTAssertEqual(reopened, projectID, "The same host and canonical folder must reuse its workspace")
        let tree = quickModel.current.explorer
        for _ in 0..<100 where !tree.rows.contains(where: { $0.entry.name == "note.md" }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(tree.rootPath, projectPath)
        XCTAssertTrue(tree.rows.contains { $0.entry.name == "note.md" })
        let note = try XCTUnwrap(tree.rows.first { $0.entry.name == "note.md" }?.entry)
        quickModel.openFile(note)
        try await wait { quickModel.selectedBuffer?.path == note.path }
        let noteID = try XCTUnwrap(quickModel.selectedBufferID)
        try Data("# Changed by remote agent".utf8).write(to: project.appendingPathComponent("note.md"), options: .atomic)
        await quickModel.refreshBufferFromSource(noteID, force: true)
        XCTAssertEqual(quickModel.selectedBuffer?.text, "# Changed by remote agent")
        quickModel.updateBufferText(noteID, "my unsaved remote draft")
        try Data("# Second remote change".utf8).write(to: project.appendingPathComponent("note.md"), options: .atomic)
        await quickModel.refreshBufferFromSource(noteID, force: true)
        XCTAssertEqual(quickModel.selectedBuffer?.text, "my unsaved remote draft")
        XCTAssertTrue(quickModel.externallyChangedBuffers.contains(noteID))
        await quickModel.refreshBufferFromSource(noteID, discardChanges: true)
        XCTAssertEqual(quickModel.selectedBuffer?.text, "# Second remote change")
        for (id, session) in sessions { XCTAssertTrue(original.terminals[id] === session); XCTAssertTrue(session.running) }
        quickModel.activateWorkspace(remoteID)
        XCTAssertTrue(quickModel.current === original)
        quickModel.activateWorkspace(projectID)
        XCTAssertEqual(quickModel.selectedBufferID, noteID)
        quickModel.pinWorkspace(projectID)
        let projectTerminalID = try XCTUnwrap(quickModel.current.snapshot.selectedTerminalID)
        let projectTerminal = quickModel.terminal(projectTerminalID, in: quickModel.current)
        projectTerminal.start()
        defer { projectTerminal.stop() }
        type("test \"$PWD\" -ef " + TerminalCommand.quote(project.path) + " && printf '__PROJECT_%s__\\n' CWD\n", in: projectTerminal.view)
        try await wait {
            let terminal = projectTerminal.view.getTerminal()
            return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined().contains("__PROJECT_CWD__")
        }
        XCTAssertTrue(quickModel.removeWorkspace(remoteID))
        XCTAssertTrue(quickModel.current.remote?.isConnected == true, "Removing one workspace must preserve the shared host connection")
        XCTAssertTrue(projectTerminal.running)
        let afterRemoval = try await quickModel.remoteDirectory(in: projectID, at: project.path)
        XCTAssertEqual(afterRemoval.path, projectPath)

        // SFTP can fail independently of the authenticated terminal; file browsing repairs that channel.
        let oldConnection = try XCTUnwrap(quickModel.current.remote)
        await oldConnection.disconnect()
        let repaired = try await quickModel.remoteDirectory(in: projectID, at: project.path)
        XCTAssertEqual(repaired.path, projectPath)
        XCTAssertFalse(quickModel.current.remote === oldConnection)
        XCTAssertTrue(quickModel.current.terminals.values.allSatisfy(\.running))
        quickModel.persist()
        let restored = AppModel(vaultURL: quickModel.vaultURL)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.current.snapshot.rootPath, projectPath)
        XCTAssertTrue(restored.current.snapshot.isPinned)
        XCTAssertEqual(restored.current.snapshot.selectedBufferID, noteID)
    }
}
#endif
