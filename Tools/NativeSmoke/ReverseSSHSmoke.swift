import Foundation
import Darwin
import CrowCore
#if CROW_APP_TEST
import AppKit
@testable import Crow
#endif

@main struct ReverseSSHSmoke {
    #if CROW_APP_TEST
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { await run() }
        app.run()
    }
    #else
    static func main() async {
        await run()
    }
    #endif

    static func run() async {
        do {
            if CommandLine.arguments.dropFirst().first == "--existing-connection" {
                try await existingConnection()
                print("PASS existing-connection Reverse SSH integration")
            } else {
                try await test()
                print("PASS Reverse SSH: execution, file edits, authentication, live revocation, cleanup, reconnect")
            }
            exit(0)
        }
        catch { print("FAIL", error.localizedDescription); exit(1) }
    }

    /// Opt-in integration check: a separate temporary reverse endpoint on an already
    /// authenticated connection. No app activation or SSH/server setting changes.
    @MainActor static func existingConnection() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, let port = Int(args[5]), (1...65535).contains(port) else {
            throw CommandError("Usage: --existing-connection control-socket username hostname port")
        }
        let spec = SystemSSHSpec(host: SSHHost(name: "Integration test", hostname: args[4], port: port, username: args[3]),
            socket: args[2], arguments: [], directory: FileManager.default.temporaryDirectory.path)
        _ = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-O", "check"] + spec.multiplexArguments)
        let session = ReverseSSHSession()
        defer { session.stop() }
        session.start { spec }
        try await wait("Live reverse endpoint did not become ready") { session.connectCommand != nil || !session.isEnabled }
        guard let command = session.connectCommand else {
            let message = session.status
            await session.stopAndWait()
            throw CommandError(message)
        }
        do {
            let result = try await ReverseSSHCommand.remote(spec, command: command + " -T 'printf CROW_LIVE_OK'")
            try require(result.contains("CROW_LIVE_OK"), "Authenticated reverse command failed")
            print("PASS existing connection: authenticated server → Mac execution")
            // Exercise binary stdin/EOF as well as output, without writing user files.
            let payload = "한글 👋 quoted ' text"
            let echo = try await ReverseSSHCommand.remote(spec,
                command: "printf '%s' " + SystemSSHBridge.quote(payload) + " | " + command + " -T cat")
            try require(echo.contains(payload), "Reverse bridge corrupted input or failed to forward EOF")
            print("PASS existing connection: UTF-8 stdin/output and EOF")
            await session.stopAndWait()
            var cleaned = false
            for _ in 0..<60 {
                if (try? await ReverseSSHCommand.remote(spec, command: "test ! -e " + command)) != nil { cleaned = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(cleaned, "Temporary reverse credentials were not removed")
            _ = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-O", "check"] + spec.multiplexArguments)
            print("PASS existing connection: temporary endpoint removed, original SSH master preserved")
        } catch {
            await session.stopAndWait()
            // Give owned asynchronous cleanup time to revoke this test's temporary bundle.
            for _ in 0..<60 {
                if (try? await ReverseSSHCommand.remote(spec, command: "test ! -e " + command)) != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            throw error
        }
    }

    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CommandError(message) }
    }

    @MainActor static func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CommandError(message)
    }

    @MainActor static func test() async throws {
        func isListening(_ port: Int) -> Bool {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { Darwin.close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = UInt16(port).bigEndian
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-smoke-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["host", "user"] {
            _ = try await ReverseSSHCommand.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", root.appendingPathComponent(name).path])
        }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let port: Int = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.bind(descriptor, $0, size); _ = getsockname(descriptor, $0, &size)
            }
            return Int(UInt16(bigEndian: pointer.pointee.sin_port))
        }
        Darwin.close(descriptor)
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(root.path)/host
        PidFile \(root.path)/pid
        AuthorizedKeysFile \(root.path)/user.pub
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        AllowUsers \(NSUserName())
        AllowTcpForwarding yes
        MaxSessions 1
        GatewayPorts no
        Subsystem sftp /usr/libexec/sftp-server
        LogLevel ERROR

        """
        let configURL = root.appendingPathComponent("sshd_config")
        try Data(config.utf8).write(to: configURL)
        func spawn(_ arguments: [String], executable: String = "/usr/bin/ssh", output: FileHandle? = nil) throws -> Process {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output ?? FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice; try process.run(); return process
        }
        let server = try spawn(["-D", "-e", "-f", configURL.path], executable: "/usr/sbin/sshd")
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        try await Task.sleep(for: .milliseconds(250))
        try require(server.isRunning, "Fixture SSH server failed")
        let publicKey = try String(contentsOf: root.appendingPathComponent("host.pub"), encoding: .utf8)
        let knownHosts = root.appendingPathComponent("known_hosts")
        try Data("[127.0.0.1]:\(port) \(publicKey)".utf8).write(to: knownHosts)
        let socket = "/tmp/crw-test-" + String(UUID().uuidString.prefix(12))
        let host = SSHHost(name: "Test", hostname: "127.0.0.1", port: port, username: NSUserName())
        let master = try spawn(["-F", "/dev/null", "-N", "-M", "-S", socket,
            "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHosts.path)", "-i", root.appendingPathComponent("user").path,
            "-p", String(port), host.userAtHost])
        defer { if master.isRunning { master.terminate(); master.waitUntilExit() }; try? FileManager.default.removeItem(atPath: socket) }
        try await wait("Master did not connect") { FileManager.default.fileExists(atPath: socket) }
        let spec = SystemSSHSpec(host: host, socket: socket, arguments: [], directory: root.path)
        let session = ReverseSSHSession(bundleBasePath: root.path)
        defer { session.stop() }
        session.start { spec }
        do { try await wait("Reverse SSH did not start") { session.connectCommand != nil || !session.isEnabled } }
        catch { throw CommandError("Reverse SSH did not start: \(session.status)") }
        guard let command = session.connectCommand else { throw CommandError(session.status) }
        let result = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-T"] + spec.multiplexArguments + [command + " 'printf CROW_CLIENT_OK'"])
        try require(result == "CROW_CLIENT_OK", "Server could not execute on client: \(result)")
        print("PASS server → reverse tunnel → Mac command execution")
        let edited = root.appendingPathComponent("edited-by-server.txt")
        let edit = "printf client-edit > " + SystemSSHBridge.quote(edited.path)
        _ = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-T"] + spec.multiplexArguments + [command + " " + SystemSSHBridge.quote(edit)])
        let editedText = try String(contentsOf: edited, encoding: .utf8)
        try require(editedText == "client-edit", "Server could not edit a client file")
        let bundles = root.appendingPathComponent(".crow/reverse-ssh")
        let directories = try FileManager.default.contentsOfDirectory(at: bundles, includingPropertiesForKeys: nil)
        let bundle = directories.first { UUID(uuidString: $0.lastPathComponent) != nil }!
        let wrapper = try String(contentsOf: bundle.appendingPathComponent("connect"), encoding: .utf8)
        let parts = wrapper.components(separatedBy: " -p ")
        let reversePort = String(parts[1].split(separator: " ")[0])
        for name in ["identity", "known_hosts"] {
            let mode = try FileManager.default.attributesOfItem(atPath: bundle.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber
            try require(mode?.intValue == 0o600, "Client credentials are not private")
        }
        do {
            _ = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(bundle.path)/known_hosts", "-i", root.appendingPathComponent("user").path,
                "-p", reversePort, host.userAtHost, "true"])
            throw CommandError("An unrelated key gained access to the Mac")
        } catch let error as CommandError {
            try require(error.message.contains("Permission denied"), "Unexpected authentication error: \(error.message)")
        }
        // A second transport to the same account represents another client device.
        // Both reverse endpoints must remain usable, but only from their own transport.
        let otherSocket = "/tmp/crw-test-" + String(UUID().uuidString.prefix(12))
        let otherMaster = try spawn(["-F", "/dev/null", "-N", "-M", "-S", otherSocket,
            "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHosts.path)", "-i", root.appendingPathComponent("user").path,
            "-p", String(port), host.userAtHost])
        defer {
            if otherMaster.isRunning { otherMaster.terminate(); otherMaster.waitUntilExit() }
            try? FileManager.default.removeItem(atPath: otherSocket)
        }
        try await wait("Second client did not connect") { FileManager.default.fileExists(atPath: otherSocket) }
        let otherSpec = SystemSSHSpec(host: host, socket: otherSocket, arguments: [], directory: root.path)
        let otherSession = ReverseSSHSession(bundleBasePath: root.path)
        defer { otherSession.stop() }
        otherSession.start { otherSpec }
        try await wait("Second reverse endpoint did not start") { otherSession.connectCommand != nil || !otherSession.isEnabled }
        guard let otherCommand = otherSession.connectCommand else { throw CommandError(otherSession.status) }
        async let firstOutput = ReverseSSHCommand.remote(spec, command: command + " -T 'printf FIRST_CLIENT'")
        async let secondOutput = ReverseSSHCommand.remote(otherSpec, command: otherCommand + " -T 'printf SECOND_CLIENT'")
        let outputs = try await (firstOutput, secondOutput)
        try require(outputs.0 == "FIRST_CLIENT" && outputs.1 == "SECOND_CLIENT", "Simultaneous clients could not use their own reverse endpoints")
        // Codex subprocesses and tmux may retain another SSH transport's environment.
        // The explicit command still selects its own private identity and pinned Mac.
        for (source, target) in [(spec, otherCommand), (otherSpec, command)] {
            let result = try await ReverseSSHCommand.remote(source, command: target + " -T 'printf AGENT_OK'")
            try require(result == "AGENT_OK", "An agent on another SSH transport could not use the explicit client command")
        }
        for prefix in ["unset SSH_CONNECTION; ", "SSH_CONNECTION='stale tmux connection'; export SSH_CONNECTION; "] {
            let result = try await ReverseSSHCommand.remote(spec,
                command: prefix + command + " -T 'printf DETACHED_AGENT_OK'")
            try require(result == "DETACHED_AGENT_OK", "A detached or stale agent environment blocked the explicit client command")
        }
        try require(session.isEnabled && otherSession.isEnabled, "Agent execution disabled an endpoint")
        await otherSession.stopAndWait()
        let survivor = try await ReverseSSHCommand.remote(spec, command: command + " -T 'printf FIRST_STILL_ALIVE'")
        try require(survivor == "FIRST_STILL_ALIVE", "Stopping another client's endpoint interrupted the first")
        print("PASS simultaneous clients, agent execution with absent/stale SSH_CONNECTION, independent Off")
        let outputURL = root.appendingPathComponent("live-output")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let live = try spawn(["-T"] + spec.multiplexArguments + [command + " 'printf CLIENT_STARTED; sleep 20'"], output: output)
        defer { if live.isRunning { live.terminate(); live.waitUntilExit() } }
        try await wait("Live client session did not start") {
            (try? String(contentsOf: outputURL, encoding: .utf8))?.contains("CLIENT_STARTED") == true
        }
        let stoppedAt = Date()
        session.stop()
        try require(!session.isEnabled && session.connectCommand == nil, "Off did not update immediately")
        try await wait("Off left an authenticated client connection open") { !live.isRunning }
        try require(Date().timeIntervalSince(stoppedAt) < 2, "Revoking a live connection took more than two seconds")
        try await wait("Off left client credentials on the server") { !FileManager.default.fileExists(atPath: bundle.path) }
        try await wait("Off left the allocated reverse listener open") { !isListening(Int(reversePort)!) }
        let normal = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-T"] + spec.multiplexArguments + ["printf NORMAL_SSH_ALIVE"])
        try require(normal == "NORMAL_SSH_ALIVE", "Off interrupted ordinary SSH")
        print("PASS Off closes authenticated sessions, removes credentials, preserves normal SSH")
        session.start { spec }
        session.stop()
        try await Task.sleep(for: .milliseconds(400))
        try require(!session.isEnabled && session.connectCommand == nil, "Cancelled startup resurrected access")
        session.start { spec }
        do { try await wait("Restart did not finish") { session.connectCommand != nil || !session.isEnabled } }
        catch { throw CommandError("Restart did not finish: \(session.status)") }
        try require(session.connectCommand != nil && session.connectCommand != command, "Restart reused revoked credentials")
        let restartedBundle = try FileManager.default.contentsOfDirectory(at: bundles, includingPropertiesForKeys: nil)
            .first { UUID(uuidString: $0.lastPathComponent) != nil }!
        try Data("#!/bin/sh\nexit 42\n".utf8).write(to: restartedBundle.appendingPathComponent("connect"))
        try await wait("Broken reverse route stayed On while the master remained alive") { !session.isEnabled }
        try require(session.connectCommand == nil, "A broken reverse route still advertised a command")
        await session.stopAndWait()
        _ = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-O", "check"] + spec.multiplexArguments)
        print("PASS reverse-path health check detects failure independently of the SSH master")
        session.start { spec }
        try await wait("Restart after health failure did not finish") { session.connectCommand != nil || !session.isEnabled }
        try require(session.connectCommand != nil, "Health failure prevented a fresh toggle")
        try await passwordAccess(spec: spec, root: root)
        #if CROW_APP_TEST
        var savedHost = host
        savedHost.commandArguments = ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(knownHosts.path)",
            "-i", root.appendingPathComponent("user").path, "-p", String(port), host.userAtHost]
        try await appToggle(root: root, host: savedHost)
        #endif
        master.terminate(); master.waitUntilExit()
        try await wait("Lost SSH master left Reverse SSH enabled") { !session.isEnabled }
    }

    @MainActor static func passwordAccess(spec: SystemSSHSpec, root: URL) async throws {
        let password = "Crow test ' $() \u{D55C}\u{AE00} " + UUID().uuidString
        let session = ReverseSSHSession(bundleBasePath: root.path)
        defer { session.stop() }
        session.start(password: password) { spec }
        try await wait("Password-protected reverse endpoint did not start") { session.connectCommand != nil || !session.isEnabled }
        guard let command = session.connectCommand else { throw CommandError(session.status) }
        let helper = root.appendingPathComponent("password-askpass")
        let secret = root.appendingPathComponent("test-password")
        let prompts = root.appendingPathComponent("password-prompts")
        let quote = SystemSSHBridge.quote
        let helperText = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " + quote(prompts.path) + "\nexec /bin/cat " + quote(secret.path) + "\n"
        try Data(helperText.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let prefix = "env SSH_ASKPASS_REQUIRE=force DISPLAY=crow-test SSH_ASKPASS=" + quote(helper.path) + " "
        for attempt in ["", "wrong-password"] {
            try Data(attempt.utf8).write(to: secret)
            var denied = false
            do { _ = try await ReverseSSHCommand.remote(spec, command: prefix + command + " -T 'printf UNEXPECTED_ACCESS'") }
            catch { denied = true }
            try require(denied, "A missing or wrong password gained reverse access")
        }
        try Data(password.utf8).write(to: secret)
        try Data().write(to: prompts)
        for _ in 0..<2 {
            let result = try await ReverseSSHCommand.remote(spec, command: prefix + command + " -T 'printf PASSWORD_OK'")
            try require(result == "PASSWORD_OK", "The correct password could not execute on the Mac")
        }
        let promptLines = try String(contentsOf: prompts, encoding: .utf8).split(separator: "\n")
        try require(promptLines.count >= 2, "New connections did not ask for the password again")
        let script = try await ReverseSSHCommand.remote(spec, command: "cat " + command)
        try require(!script.contains(password), "The password leaked into the remote connector")
        // Even direct use of the health key is forced to its marker, regardless of the requested command.
        guard let probeLine = script.components(separatedBy: .newlines).first(where: { $0.contains("/probe'") }) else {
            throw CommandError("Missing restricted health probe")
        }
        let forbidden = root.appendingPathComponent("probe-must-not-write")
        let result = try await ReverseSSHCommand.remote(spec, command: probeLine + " " + quote("touch " + quote(forbidden.path)))
        try require(result == "CROW_REVERSE_OK" && !FileManager.default.fileExists(atPath: forbidden.path), "Health key allowed an arbitrary command")
        // A regular authenticated session must also be revoked while it is running.
        let started = root.appendingPathComponent("password-live-started")
        let live = Task { try await ReverseSSHCommand.remote(spec, command: prefix + command + " -T " + quote("touch " + quote(started.path) + "; sleep 30")) }
        try await wait("Password-authenticated live command did not start") { FileManager.default.fileExists(atPath: started.path) }
        await session.stopAndWait()
        _ = await live.result
        let removed = try? await ReverseSSHCommand.remote(spec, command: "test ! -e " + command)
        try require(removed != nil, "Protected connector was not removed")
        print("PASS reverse password: missing/wrong rejected, correct accepted, repeated prompt, restricted probe, live revocation and cleanup")
    }

    #if CROW_APP_TEST
    @MainActor static func appToggle(root: URL, host: SSHHost) async throws {
        let model = AppModel(vaultURL: root.appendingPathComponent("vault"))
        defer { model.shutdown() }
        model.hosts = [host]; model.sidebarPane = .workspaces
        let account = "reverse-password-smoke-" + UUID().uuidString
        defer { try? SecureStore.remove(account) }
        let access = ReverseSSHAccessSettings(account: account)
        try access.save(String(contentsOf: root.appendingPathComponent("test-password"), encoding: .utf8))
        model.reverseSSHAccess = access
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        model.reverseSSHPasteboard = pasteboard
        let prefix = "env SSH_ASKPASS_REQUIRE=force DISPLAY=crow-test SSH_ASKPASS=" + SystemSSHBridge.quote(root.appendingPathComponent("password-askpass").path) + " "
        let session = ReverseSSHSession(bundleBasePath: root.path)
        model.reverseSSHConnections[host.id] = session
        let commandLine = "ssh " + host.commandArguments!.map(SystemSSHBridge.quote).joined(separator: " ")
        try await model.connectCommand(commandLine)
        try require(model.sidebarPane == .workspaces, "Starting SSH switched to the file explorer")
        try await wait("Ordinary SSH did not connect") { model.current.snapshot.workspace.connection == .connected }
        try require(model.sidebarPane == .workspaces, "SSH completion switched to the file explorer")
        try await model.connectCommand(commandLine)
        try require(model.sidebarPane == .workspaces, "Selecting an already connected SSH host switched the sidebar")
        model.disconnectCurrent()
        try await Task.sleep(for: .milliseconds(300))
        print("PASS SSH sidebar selection: start, connection completion, already-connected host")
        for attempt in 0..<2 {
            // Both a new connection and a previously disconnected workspace must work from one toggle.
            let selectedPane: SidebarPane = attempt == 0 ? .workspaces : .files
            model.sidebarPane = selectedPane
            model.setReverseSSH(true, for: host)
            try await wait("App toggle did not finish") { session.connectCommand != nil || !session.isEnabled }
            guard let command = session.connectCommand, let spec = model.current.systemSSH else {
                throw CommandError("App toggle failed: \(session.status)")
            }
            try require(model.sidebarPane == selectedPane, "Enabling Reverse SSH changed the selected sidebar pane")
            try require(pasteboard.string(forType: .string) == command, "Enabling Reverse SSH did not automatically copy its command")
            let result = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-T"] + spec.multiplexArguments + [prefix + command + " 'printf APP_TOGGLE_OK'"])
            try require(result == "APP_TOGGLE_OK", "App toggle did not enable client execution")
            model.setReverseSSH(false, for: host)
            try require(!session.isEnabled, "App toggle Off did not revoke access")
            _ = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-O", "check"] + spec.multiplexArguments)
            model.disconnectCurrent()
            try await Task.sleep(for: .milliseconds(300))
            print("PASS SSH list toggle: \(attempt == 0 ? "connect" : "reconnect"), client execution, immediate Off")
        }
    }
    #endif
}
