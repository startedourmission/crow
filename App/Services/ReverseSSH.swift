#if os(macOS)
import Foundation
import Observation
import Darwin
import CrowCore

/// A separate, temporary SSH identity for one server's access to this Mac.
/// The listener and accepted sockets belong to Crow, so Off revokes live sessions too.
@MainActor final class ReverseSSHServer {
    let directory: URL
    let username: String
    private(set) var port = 0
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var sessions: [UUID: (Process, FileHandle)] = [:]
    private var log: FileHandle?

    private init(directory: URL) {
        self.directory = directory
        username = NSUserName()
    }

    static func create() async throws -> ReverseSSHServer {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-client-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let server = ReverseSSHServer(directory: root)
        do {
            for name in ["host", "identity"] {
                _ = try await ReverseSSHCommand.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", root.appendingPathComponent(name).path])
            }
            try Task.checkCancellation()
            let key = try Data(contentsOf: root.appendingPathComponent("identity.pub"))
            try key.write(to: root.appendingPathComponent("authorized_keys"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("authorized_keys").path)
            let config = """
            HostKey "\(root.path)/host"
            AuthorizedKeysFile "\(root.path)/authorized_keys"
            PidFile "\(root.path)/sshd.pid"
            AllowUsers \(server.username)
            AuthenticationMethods publickey
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            UsePAM no
            UseDNS no
            PermitRootLogin no
            PermitUserEnvironment no
            AllowAgentForwarding no
            AllowTcpForwarding no
            AllowStreamLocalForwarding no
            X11Forwarding no
            PermitTunnel no
            StrictModes yes
            LoginGraceTime 15
            LogLevel ERROR
            Subsystem sftp /usr/libexec/sftp-server

            """
            try Data(config.utf8).write(to: root.appendingPathComponent("sshd_config"))
            _ = try await ReverseSSHCommand.run("/usr/sbin/sshd", ["-t", "-f", root.appendingPathComponent("sshd_config").path])
            try Task.checkCancellation()
            try server.listen()
            return server
        } catch { server.stop(); throw error }
    }

    var privateKey: String { get throws { try String(contentsOf: directory.appendingPathComponent("identity"), encoding: .utf8) } }
    var hostPublicKey: String { get throws { try String(contentsOf: directory.appendingPathComponent("host.pub"), encoding: .utf8) } }

    private func listen() throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        guard fcntl(listener, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(listener, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        port = Int(UInt16(bigEndian: address.sin_port))
        let logURL = directory.appendingPathComponent("sshd.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        log = try FileHandle(forWritingTo: logURL)
        let descriptor = listener
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        reader.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptConnections() } }
        reader.setCancelHandler { Darwin.close(descriptor) }
        source = reader; reader.resume()
    }

    private func acceptConnections() {
        guard listener >= 0 else { return }
        while true {
            let descriptor = Darwin.accept(listener, nil, nil)
            guard descriptor >= 0 else { return }
            // Bound resource use; no unauthenticated process can accumulate indefinitely.
            guard sessions.count < 16, fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(descriptor); continue }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let process = Process(), id = UUID()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            process.arguments = ["-i", "-e", "-f", directory.appendingPathComponent("sshd_config").path]
            process.standardInput = handle; process.standardOutput = handle; process.standardError = log
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in self?.finish(id) }
            }
            do { try process.run(); sessions[id] = (process, handle) }
            catch { try? handle.close() }
        }
    }

    private func finish(_ id: UUID) {
        guard let (_, handle) = sessions.removeValue(forKey: id) else { return }
        try? handle.close()
    }

    func stop() {
        if listener >= 0 {
            if let source { source.cancel() } else { Darwin.close(listener) }
            listener = -1; source = nil
        }
        for (process, handle) in sessions.values {
            // Shutdown acts on the socket shared with sshd's children, including PTYs.
            _ = Darwin.shutdown(handle.fileDescriptor, SHUT_RDWR)
            if process.isRunning { process.terminate() }
            try? handle.close()
        }
        sessions.removeAll()
        try? log?.close(); log = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Only bounded noninteractive commands. Credentials never enter process arguments or logs.
enum ReverseSSHCommand {
    /// Use shell stdin, not SSH exec quoting (Windows DefaultShell may launch WSL).
    static func remote(_ spec: SystemSSHSpec, command: String) async throws -> String {
        let input = "exec sh -c " + SystemSSHBridge.quote(command) + "\n"
        return try await run("/usr/bin/ssh", ["-T"] + spec.multiplexArguments, input: Data(input.utf8))
    }

    static func run(_ executable: String = "/usr/bin/ssh", _ arguments: [String], input: Data? = nil) async throws -> String {
        let work = Task.detached {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-reverse-command-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let outURL = root.appendingPathComponent("out"), errURL = root.appendingPathComponent("err")
            for url in [outURL, errURL] { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let output = try FileHandle(forWritingTo: outURL), errors = try FileHandle(forWritingTo: errURL)
            defer { try? output.close(); try? errors.close() }
            let inputURL = root.appendingPathComponent("input")
            try (input ?? Data()).write(to: inputURL)
            let stdin = try FileHandle(forReadingFrom: inputURL)
            defer { try? stdin.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardInput = stdin; process.standardOutput = output; process.standardError = errors
            try Task.checkCancellation()
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let deadline = Date().addingTimeInterval(12)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw CommandError("Reverse SSH timed out.") }
                for url in [outURL, errURL] {
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 1024 * 1024 else {
                        throw CommandError("Reverse SSH diagnostic output exceeded its limit.")
                    }
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            // isRunning is already false. An async task may resume on a different
            // thread; waitUntilExit would wait on that thread's unrelated run loop.
            guard process.terminationStatus == 0 else {
                let detail = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                throw CommandError(detail.isEmpty ? "Reverse SSH could not complete the connection." : String(detail.prefix(1500)))
            }
            return try String(contentsOf: outURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

/// Keep SSH authentication, keys and host verification in the POSIX environment.
/// Only the raw TCP stream crosses to Windows when its loopback owns the forward.
enum ReverseSSHConnector {
    enum Route { case direct, windowsLoopback }

    static func script(path: String, port: Int, username: String, connection: String, route: Route) -> String {
        let quote = SystemSSHBridge.quote
        let proxy: String
        switch route {
        case .direct: proxy = ""
        case .windowsLoopback:
            let encoded = Data(windowsRelay(port: port).utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }).base64EncodedString()
            proxy = " -o " + quote("ProxyCommand=powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand " + encoded)
        }
        return """
        #!/bin/sh
        # Prevent accidentally using another client's command in a shared server account.
        # This is not a security boundary against that account's owner.
        if [ -z "${SSH_CONNECTION-}" ] || [ "$SSH_CONNECTION" != \(quote(connection)) ]; then
          printf '%s\\n' 'Crow: this client command belongs to a different SSH connection. Run it in the Crow connection that enabled Reverse SSH.' >&2
          exit 1
        fi
        exec ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o UserKnownHostsFile=\(quote(path + "/known_hosts")) -i \(quote(path + "/identity"))\(proxy) -p \(port) -l \(quote(username)) 127.0.0.1 "$@"

        """
    }

    private static func windowsRelay(port: Int) -> String {
        // Binary .NET streams: PowerShell text pipelines would corrupt SSH packets.
        // Fixed loopback destination; no new listener, firewall rule or credential copy.
        """
        $crowTCP = [Net.Sockets.TcpClient]::new()
        try {
          if (-not $crowTCP.ConnectAsync('127.0.0.1', \(port)).Wait(4000)) { throw 'Windows loopback connection timed out' }
          $crowNetwork = $crowTCP.GetStream()
          $crowInput = [Console]::OpenStandardInput()
          $crowOutput = [Console]::OpenStandardOutput()
          $crowSend = $crowInput.CopyToAsync($crowNetwork)
          $crowReceive = $crowNetwork.CopyToAsync($crowOutput)
          $crowFirst = [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($crowSend, $crowReceive))
          if ($crowFirst -eq 0) {
            $crowSend.GetAwaiter().GetResult()
            $crowTCP.Client.Shutdown([Net.Sockets.SocketShutdown]::Send)
          }
          $crowReceive.GetAwaiter().GetResult()
          $crowOutput.Flush()
        } catch {
          [Console]::Error.WriteLine('Crow Windows loopback relay: ' + $_.Exception.Message)
          exit 1
        } finally { $crowTCP.Dispose() }
        """
    }
}

@MainActor @Observable final class ReverseSSHSession {
    private(set) var isEnabled = false
    private(set) var status = "Off"
    private(set) var connectCommand: String?
    private var operation: Operation?
    private var task: Task<Void, Never>?
    private let bundleBasePath: String?

    init(bundleBasePath: String? = nil) { self.bundleBasePath = bundleBasePath }

    func start(connection: @escaping @MainActor () async throws -> SystemSSHSpec) {
        guard !isEnabled else { return }
        isEnabled = true; status = "Connecting…"; connectCommand = nil
        let operation = Operation(), bundleBasePath = bundleBasePath
        self.operation = operation
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let spec = try await connection()
                try Task.checkCancellation()
                try await operation.open(spec, bundleBasePath: bundleBasePath) { [weak self] status in
                    if self?.operation === operation { self?.status = status }
                }
                try Task.checkCancellation()
                guard let self, self.operation === operation else { throw CancellationError() }
                self.connectCommand = operation.connectCommand
                self.status = "On · server can access this Mac"
                var checks = 0
                while true {
                    try await Task.sleep(for: .seconds(3))
                    _ = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-O", "check"] + spec.multiplexArguments)
                    checks += 1
                    if checks % 5 == 0 { try await operation.verify() }
                }
            } catch {
                if let self, self.operation === operation {
                    self.isEnabled = false; self.connectCommand = nil; self.operation = nil
                    self.status = error is CancellationError ? "Off" : error.localizedDescription
                }
            }
            await operation.close()
        }
    }

    func stop() {
        // Revoke access synchronously. Remote listener/file cleanup can follow asynchronously.
        operation?.server?.stop()
        operation = nil; task?.cancel(); task = nil
        isEnabled = false; connectCommand = nil; status = "Off"
    }

    /// For lifecycle callers/tests that must wait for removal of this session's bundle.
    func stopAndWait() async {
        let running = task
        stop()
        await running?.value
    }

    @MainActor private final class Operation {
        var server: ReverseSSHServer?
        var spec: SystemSSHSpec?
        var files: SystemSFTP?
        var remoteDirectory: String?
        var remotePort: Int?
        var connectCommand: String?

        func open(_ spec: SystemSSHSpec, bundleBasePath: String?, progress: (String) -> Void) async throws {
            self.spec = spec
            progress("Identifying this SSH connection…")
            let connection = try await ReverseSSHCommand.remote(spec, command: "printf '%s\\n' \"${SSH_CONNECTION-}\"")
            let endpoints = connection.split(separator: " ", omittingEmptySubsequences: false)
            guard endpoints.count == 4, !endpoints[0].isEmpty, !endpoints[2].isEmpty,
                  let clientPort = Int(endpoints[1]), (1...65535).contains(clientPort),
                  let serverPort = Int(endpoints[3]), (1...65535).contains(serverPort),
                  !connection.contains(where: { $0.isNewline }) else {
                throw CommandError("The server did not provide SSH_CONNECTION. Reverse SSH needs it to keep each client's command tied to its original SSH connection.")
            }
            try Task.checkCancellation()
            progress("Preparing this Mac…")
            server = try await ReverseSSHServer.create()
            try Task.checkCancellation()
            guard let server else { throw CancellationError() }
            // Don't cancel a forward allocation halfway through: retain its port for cleanup.
            let request = "127.0.0.1:0:127.0.0.1:\(server.port)"
            progress("Opening reverse connection…")
            let allocation = Task.detached {
                try await ReverseSSHCommand.run("/usr/bin/ssh", ["-O", "forward", "-R", request, "-o", "ExitOnForwardFailure=yes"] + spec.multiplexArguments)
            }
            let result = try await allocation.value
            guard let port = Int(result), (1...65535).contains(port) else { throw CommandError("SSH did not return the allocated reverse port.") }
            remotePort = port
            try Task.checkCancellation()
            progress("Preparing server access…")
            let files = try SystemSFTP(spec: spec); self.files = files
            let base = try await files.realPath(bundleBasePath ?? "~")
            try Task.checkCancellation()
            let path = (base as NSString).appendingPathComponent(".crow-client-" + UUID().uuidString)
            // Remember the path even if the transfer fails, so partial credentials are removed.
            remoteDirectory = path
            let command = ReverseSSHConnector.script(path: path, port: port, username: server.username, connection: connection, route: .direct)
            try await files.installReverseSSHBundle(at: path, identity: server.privateKey,
                knownHosts: "[127.0.0.1]:\(port) \(try server.hostPublicKey)", command: command)
            try Task.checkCancellation()
            connectCommand = SystemSSHBridge.quote(path + "/connect")
            progress("Verifying server → Mac access…")
            do { try await verify() }
            catch {
                try Task.checkCancellation()
                let directError = error.localizedDescription
                progress("Checking Windows loopback access…")
                // Probe the bridge capability instead of assuming a host name, WSL distro or network mode.
                do {
                    _ = try await ReverseSSHCommand.remote(spec, command: "command -v powershell.exe >/dev/null")
                    let bridged = ReverseSSHConnector.script(path: path, port: port, username: server.username, connection: connection, route: .windowsLoopback)
                    try await files.write(bridged, path: path + "/connect", expected: command, overwrite: false)
                    try Task.checkCancellation()
                    try await verify()
                } catch {
                    try Task.checkCancellation()
                    throw CommandError("Reverse SSH could not verify server → Mac access. The terminal was left open.\n\nDirect loopback: \(directError)\n\nWindows loopback bridge: \(error.localizedDescription)")
                }
            }
        }

        func verify() async throws {
            guard let spec, let connectCommand else { throw CommandError("Reverse SSH is not ready.") }
            let marker = "CROW_REVERSE_OK_" + UUID().uuidString
            let output = try await ReverseSSHCommand.remote(spec,
                command: "exec " + connectCommand + " -T " + SystemSSHBridge.quote("printf '%s\\n' '" + marker + "'"))
            guard output.components(separatedBy: .newlines).contains(marker) else {
                throw CommandError("The reverse connection did not return its authenticated readiness response.")
            }
        }

        func close() async {
            server?.stop()
            let spec = spec, port = remotePort, localPort = server?.port
            let files = files, path = remoteDirectory
            // Cleanup must outlive cancellation of the owning toggle's task.
            await Task.detached {
                if let spec, port != nil, let localPort {
                    // Mux cancellation matches the original request, not its allocated port.
                    _ = try? await ReverseSSHCommand.run("/usr/bin/ssh", ["-O", "cancel", "-R", "127.0.0.1:0:127.0.0.1:\(localPort)"] + spec.multiplexArguments)
                }
                if let files, let path { try? await files.removeReverseSSHBundle(at: path) }
                files?.close()
            }.value
            server = nil; self.files = nil
        }
    }
}
#endif
