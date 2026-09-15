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
            try await ReverseSSHCommand.generateKey(at: root.appendingPathComponent("host"))
            try await ReverseSSHCommand.generateKey(at: root.appendingPathComponent("identity"))
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
    static func generateKey(at url: URL) async throws {
        _ = try await run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-f", url.path, "-N", ""])
    }

    /// Pass the remote shell script through stdin to preserve command quoting.
    static func remote(_ spec: SystemSSHSpec, command: String) async throws -> String {
        let input = "exec sh -c " + SystemSSHBridge.quote(command) + "\n"
        return try await run("/usr/bin/ssh", ["-T"] + spec.multiplexArguments, input: Data(input.utf8))
    }

    static func run(_ executable: String = "/usr/bin/ssh", _ arguments: [String], input: Data? = nil, operation: String = "Reverse SSH", environment: [String: String]? = nil) async throws -> String {
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
            // Assigning nil clears the child environment on macOS, including HOME
            // and PATH needed to locate user-installed CLIs.
            process.environment = environment ?? ProcessInfo.processInfo.environment
            process.standardInput = stdin; process.standardOutput = output; process.standardError = errors
            try Task.checkCancellation()
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let deadline = Date().addingTimeInterval(12)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw CommandError("\(operation) timed out.") }
                for url in [outURL, errURL] {
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 1024 * 1024 else {
                        throw CommandError("\(operation) diagnostic output exceeded its limit.")
                    }
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            // isRunning is already false. An async task may resume on a different
            // thread; waitUntilExit would wait on that thread's unrelated run loop.
            guard process.terminationStatus == 0 else {
                let detail = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                throw CommandError(detail.isEmpty ? "\(operation) command failed." : String(detail.prefix(1500)))
            }
            return try String(contentsOf: outURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

/// Reverse SSH is available between Macs only.
enum ReverseSSHConnector {
    static let supportedHostCommand = """
    if [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/sw_vers ]; then
        printf '%s\\n' CROW_REVERSE_MACOS
    else
        printf '%s\\n' CROW_REVERSE_UNSUPPORTED
    fi
    """

    static func supportsHost(_ output: String) -> Bool {
        let markers = output.components(separatedBy: .newlines).filter { $0.hasPrefix("CROW_REVERSE_") }
        return markers == ["CROW_REVERSE_MACOS"]
    }

    static func script(path: String, port: Int, username: String) -> String {
        let quote = SystemSSHBridge.quote
        let options = "ssh -F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -o AddKeysToAgent=no -o PreferredAuthentications=publickey -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o UserKnownHostsFile=" + quote(path + "/known_hosts")
        let destination = " -p \(port) -l " + quote(username) + " 127.0.0.1"
        return """
        #!/bin/sh
        [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/sw_vers ] || {
            printf '%s\\n' 'Reverse SSH is supported only between macOS devices.' >&2
            exit 1
        }
        # This bundle's private identity and pinned host key select exactly one Mac.
        exec \(options) -o BatchMode=yes -i \(quote(path + "/identity"))\(destination) "$@"

        """
    }
}

@MainActor protocol ReverseSSHOperation: AnyObject {
    var server: ReverseSSHServer? { get }
    var connectCommand: String? { get }
    func open(bundleBasePath: String?, progress: (String) -> Void) async throws
    func checkConnection() async throws
    func verify() async throws
    func revoke()
    func close() async
}

extension ReverseSSHOperation {
    func revoke() { server?.stop() }
}

@MainActor @Observable final class ReverseSSHSession {
    private(set) var isEnabled = false
    private(set) var status = "Off"
    private(set) var connectCommand: String?
    private var operation: (any ReverseSSHOperation)?
    private var task: Task<Void, Never>?
    private let bundleBasePath: String?
    private let setupTimeout: Duration

    init(bundleBasePath: String? = nil, setupTimeout: Duration = .seconds(45)) {
        self.bundleBasePath = bundleBasePath
        self.setupTimeout = setupTimeout
    }

    func start(onReady: (@MainActor (String) -> Void)? = nil,
               onFailure: (@MainActor (String) -> Void)? = nil,
               connection: @escaping @MainActor () async throws -> SystemSSHSpec) {
        startOperation(onReady: onReady, onFailure: onFailure) {
            Operation(spec: try await connection())
        }
    }

    func startOperation(onReady: (@MainActor (String) -> Void)? = nil,
                        onFailure: (@MainActor (String) -> Void)? = nil,
                        makeOperation: @escaping @MainActor () async throws -> any ReverseSSHOperation) {
        guard !isEnabled else { return }
        isEnabled = true; status = "Connecting…"; connectCommand = nil
        let generation = UUID()
        self.generation = generation
        let bundleBasePath = bundleBasePath, setupTimeout = setupTimeout
        task = Task { [weak self] in
            var running: (any ReverseSSHOperation)?
            var deadline: Task<Void, Never>?
            defer { deadline?.cancel() }
            do {
                try Task.checkCancellation()
                let operation = try await makeOperation()
                running = operation
                try Task.checkCancellation()
                guard let self, self.generation == generation else { throw CancellationError() }
                self.operation = operation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: setupTimeout) } catch { return }
                    guard let self, self.generation == generation, self.connectCommand == nil else { return }
                    let stage = self.status
                    self.operation?.revoke()
                    self.generation = UUID(); self.task?.cancel()
                    self.operation = nil; self.isEnabled = false
                    self.status = stage + "\nReverse SSH setup timed out. The terminal connection was left open."
                    onFailure?(self.status)
                }
                try await operation.open(bundleBasePath: bundleBasePath) { [weak self] status in
                    if self?.generation == generation { self?.status = status }
                }
                try Task.checkCancellation()
                guard self.generation == generation else { throw CancellationError() }
                deadline?.cancel()
                self.connectCommand = operation.connectCommand
                self.status = "On · server account can access this Mac"
                if let command = self.connectCommand { onReady?(command) }
                var checks = 0
                while true {
                    try await Task.sleep(for: .seconds(3))
                    try await operation.checkConnection()
                    checks += 1
                    if checks % 5 == 0 { try await operation.verify() }
                }
            } catch {
                if let self, self.generation == generation {
                    let stage = self.status
                    self.isEnabled = false; self.connectCommand = nil; self.operation = nil
                    if error is CancellationError { self.status = "Off" }
                    else {
                        self.status = stage + "\n" + error.localizedDescription
                        onFailure?(self.status)
                    }
                }
            }
            await running?.close()
        }
    }
    private var generation = UUID()

    func stop() {
        // Revoke access synchronously. Remote listener/file cleanup can follow asynchronously.
        operation?.revoke()
        generation = UUID()
        operation = nil; task?.cancel(); task = nil
        isEnabled = false; connectCommand = nil; status = "Off"
    }

    /// For lifecycle callers/tests that must wait for removal of this session's bundle.
    func stopAndWait() async {
        let running = task
        stop()
        await running?.value
    }

    @MainActor private final class Operation: ReverseSSHOperation {
        var server: ReverseSSHServer?
        var spec: SystemSSHSpec?
        var files: SystemSFTP?
        var remoteDirectory: String?
        var remotePort: Int?
        var connectCommand: String?

        init(spec: SystemSSHSpec) { self.spec = spec }

        func checkConnection() async throws {
            guard let spec else { throw FileFailure.disconnected }
            _ = try await ReverseSSHCommand.run("/usr/bin/ssh", ["-O", "check"] + spec.multiplexArguments)
        }

        func open(bundleBasePath: String?, progress: (String) -> Void) async throws {
            guard let spec else { throw FileFailure.disconnected }
            try Task.checkCancellation()
            progress("Checking macOS support…")
            let platform = try await ReverseSSHCommand.remote(spec, command: ReverseSSHConnector.supportedHostCommand)
            guard ReverseSSHConnector.supportsHost(platform) else {
                throw CommandError("Reverse SSH is supported only between macOS devices.")
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
            let storage = (base as NSString).appendingPathComponent(".crow")
            try await files.ensurePrivateDirectory(storage)
            let bundles = storage + "/reverse-ssh"
            try await files.ensurePrivateDirectory(bundles)
            let path = bundles + "/" + UUID().uuidString
            // Remember the path even if the transfer fails, so partial credentials are removed.
            remoteDirectory = path
            let command = ReverseSSHConnector.script(path: path, port: port, username: server.username)
            try await files.installReverseSSHBundle(at: path, identity: server.privateKey,
                knownHosts: "[127.0.0.1]:\(port) \(try server.hostPublicKey)", command: command)
            // Installation and verification each need one SSH session channel.
            // Do not reserve an idle SFTP channel for the lifetime of the toggle.
            files.close(); self.files = nil
            try Task.checkCancellation()
            connectCommand = SystemSSHBridge.quote(path + "/connect")
            progress("Verifying server → Mac access…")
            try await verify()
        }

        func verify() async throws {
            guard let spec, let connectCommand else { throw CommandError("Reverse SSH is not ready.") }
            let marker = "CROW_REVERSE_OK_" + UUID().uuidString
            let arguments = " -T " + SystemSSHBridge.quote("printf '%s\\n' '" + marker + "'")
            let output = try await ReverseSSHCommand.remote(spec, command: "exec " + connectCommand + arguments)
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
                if let path, let spec {
                    let cleanupFiles = files ?? (try? SystemSFTP(spec: spec))
                    if let cleanupFiles { try? await cleanupFiles.removeReverseSSHBundle(at: path); cleanupFiles.close() }
                } else { files?.close() }
            }.value
            server = nil; self.files = nil
        }
    }
}
#if canImport(Citadel)
import Foundation
@preconcurrency import Citadel
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSH
import CrowCore

/// Reuses the authenticated in-app connection; never exports its saved SSH key.
@MainActor final class NativeReverseSSHOperation: ReverseSSHOperation {
    private let remote: RemoteConnection
    private let client: SSHClient
    private(set) var server: ReverseSSHServer?
    private(set) var connectCommand: String?
    private var directory: String?
    private var forwarding: Task<Void, Never>?
    private var forwardingError: Error?
    private var setupFiles: SFTPClient?

    init(remote: RemoteConnection) throws {
        guard let client = remote.client, client.isConnected else { throw FileFailure.disconnected }
        self.remote = remote; self.client = client
    }

    func open(bundleBasePath: String?, progress: (String) -> Void) async throws {
        progress("Checking macOS support…")
        guard ReverseSSHConnector.supportsHost(try await command(ReverseSSHConnector.supportedHostCommand)) else {
            throw CommandError("Reverse SSH is supported only between macOS devices.")
        }
        try Task.checkCancellation()
        progress("Preparing this Mac…")
        let server = try await ReverseSSHServer.create()
        self.server = server
        try Task.checkCancellation()
        progress("Opening reverse connection…")
        let port = try await openForward(to: server.port)
        progress("Preparing server access…")
        let files = try await client.openSFTP()
        setupFiles = files
        defer { setupFiles = nil }
        do {
            let base = try await files.getRealPath(atPath: bundleBasePath ?? ".")
            let storage = (base as NSString).appendingPathComponent(".crow")
            try await ensurePrivateDirectory(storage, files: files)
            let bundles = storage + "/reverse-ssh"
            try await ensurePrivateDirectory(bundles, files: files)
            let path = bundles + "/" + UUID().uuidString
            var attributes = SFTPFileAttributes(); attributes.permissions = 0o700
            // Only remember directories we actually created (never delete an existing one).
            try await files.createDirectory(atPath: path, attributes: attributes)
            directory = path
            let entries: [(String, String, UInt32)] = [
                ("identity", try server.privateKey, 0o600),
                ("known_hosts", "[127.0.0.1]:\(port) \(try server.hostPublicKey)", 0o600),
                ("connect", ReverseSSHConnector.script(path: path, port: port, username: server.username), 0o700)
            ]
            for (name, text, mode) in entries {
                try Task.checkCancellation()
                var attributes = SFTPFileAttributes(); attributes.permissions = mode
                let filePath = path + "/" + name
                try await files.withFile(filePath: filePath, flags: [.write, .create, .forceCreate], attributes: attributes) { file in
                    let actual = try await file.readAttributes()
                    guard let permissions = actual.permissions, permissions & 0o777 == mode else {
                        throw CommandError("The server must support private file permissions for Reverse SSH.")
                    }
                    try await file.write(ByteBuffer(string: text), at: 0)
                }
            }
            try await files.close()
            connectCommand = SystemSSHBridge.quote(path + "/connect")
        } catch { try? await files.close(); throw error }
        try Task.checkCancellation()
        progress("Verifying server → Mac access…")
        try await verify()
    }

    private func ensurePrivateDirectory(_ path: String, files: SFTPClient) async throws {
        var attributes = SFTPFileAttributes(); attributes.permissions = 0o700
        do { try await files.createDirectory(atPath: path, attributes: attributes) }
        catch { /* Validate existing storage without following a symlink below. */ }
        let components = try await files.listDirectory(atPath: (path as NSString).deletingLastPathComponent)
            .flatMap(\.components)
        let mode = components.first { $0.filename == (path as NSString).lastPathComponent }?.attributes.permissions
        guard let mode, mode & 0o170777 == 0o040700 else {
            throw CommandError("Crow storage must be a private directory (permissions 700): " + path)
        }
    }

    private func command(_ text: String) async throws -> String {
        guard remote.client === client else { throw FileFailure.disconnected }
        return try await remote.workspaceCommand(text, operation: "Reverse SSH")
    }

    func checkConnection() async throws {
        if let forwardingError { throw forwardingError }
        guard client.isConnected, remote.client === client else { throw FileFailure.disconnected }
    }

    func verify() async throws {
        try await checkConnection()
        guard let connectCommand else { throw CommandError("Reverse SSH is not ready.") }
        let marker = "CROW_REVERSE_OK_" + UUID().uuidString
        let output = try await command("exec " + connectCommand + " -T " + SystemSSHBridge.quote("printf '%s\\n' '" + marker + "'"))
        guard output.components(separatedBy: .newlines).contains(marker) else {
            throw CommandError("The reverse connection did not return its authenticated readiness response.")
        }
    }

    private func openForward(to localPort: Int) async throws -> Int {
        // Citadel registers and cancels using the requested port, so port 0 cannot
        // route accepted channels or cancel the allocated listener correctly.
        for attempt in 0..<3 {
            let port = Int.random(in: 49152...65535)
            let (opened, sink) = AsyncThrowingStream<Int, Error>.makeStream()
            let client = client
            forwardingError = nil
            forwarding = Task { [weak self] in
                do {
                    try await client.withRemotePortForward(host: "127.0.0.1", port: port,
                        configure: { channel in
                            channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                                .flatMap { channel.pipeline.addHandler(ReverseSSHChannelCodec()) }
                        }, onOpen: { forward in sink.yield(forward.boundPort) },
                        onAccept: { (incoming: NIOAsyncChannel<ByteBuffer, ByteBuffer>) in
                            try await Self.relay(incoming, to: localPort)
                        })
                } catch {
                    sink.finish(throwing: error)
                    if !(error is CancellationError) { self?.forwardingError = error }
                }
                sink.finish()
            }
            let deadline = Task {
                try? await Task.sleep(for: .seconds(12))
                if !Task.isCancelled { sink.finish(throwing: CommandError("Reverse SSH port forwarding timed out.")) }
            }
            do {
                defer { deadline.cancel() }
                for try await port in opened { try Task.checkCancellation(); return port }
                throw CancellationError()
            } catch {
                forwarding?.cancel()
                await forwarding?.value
                try Task.checkCancellation()
                // A chosen port may already be in use. Retry only explicit refusal.
                guard attempt < 2, error is NIOSSHError else { throw error }
            }
        }
        throw CommandError("The SSH server refused to open a reverse port.")
    }

    nonisolated private static func relay(_ incoming: NIOAsyncChannel<ByteBuffer, ByteBuffer>, to port: Int) async throws {
        try await incoming.executeThenClose { input, output in
            let local = try await ClientBootstrap(group: incoming.channel.eventLoop)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .connect(host: "127.0.0.1", port: port)
                .flatMapThrowing { try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: $0,
                    configuration: .init(isOutboundHalfClosureEnabled: true)) }.get()
            try await local.executeThenClose { localInput, localOutput in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await bytes in input { try await localOutput.write(bytes) }
                        localOutput.finish()
                    }
                    group.addTask {
                        for try await bytes in localInput { try await output.write(bytes) }
                        output.finish()
                    }
                    // Preserve the reply after stdin EOF (e.g. a piped command).
                    try await group.waitForAll()
                }
            }
        }
    }

    func revoke() {
        server?.stop()
        forwarding?.cancel()
        let files = setupFiles
        Task.detached { try? await files?.close() }
    }

    func close() async {
        revoke()
        let forwarding = forwarding, directory = directory, client = client
        // Cleanup must not inherit the cancelled toggle task.
        await Task.detached {
            await forwarding?.value
            if let directory, client.isConnected, let files = try? await client.openSFTP() {
                for name in ["identity", "known_hosts", "connect"] { try? await files.remove(at: directory + "/" + name) }
                try? await files.rmdir(at: directory)
                try? await files.close()
            }
        }.value
        self.forwarding = nil; self.directory = nil; server = nil
    }
}

private final class ReverseSSHChannelCodec: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard packet.type == .channel, case .byteBuffer(let bytes) = packet.data else {
            context.close(promise: nil); return
        }
        context.fireChannelRead(wrapInboundOut(bytes))
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}
#endif
#endif
