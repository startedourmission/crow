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
        do { try await test(); print("PASS Reverse SSH: execution, file edits, authentication, live revocation, cleanup, reconnect"); exit(0) }
        catch { print("FAIL", error.localizedDescription); exit(1) }
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
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let bundle = directories.first { $0.lastPathComponent.hasPrefix(".crow-client-") }!
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

    #if CROW_APP_TEST
    @MainActor static func appToggle(root: URL, host: SSHHost) async throws {
        let model = AppModel(vaultURL: root.appendingPathComponent("vault"))
        defer { model.shutdown() }
        model.hosts = [host]; model.sidebarPane = .hosts
        let session = ReverseSSHSession(bundleBasePath: root.path)
        model.reverseSSHConnections[host.id] = session
        for attempt in 0..<2 {
            // Both a new connection and a previously disconnected workspace must work from one toggle.
            model.setReverseSSH(true, for: host)
            try await wait("App toggle did not finish") { session.connectCommand != nil || !session.isEnabled }
            guard let command = session.connectCommand, let spec = model.current.systemSSH else {
                throw CommandError("App toggle failed: \(session.status)")
            }
            try require(model.sidebarPane == .hosts, "Enabling Reverse SSH moved away from the SSH list")
            let result = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-T"] + spec.multiplexArguments + [command + " 'printf APP_TOGGLE_OK'"])
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
