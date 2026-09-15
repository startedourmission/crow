#if os(macOS)
import Foundation
import Observation
import Darwin
import CrowCore
import CryptoKit

/// Shared-key reverse access cannot identify an isolated agent execution.
/// Keep every legacy entry point closed. Managed agents use a separate transport.
enum ReverseSSHAccessPolicy {
    static let isolatedAgentsAvailable = false
    static let unavailableMessage = "Shared-key Reverse SSH is disabled. Pair this host in Crow Server settings, then open an isolated reverse agent."

    static func requireIsolatedAgentAccess() throws {
        guard isolatedAgentsAvailable else { throw CommandError(unavailableMessage) }
    }
}

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

    static func create(password: String? = nil) async throws -> ReverseSSHServer {
        try ReverseSSHAccessPolicy.requireIsolatedAgentAccess()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-client-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let server = ReverseSSHServer(directory: root)
        do {
            try await ReverseSSHCommand.generateKey(at: root.appendingPathComponent("host"))
            try await ReverseSSHCommand.generateKey(at: root.appendingPathComponent("identity"), password: password)
            try Task.checkCancellation()
            var key = try Data(contentsOf: root.appendingPathComponent("identity.pub"))
            if password != nil {
                try await ReverseSSHCommand.generateKey(at: root.appendingPathComponent("probe"))
                let probe = try String(contentsOf: root.appendingPathComponent("probe.pub"), encoding: .utf8)
                // Health checks can only print this marker, never open a shell, PTY or forward.
                key.append(Data(("restrict,command=\"echo CROW_REVERSE_OK\" " + probe).utf8))
            }
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
            LoginGraceTime \(password == nil ? 15 : 120)
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
    var probePrivateKey: String? { get throws {
        let url = directory.appendingPathComponent("probe")
        return FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
    } }
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
    static func generateKey(at url: URL, password: String? = nil) async throws {
        let arguments = ["-q", "-t", "ed25519", "-a", "64", "-f", url.path]
        guard let password else {
            _ = try await run("/usr/bin/ssh-keygen", arguments + ["-N", ""])
            return
        }
        guard !password.isEmpty, !password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
            throw CommandError("Use a nonempty, single-line Reverse SSH password.")
        }
        let root = url.deletingLastPathComponent().appendingPathComponent("askpass-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("password"), helper = root.appendingPathComponent("askpass")
        try Data(password.utf8).write(to: secret)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
        try Data(("#!/bin/sh\nexec /bin/cat " + SystemSSHBridge.quote(secret.path) + "\n").utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = helper.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = "crow-keygen"
        _ = try await run("/usr/bin/ssh-keygen", arguments, environment: environment)
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

    static func script(path: String, port: Int, username: String, passwordRequired: Bool = false) -> String {
        let quote = SystemSSHBridge.quote
        let options = "ssh -F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -o AddKeysToAgent=no -o PreferredAuthentications=publickey -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o UserKnownHostsFile=" + quote(path + "/known_hosts")
        let destination = " -p \(port) -l " + quote(username) + " 127.0.0.1"
        let probe = passwordRequired ? """
        if [ "${1-}" = --crow-check ]; then
            exec \(options) -o BatchMode=yes -T -i \(quote(path + "/probe"))\(destination)
        fi
        """ : ""
        guard ReverseSSHAccessPolicy.isolatedAgentsAvailable else {
            return "#!/bin/sh\nprintf '%s\\n' " + quote(ReverseSSHAccessPolicy.unavailableMessage) + " >&2\nexit 1\n"
        }
        return """
        #!/bin/sh
        [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/sw_vers ] || {
            printf '%s\\n' 'Reverse SSH is supported only between macOS devices.' >&2
            exit 1
        }
        # This bundle's private identity and pinned host key select exactly one Mac.
        # The health-check key can only return a fixed marker; it cannot run commands.
        \(probe)
        exec \(options) -o BatchMode=\(passwordRequired ? "no" : "yes") -i \(quote(path + "/identity"))\(destination) "$@"

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

    private static let sessions = NSHashTable<ReverseSSHSession>.weakObjects()

    init(bundleBasePath: String? = nil) {
        self.bundleBasePath = bundleBasePath
        Self.sessions.add(self)
    }

    static func revokeAll() { sessions.allObjects.forEach { $0.stop() } }

    func start(password: String? = nil, onReady: (@MainActor (String) -> Void)? = nil, connection: @escaping @MainActor () async throws -> SystemSSHSpec) {
        guard ReverseSSHAccessPolicy.isolatedAgentsAvailable else {
            stop()
            status = ReverseSSHAccessPolicy.unavailableMessage
            return
        }
        guard !isEnabled else { return }
        isEnabled = true; status = "Connecting…"; connectCommand = nil
        let operation = Operation(), bundleBasePath = bundleBasePath
        self.operation = operation
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let spec = try await connection()
                try Task.checkCancellation()
                try await operation.open(spec, bundleBasePath: bundleBasePath, password: password) { [weak self] status in
                    if self?.operation === operation { self?.status = status }
                }
                try Task.checkCancellation()
                guard let self, self.operation === operation else { throw CancellationError() }
                self.connectCommand = operation.connectCommand
                self.status = password == nil ? "On · server can access this Mac" : "On · password required"
                if let command = self.connectCommand { onReady?(command) }
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
        var passwordRequired = false

        func open(_ spec: SystemSSHSpec, bundleBasePath: String?, password: String?, progress: (String) -> Void) async throws {
            self.spec = spec
            passwordRequired = password != nil
            try Task.checkCancellation()
            progress("Checking macOS support…")
            let platform = try await ReverseSSHCommand.remote(spec, command: ReverseSSHConnector.supportedHostCommand)
            guard ReverseSSHConnector.supportsHost(platform) else {
                throw CommandError("Reverse SSH is supported only between macOS devices.")
            }
            try Task.checkCancellation()
            progress("Preparing this Mac…")
            server = try await ReverseSSHServer.create(password: password)
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
            let command = ReverseSSHConnector.script(path: path, port: port, username: server.username, passwordRequired: passwordRequired)
            try await files.installReverseSSHBundle(at: path, identity: server.privateKey,
                knownHosts: "[127.0.0.1]:\(port) \(try server.hostPublicKey)", command: command, probeIdentity: server.probePrivateKey)
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
            let marker = passwordRequired ? "CROW_REVERSE_OK" : "CROW_REVERSE_OK_" + UUID().uuidString
            let arguments = passwordRequired ? " --crow-check" : " -T " + SystemSSHBridge.quote("printf '%s\\n' '" + marker + "'")
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
#endif

#if os(macOS)
import Network
import Security

struct ManagedPairing: Codable, Sendable {
    var version = 1
    let id: UUID
    let secret: Data
    let port: UInt16
    func validated() throws -> ManagedPairing {
        guard version == 1, secret.count == 32, port > 0 else { throw CommandError("Invalid Crow server pairing code.") }
        return self
    }
    var code: String { get throws { try JSONEncoder().encode(self).base64EncodedString() } }
    static func decode(_ code: String) throws -> ManagedPairing {
        guard let data = Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines)), data.count < 2048 else { throw CommandError("Invalid Crow server pairing code.") }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }
}

/// Only ciphertext leaves the administrator-owned server. Copying its registration
/// code or inspecting the server GUI cannot reveal the transport secret.
struct ManagedPairingEnvelope: Codable {
    let version: Int
    let recipient: Data
    let ephemeral: Data
    let ciphertext: Data
    let fingerprint: String
    private static let context = Data("Crow server enrollment v1".utf8)
    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: context + data).prefix(16).map { String(format: "%02X", $0) }.joined()
    }
    static func seal(_ pairing: ManagedPairing, to recipient: Data) throws -> ManagedPairingEnvelope {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: recipient + ephemeral.publicKey.rawRepresentation,
            sharedInfo: context, outputByteCount: 32)
        let data = try JSONEncoder().encode(pairing)
        let sealed = try AES.GCM.seal(data, using: key, authenticating: context)
        guard let ciphertext = sealed.combined else { throw CommandError("Could not encrypt the pairing code.") }
        return .init(version: 1, recipient: recipient, ephemeral: ephemeral.publicKey.rawRepresentation,
            ciphertext: ciphertext, fingerprint: fingerprint(pairing.secret))
    }
    func open(using privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> ManagedPairing {
        guard version == 1, recipient == privateKey.publicKey.rawRepresentation else {
            throw CommandError("This code belongs to another client Mac. Register this Mac's public key on the server first.")
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: ephemeral))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: recipient + ephemeral,
            sharedInfo: Self.context, outputByteCount: 32)
        let data = try AES.GCM.open(.init(combined: ciphertext), using: key, authenticating: Self.context)
        let pairing = try JSONDecoder().decode(ManagedPairing.self, from: data).validated()
        guard Self.fingerprint(pairing.secret) == fingerprint else { throw CommandError("Pairing fingerprint mismatch.") }
        return pairing
    }
    var code: String { get throws { try JSONEncoder().encode(self).base64EncodedString() } }
    static func decode(_ code: String) throws -> ManagedPairingEnvelope {
        guard let data = Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines)), data.count <= 4096 else {
            throw CommandError("Invalid encrypted pairing code.")
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.recipient.count == 32, value.ephemeral.count == 32,
              value.ciphertext.count >= 28, value.fingerprint.count == 32 else { throw CommandError("Invalid encrypted pairing code.") }
        return value
    }
}

struct ManagedStart: Codable, Sendable {
    let provider: AgentProvider
    let directory: String
}

struct ManagedFrame: Codable, Sendable {
    var kind: String
    var id: UUID? = nil
    var text: String? = nil
    var data: Data? = nil
    var arguments: [String]? = nil
    var start: ManagedStart? = nil
    var columns: UInt16? = nil
    var rows: UInt16? = nil
}

/// TLS-PSK authenticates both endpoints. No pairing secret is sent through SSH,
/// environment variables, agent stdin, or the server user's home directory.
final class ManagedWire: @unchecked Sendable {
    static let maximumFrame = 4 * 1024 * 1024
    let connection: NWConnection
    private let writes = NSLock()
    private let queue = DispatchQueue(label: "crow.managed.wire", qos: .userInitiated)
    init(_ connection: NWConnection) { self.connection = connection }

    static func parameters(_ pairing: ManagedPairing) throws -> NWParameters {
        _ = try pairing.validated()
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let key = pairing.secret.withUnsafeBytes { DispatchData(bytes: $0) }
        let name = Data(pairing.id.uuidString.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, name as __DispatchData)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let params = NWParameters(tls: tls, tcp: .init())
        params.allowLocalEndpointReuse = true
        return params
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, Error>?
        var result: Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return value }
        let semaphore = DispatchSemaphore(value: 0)
        func complete(_ result: Result<T, Error>) {
            lock.lock(); defer { lock.unlock() }
            guard value == nil else { return }; value = result; semaphore.signal()
        }
    }
    func begin() throws {
        let box = ResultBox<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: box.complete(.success(()))
            case .failed(let error), .waiting(let error): box.complete(.failure(error))
            case .cancelled: box.complete(.failure(CancellationError()))
            default: break
            }
        }
        connection.start(queue: queue)
        guard box.semaphore.wait(timeout: .now() + 10) == .success else { close(); throw CommandError("Crow server did not authenticate. Check its pairing code and server mode.") }
        try box.result!.get()
        connection.stateUpdateHandler = nil
    }
    func close() { connection.cancel() }
    func send(_ frame: ManagedFrame) throws {
        let payload = try JSONEncoder().encode(frame)
        guard payload.count <= Self.maximumFrame else { throw CommandError("Crow server message is too large.") }
        var size = UInt32(payload.count).bigEndian
        var packet = withUnsafeBytes(of: &size) { Data($0) }; packet.append(payload)
        writes.lock(); defer { writes.unlock() }
        let box = ResultBox<Void>()
        connection.send(content: packet, completion: .contentProcessed { error in
            box.complete(error.map { .failure($0) } ?? .success(()))
        })
        guard box.semaphore.wait(timeout: .now() + 15) == .success else { close(); throw CommandError("Crow server stopped receiving data.") }
        try box.result!.get()
    }
    private func read(_ count: Int) throws -> Data {
        let deadline = DispatchTime.now() + 20
        var result = Data()
        while result.count < count {
            let box = ResultBox<Data>()
            connection.receive(minimumIncompleteLength: 1, maximumLength: count - result.count) { data, _, complete, error in
                if let data, !data.isEmpty { box.complete(.success(data)) }
                else { box.complete(.failure(error ?? CommandError(complete ? "Crow connection closed." : "Crow returned no data."))) }
            }
            guard box.semaphore.wait(timeout: deadline) == .success else { close(); throw CommandError("Crow connection expired.") }
            result.append(try box.result!.get())
        }
        return result
    }
    func receive() throws -> ManagedFrame {
        let header = try read(4)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= Self.maximumFrame else { throw CommandError("Invalid Crow message length.") }
        return try JSONDecoder().decode(ManagedFrame.self, from: read(Int(count)))
    }
}

final class ManagedCommand: @unchecked Sendable {
    struct Output { let status: Int32; let data: Data }
    private let lock = NSLock()
    private var process: Process?
    private var group: pid_t?
    private var cancelled = false
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let group { _ = kill(-group, SIGKILL) }
        if let process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }
    func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
             directory: String? = nil, timeout: TimeInterval = 55) throws -> Output {
        var template = Array((NSTemporaryDirectory() + "crow-command-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        task.environment = environment
        if let directory { task.currentDirectoryURL = URL(fileURLWithPath: directory) }
        task.standardOutput = output; task.standardError = output; task.standardInput = FileHandle.nullDevice
        let completion = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in completion.signal() }
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        do { try task.run() } catch { lock.unlock(); throw error }
        process = task
        if getpgid(task.processIdentifier) == task.processIdentifier { group = task.processIdentifier }
        lock.unlock()
        defer { cancel(); lock.lock(); process = nil; group = nil; lock.unlock() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while completion.wait(timeout: .now() + 0.05) != .success {
            var info = stat()
            if fstat(fd, &info) != 0 || info.st_size > 1024 * 1024 {
                cancel(); throw CommandError("Command output exceeded 1 MB.")
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                cancel(); throw CommandError("Command timed out.")
            }
        }
        lock.lock(); let stopped = cancelled; lock.unlock()
        guard !stopped else { throw CancellationError() }
        try output.seek(toOffset: 0)
        let data = try output.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024 else { throw CommandError("Command output exceeded 1 MB.") }
        return Output(status: task.terminationStatus, data: data)
    }
}

enum ManagedSystem {
    static let storage = "/var/db/crow-server"
    static let app = "/Library/Application Support/Crow/Server/Crow.app"
    static let program = app + "/Contents/MacOS/Crow"
    static let label = "dev.chajinwoo.crow.server"
    static let launchPlist = "/Library/LaunchDaemons/" + label + ".plist"

    static func requireRoot() throws {
        guard geteuid() == 0 else { throw CommandError("Crow server administration requires administrator authorization.") }
    }
    @discardableResult static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let result = try ManagedCommand().run(executable, arguments, environment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": geteuid() == 0 ? "/var/root" : FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8"], timeout: 30)
        guard result.status == 0 else { throw CommandError("Crow server operation failed: " + (executable as NSString).lastPathComponent) }
        return String(decoding: result.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func write(_ data: Data, to path: String, mode: Int = 0o600) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
    static func privateDirectory(_ path: String, mode: Int = 0o700) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory, attributes[.ownerAccountID] as? UInt32 == geteuid() else { throw CommandError("Unsafe Crow server directory.") }
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
    static func config() throws -> ManagedPairing {
        try requireRoot()
        return try JSONDecoder().decode(ManagedPairing.self, from: Data(contentsOf: URL(fileURLWithPath: storage + "/pairing.json"))).validated()
    }
    /// Only self-contained native CLIs with OS-provided dependencies are accepted.
    /// User-writable interpreters and libraries cannot become privileged job entry points.
    static func installAgent(provider: AgentProvider, source: String) throws {
        try requireRoot()
        let source = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
        let directory = storage + "/agents"
        try privateDirectory(directory, mode: 0o755)
        let destination = directory + "/" + provider.rawValue
        let staged = destination + ".new-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: staged) }
        try FileManager.default.copyItem(atPath: source, toPath: staged)
        let dependencies = try run("/usr/bin/otool", ["-L", staged]).components(separatedBy: .newlines).dropFirst()
        guard !dependencies.isEmpty, dependencies.allSatisfy({ line in
            let value = line.trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("/usr/lib/") || value.hasPrefix("/System/Library/")
                || (value.hasPrefix(staged + " (architecture ") && value.hasSuffix("):"))
        }) else { throw CommandError("Choose a standalone native agent executable. Scripts and user-installed library dependencies cannot be used for isolated agents.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: staged)
        if FileManager.default.fileExists(atPath: destination) { try FileManager.default.removeItem(atPath: destination) }
        try FileManager.default.moveItem(atPath: staged, toPath: destination)
    }
    static func setup(clientPublicKey: Data? = nil) throws -> ManagedPairing {
        try requireRoot()
        try privateDirectory(storage)
        try privateDirectory(storage + "/jobs", mode: 0o711)
        try FileManager.default.setAttributes([.posixPermissions: 0o711], ofItemAtPath: storage)
        let keyFile = storage + "/client-public-key"
        let previous = try? Data(contentsOf: URL(fileURLWithPath: keyFile))
        if let clientPublicKey {
            _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPublicKey)
            try write(clientPublicKey, to: keyFile)
            if previous != clientPublicKey { return try resetPairing() }
        }
        guard clientPublicKey != nil || previous?.count == 32 else { throw CommandError("Register the client Mac's public key first.") }
        if FileManager.default.fileExists(atPath: storage + "/pairing.json") { return try config() }
        return try resetPairing()
    }
    static func resetPairing() throws -> ManagedPairing {
        try requireRoot()
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CommandError("Could not create a server identity.") }
        let pairing = ManagedPairing(id: UUID(), secret: Data(bytes), port: 44822)
        try write(JSONEncoder().encode(pairing), to: storage + "/pairing.json")
        return pairing
    }
    static func exportedPairing(_ pairing: ManagedPairing) throws -> String {
        try requireRoot()
        let publicKey = try Data(contentsOf: URL(fileURLWithPath: storage + "/client-public-key"))
        return try ManagedPairingEnvelope.seal(pairing, to: publicKey).code
    }
    static func makeLaunchPlist() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": [program, "--crow-server"],
            "RunAtLoad": true, "KeepAlive": true, "UserName": "root", "Umask": 0o077,
            "ProcessType": "Background", "ExitTimeOut": 20], format: .xml, options: 0)
    }
}

/// One fresh Unix identity per execution; no account or key is shared with SSH logins.
final class ManagedJob: @unchecked Sendable {
    struct Lease: Codable { let identity: UUID; let uid: UInt32; let name: String; let directory: String; let owner: UInt32 }
    static let allocations = NSLock()
    let id = UUID()
    let wire: ManagedWire
    private(set) var lease: Lease?
    private var master: FileHandle?
    private var child: pid_t = 0
    private var socket: Int32 = -1
    private var socketPath = ""
    private let state = NSLock()
    private let lifecycle = NSLock()
    private var ended = false
    private var projectGrant: ManagedProjectGrant?
    private var responses: [UUID: (DispatchSemaphore, ManagedFrame?)] = [:]

    init(wire: ManagedWire) { self.wire = wire }
    func start(_ request: ManagedStart) throws {
        lifecycle.lock(); defer { lifecycle.unlock() }
        state.lock(); let stopped = ended; state.unlock()
        guard !stopped else { throw CancellationError() }
        try ManagedSystem.requireRoot()
        let executable = ManagedSystem.storage + "/agents/" + request.provider.rawValue
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw CommandError("Install this agent's native executable in Crow's server settings first.") }
        let directory = URL(fileURLWithPath: request.directory).resolvingSymlinksInPath().path
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let owner = attributes[.ownerAccountID] as? UInt32, owner >= 500,
              directory.hasPrefix("/Users/"), !directory.contains("\n"), !directory.contains("\r"), !directory.utf8.contains(0) else {
            throw CommandError("Choose a user-owned project folder under /Users on the server.")
        }
        Self.allocations.lock()
        do {
            let nextFile = ManagedSystem.storage + "/next-uid"
            var uid = UInt32((try? String(contentsOfFile: nextFile, encoding: .utf8)).flatMap { UInt32($0) } ?? 60000)
            while getpwuid(uid) != nil || uid == 65534 { uid += 1 }
            guard uid >= 60000, uid < 1_000_000 else { throw CommandError("Crow server identity range is exhausted.") }
            try ManagedSystem.write(Data(String(uid + 1).utf8), to: nextFile)
            let name = "_crow_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            lease = Lease(identity: id, uid: uid, name: name, directory: directory, owner: owner)
            try ManagedSystem.privateDirectory(jobRoot, mode: 0o711)
            try ManagedSystem.write(JSONEncoder().encode(lease!), to: jobRoot + "/lease.json")
            let record = "/Users/" + name
            try ManagedSystem.run("/usr/bin/dscl", [".", "-create", record])
            for (key, value) in [("GeneratedUID", id.uuidString), ("UniqueID", String(uid)), ("PrimaryGroupID", "65534"), ("UserShell", "/usr/bin/false"),
                                 ("NFSHomeDirectory", jobRoot + "/home"), ("IsHidden", "1"), ("AuthenticationAuthority", ";DisabledUser;")] {
                try ManagedSystem.run("/usr/bin/dscl", [".", "-create", record, key, value])
            }
            Self.allocations.unlock()
        } catch { Self.allocations.unlock(); throw error }
        guard let lease else { throw CommandError("Could not allocate an agent identity.") }
        try ManagedSystem.privateDirectory(jobRoot + "/home")
        guard chown(jobRoot + "/home", lease.uid, 65534) == 0 else { throw POSIXError(.EACCES) }
        // Git sees a different file owner by design; trust only this explicitly selected project.
        let gitPath = directory.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\t", with: "\\t")
        try ManagedSystem.write(Data(("[safe]\n\tdirectory = \"" + gitPath + "\"\n").utf8), to: jobRoot + "/home/.gitconfig")
        guard chown(jobRoot + "/home/.gitconfig", lease.uid, 65534) == 0 else { throw POSIXError(.EACCES) }
        projectGrant = try ManagedProjectGrant(path: directory, uid: lease.uid, owner: lease.owner, identity: lease.identity)
        try projectGrant?.grant()
        socketPath = "/var/run/crow-" + id.uuidString + ".sock"
        socket = try ManagedUnix.listen(socketPath, uid: lease.uid)
        let wrapper = "#!/bin/sh\nexec " + TerminalCommand.quote(ManagedSystem.program) + " --crow-reverse " + TerminalCommand.quote(socketPath) + " \"$@\"\n"
        try ManagedSystem.privateDirectory(jobRoot + "/bin", mode: 0o755)
        try ManagedSystem.write(Data(wrapper.utf8), to: jobRoot + "/bin/crow-reverse", mode: 0o755)
        var mainFD: Int32 = -1, slave: Int32 = -1
        var dimensions = winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&mainFD, &slave, nil, nil, &dimensions) == 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(slave) }
        _ = fcntl(mainFD, F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions); defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_adddup2(&actions, slave, fd) }
        var spawnAttributes: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttributes); defer { posix_spawnattr_destroy(&spawnAttributes) }
        posix_spawnattr_setflags(&spawnAttributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let arguments = [ManagedSystem.program, "--crow-agent-child", String(lease.uid), jobRoot, directory, executable] + request.provider.arguments
        let pointers = arguments.map { strdup($0) }; defer { pointers.forEach { free($0) } }
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"].map { value in value.withCString { strdup($0) } }; defer { environment.forEach { free($0) } }
        let result = (pointers + [nil]).withUnsafeBufferPointer { argv in
            (environment + [nil]).withUnsafeBufferPointer { env in
                posix_spawn(&child, ManagedSystem.program, &actions, &spawnAttributes,
                    UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard result == 0 else { Darwin.close(mainFD); throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: mainFD, closeOnDealloc: true); master = handle
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            guard let bytes = try? handle.read(upToCount: 65536), !bytes.isEmpty else { handle.readabilityHandler = nil; return }
            do { try self.wire.send(.init(kind: "output", data: bytes)) } catch { self.wire.close() }
        }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var status: Int32 = 0; _ = waitpid(self.child, &status, 0)
            try? self.wire.send(.init(kind: "exit", text: String(status)))
            self.wire.close()
        }
        DispatchQueue.global().async { [weak self] in self?.acceptReverseRequests() }
    }
    private var jobRoot: String { ManagedSystem.storage + "/jobs/" + id.uuidString }
    static func ancestors(_ path: String) -> [String] {
        var result: [String] = [], current = (path as NSString).deletingLastPathComponent
        while current != "/", !current.isEmpty { result.append(current); current = (current as NSString).deletingLastPathComponent }
        return result.reversed()
    }
    static func projectACL(_ name: String) -> String {
        "user:\(name) allow read,write,append,execute,delete,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit"
    }
    func input(_ frame: ManagedFrame) throws {
        if frame.kind == "input", let bytes = frame.data { try master?.write(contentsOf: bytes) }
        if frame.kind == "resize", let rows = frame.rows, let cols = frame.columns, let master {
            var size = winsize(ws_row: max(1, rows), ws_col: max(1, cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(master.fileDescriptor, TIOCSWINSZ, &size)
        }
        if frame.kind == "reply", let id = frame.id {
            state.lock(); if let (ready, _) = responses[id] { responses[id] = (ready, frame); ready.signal() }; state.unlock()
        }
    }
    private func acceptReverseRequests() {
        while true {
            let fd = Darwin.accept(socket, nil, nil)
            guard fd >= 0 else { return }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard let uid = lease?.uid, ManagedUnix.authorizedPeer(fd, uid: uid) else { try? handle.close(); continue }
            DispatchQueue.global().async { [weak self] in
                defer { try? handle.close() }
                guard let self else { return }
                do {
                    var request = try ManagedUnix.read(handle)
                    guard request.kind == "reverse", let args = request.arguments, args.count <= 32 else { throw CommandError("Invalid reverse request.") }
                    let id = UUID(), ready = DispatchSemaphore(value: 0); request.id = id
                    self.state.lock()
                    guard !self.ended, self.responses.count < 8 else { self.state.unlock(); return }
                    self.responses[id] = (ready, nil); self.state.unlock()
                    defer { self.state.lock(); self.responses.removeValue(forKey: id); self.state.unlock() }
                    try self.wire.send(request)
                    guard ready.wait(timeout: .now() + 60) == .success else { throw CommandError("Reverse request expired.") }
                    self.state.lock(); let reply = self.responses[id]?.1; self.state.unlock()
                    guard let reply else { return }; try ManagedUnix.write(reply, handle)
                } catch { try? ManagedUnix.write(.init(kind: "reply", text: error.localizedDescription), handle) }
            }
        }
    }
    func stop() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        state.lock(); guard !ended else { state.unlock(); return }; ended = true
        for (ready, _) in responses.values { ready.signal() }; state.unlock()
        if socket >= 0 { _ = shutdown(socket, SHUT_RDWR); Darwin.close(socket) }
        if !socketPath.isEmpty { try? FileManager.default.removeItem(atPath: socketPath) }
        master?.readabilityHandler = nil; try? master?.close(); master = nil
        guard let lease else { return }
        _ = try? ManagedSystem.run("/usr/bin/pkill", ["-KILL", "-U", String(lease.uid)])
        _ = try? ManagedSystem.run("/usr/bin/pkill", ["-KILL", "-u", String(lease.uid)])
        projectGrant?.revoke(); projectGrant = nil
        Self.clean(lease, jobRoot: jobRoot)
    }
    static func clean(_ lease: Lease, jobRoot: String) {
        let expectedName = "_crow_" + lease.identity.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard geteuid() == 0, lease.uid >= 60000, lease.uid < 1_000_000, lease.uid != 65534,
              lease.name == expectedName, jobRoot == ManagedSystem.storage + "/jobs/" + lease.identity.uuidString,
              lease.directory.hasPrefix("/Users/"), lease.owner >= 500 else { return }
        if let record = getpwnam(lease.name), record.pointee.pw_uid != lease.uid { return }
        if let record = getpwuid(lease.uid), String(cString: record.pointee.pw_name) != lease.name { return }
        let identity = try? ManagedSystem.run("/usr/bin/dscl", [".", "-read", "/Users/" + lease.name, "GeneratedUID"])
        if let identity, identity.split(whereSeparator: { $0.isWhitespace }).last.map(String.init)?.uppercased() != lease.identity.uuidString { return }
        _ = try? ManagedSystem.run("/usr/bin/pkill", ["-KILL", "-U", String(lease.uid)])
        _ = try? ManagedSystem.run("/usr/bin/pkill", ["-KILL", "-u", String(lease.uid)])
        if let grant = try? ManagedProjectGrant(path: lease.directory, uid: lease.uid, owner: lease.owner, identity: lease.identity) { grant.revoke() }
        _ = try? ManagedSystem.run("/usr/bin/dscl", [".", "-delete", "/Users/" + lease.name])
        try? FileManager.default.removeItem(atPath: "/var/run/crow-" + lease.identity.uuidString + ".sock")
        try? FileManager.default.removeItem(atPath: jobRoot)
    }

}

enum ManagedUnix {
    static func authorizedPeer(_ fd: Int32, uid expected: uid_t) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == expected
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CommandError("Crow socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
    static func listen(_ path: String, uid: uid_t) throws -> Int32 {
        var address = try address(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, chown(path, uid, 65534) == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else { Darwin.close(fd); throw POSIXError(.EACCES) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }
    static func connect(_ path: String) throws -> FileHandle {
        var address = try address(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { Darwin.close(fd); throw CommandError("This process is not an authorized reverse agent.") }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func write(_ frame: ManagedFrame, _ handle: FileHandle) throws {
        var noPipe: Int32 = 1, timeout = timeval(tv_sec: 65, tv_usec: 0)
        _ = setsockopt(handle.fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(handle.fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let data = try JSONEncoder().encode(frame)
        guard data.count <= ManagedWire.maximumFrame else { throw CommandError("Reverse message too large.") }
        var size = UInt32(data.count).bigEndian
        try handle.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) } + data)
    }
    static func read(_ handle: FileHandle) throws -> ManagedFrame {
        var timeout = timeval(tv_sec: 65, tv_usec: 0)
        _ = setsockopt(handle.fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        func exact(_ length: Int) throws -> Data {
            var data = Data()
            while data.count < length {
                guard let chunk = try handle.read(upToCount: length - data.count), !chunk.isEmpty else { throw CommandError("Reverse channel closed.") }
                data.append(chunk)
            }
            return data
        }
        let count = try exact(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= ManagedWire.maximumFrame else { throw CommandError("Invalid reverse request.") }
        return try JSONDecoder().decode(ManagedFrame.self, from: exact(Int(count)))
    }
}

final class ManagedDaemon: @unchecked Sendable {
    static let shared = ManagedDaemon()
    private let lock = NSLock()
    private var jobs: [UUID: ManagedJob] = [:]
    private var listener: NWListener?
    private var termination: DispatchSourceSignal?
    func run() throws {
        try ManagedSystem.requireRoot()
        let pairing = try ManagedSystem.config()
        let root = ManagedSystem.storage + "/jobs"
        for directory in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let path = root + "/" + directory
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path + "/lease.json")), let lease = try? JSONDecoder().decode(ManagedJob.Lease.self, from: data) {
                ManagedJob.clean(lease, jobRoot: path)
            }
        }
        let parameters = try ManagedWire.parameters(pairing)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: pairing.port)!)
        let listener = try NWListener(using: parameters); self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let job = ManagedJob(wire: ManagedWire(connection))
            self.lock.lock()
            guard self.jobs.count < 8 else { self.lock.unlock(); connection.cancel(); return }
            self.jobs[job.id] = job; self.lock.unlock()
            DispatchQueue.global().async { self.serve(job) }
        }
        listener.stateUpdateHandler = { status in if case .failed = status { exit(1) } }
        listener.start(queue: .global())
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global()); self.termination = termination
        termination.setEventHandler { [weak self] in
            guard let self else { exit(0) }
            self.listener?.cancel(); self.lock.lock(); let jobs = Array(self.jobs.values); self.lock.unlock()
            jobs.forEach { $0.wire.close(); $0.stop() }; exit(0)
        }
        termination.resume()
        dispatchMain()
    }
    private func serve(_ job: ManagedJob) {
        let wire = job.wire
        defer { wire.close(); job.stop(); lock.lock(); jobs.removeValue(forKey: job.id); lock.unlock() }
        do {
            try wire.begin()
            let first = try wire.receive()
            guard first.kind == "start", let request = first.start else { throw CommandError("An agent start request is required.") }
            // Account creation and ACL walks can outlast a socket receive deadline.
            let progress = DispatchSource.makeTimerSource(queue: .global())
            progress.schedule(deadline: .now(), repeating: .seconds(3))
            progress.setEventHandler { do { try wire.send(.init(kind: "pong")) } catch { wire.close() } }
            progress.resume(); defer { progress.cancel() }
            try wire.send(.init(kind: "output", data: Data("Starting isolated agent…\r\n".utf8)))
            try job.start(request)
            try wire.send(.init(kind: "ready", id: job.id))
            while true {
                let frame = try wire.receive()
                if frame.kind == "stop" { return }
                if frame.kind == "ping" { try wire.send(.init(kind: "pong")) }
                else { try job.input(frame) }
            }
        } catch { try? wire.send(.init(kind: "error", text: error.localizedDescription)) }
    }
}
#endif

#if os(macOS)
/// All privileged project changes use open descriptors, never paths traversed by
/// chmod/chown as root. Renames and symlinks in a shared SSH workspace cannot
/// redirect an ACL grant to another directory.
final class ManagedProjectGrant {
    let root: Int32
    let parents: [Int32]
    let uid: UInt32
    let owner: UInt32
    private var identity: uuid_t = UUID().uuid
    init(path: String, uid: UInt32, owner: UInt32, identity: UUID) throws {
        self.uid = uid; self.owner = owner; self.identity = identity.uuid
        var opened: [Int32] = []
        let initial = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard initial >= 0 else { throw POSIXError(.EIO) }
        opened.append(initial)
        do {
            for component in path.split(separator: "/") {
                guard component != ".", component != ".." else { throw CommandError("Invalid project path.") }
                let fd = openat(opened.last!, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw CommandError("Could not open project component \(component): \(String(cString: strerror(errno))). Symbolic links are not followed.") }
                opened.append(fd)
            }
            var info = stat()
            guard opened.count > 3, fstat(opened.last!, &info) == 0, info.st_uid == owner, owner >= 500 else { throw CommandError("The project is not owned by the selected server user.") }
        } catch { opened.forEach { Darwin.close($0) }; throw error }
        root = opened.removeLast(); parents = opened
    }
    deinit { Darwin.close(root); parents.forEach { Darwin.close($0) } }
    func grant() throws {
        for fd in parents {
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
            if info.st_mode & S_IXOTH == 0 { try update(fd, searchOnly: true, remove: false) }
        }
        try grantProject()
    }
    func grantProject() throws {
        try walk(root) { fd in try update(fd, searchOnly: false, remove: false) }
    }
    func revoke() {
        try? walk(root) { fd in
            var info = stat()
            if fstat(fd, &info) == 0, info.st_uid == uid { _ = fchown(fd, owner, 20) }
            try update(fd, searchOnly: false, remove: true)
        }
        for fd in parents { try? update(fd, searchOnly: true, remove: true) }
    }
    private func walk(_ fd: Int32, action: (Int32) throws -> Void) throws {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
        guard info.st_uid == owner || info.st_uid == uid else { return }
        if (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink != 1 { return }
        try action(fd)
        guard (info.st_mode & S_IFMT) == S_IFDIR, let directory = fdopendir(dup(fd)) else { return }
        defer { closedir(directory) }; rewinddir(directory)
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            let child = openat(fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { continue }
            defer { Darwin.close(child) }
            var childInfo = stat()
            guard fstat(child, &childInfo) == 0, [S_IFDIR, S_IFREG].contains(childInfo.st_mode & S_IFMT) else { continue }
            try walk(child, action: action)
        }
    }
    private func update(_ fd: Int32, searchOnly: Bool, remove: Bool) throws {
        var acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) ?? acl_init(1)
        guard acl != nil else { throw POSIXError(.EIO) }; defer { acl_free(UnsafeMutableRawPointer(acl!)) }
        var entry: acl_entry_t?
        var changed = false
        var cursor = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, cursor, &entry) == 0, let entry {
            cursor = Int32(ACL_NEXT_ENTRY.rawValue)
            if let qualifier = acl_get_qualifier(entry) {
                let matches = withUnsafeBytes(of: identity) { memcmp(qualifier, $0.baseAddress!, 16) == 0 }
                acl_free(qualifier)
                if matches { _ = acl_delete_entry(acl, entry); changed = true; cursor = Int32(ACL_FIRST_ENTRY.rawValue) }
            }
        }
        if remove && !changed { return }
        if !remove {
            guard acl_create_entry(&acl, &entry) == 0, let entry else { throw POSIXError(.EIO) }
            _ = acl_set_tag_type(entry, ACL_EXTENDED_ALLOW)
            _ = withUnsafePointer(to: identity) { acl_set_qualifier(entry, $0) }
            var permissions: acl_permset_t?
            _ = acl_get_permset(entry, &permissions); _ = acl_clear_perms(permissions)
            let values: [acl_perm_t] = searchOnly ? [ACL_EXECUTE] : [ACL_READ_DATA, ACL_WRITE_DATA, ACL_APPEND_DATA,
                ACL_EXECUTE, ACL_DELETE, ACL_DELETE_CHILD, ACL_READ_ATTRIBUTES, ACL_WRITE_ATTRIBUTES,
                ACL_READ_EXTATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_READ_SECURITY]
            for value in values { _ = acl_add_perm(permissions, value) }
            _ = acl_set_permset(entry, permissions)
            if !searchOnly {
                var info = stat()
                if fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
                    var flags: acl_flagset_t?
                    _ = acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags)
                    _ = acl_add_flag_np(flags, ACL_ENTRY_FILE_INHERIT)
                    _ = acl_add_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT)
                    _ = acl_set_flagset_np(UnsafeMutableRawPointer(entry), flags)
                }
            }
        }
        guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else {
            throw CommandError("Could not update \(searchOnly ? "parent" : "project") access: \(String(cString: strerror(errno))).")
        }
    }
}
#endif

#if os(macOS)
/// A folder capability held only on the client Mac. All file access is relative
/// to an open directory descriptor, with no symlink traversal.
final class ManagedLocalAccess: @unchecked Sendable {
    let root: String
    let commandsAllowed: Bool
    private let rootFD: Int32
    private let lock = NSLock()
    private var closed = false
    private var commands: [UUID: ManagedCommand] = [:]
    init(root: String, commandsAllowed: Bool) throws {
        self.root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        self.commandsAllowed = commandsAllowed
        rootFD = open(self.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw CommandError("Choose an accessible local folder.") }
    }
    deinit { close(); Darwin.close(rootFD) }
    func close() {
        lock.lock(); closed = true; let active = Array(commands.values); lock.unlock()
        active.forEach { $0.cancel() }
    }
    func perform(_ frame: ManagedFrame) throws -> ManagedFrame {
        lock.lock(); let stopped = closed; lock.unlock()
        guard !stopped else { throw CancellationError() }
        guard let args = frame.arguments, let operation = args.first else { throw CommandError("Use crow-reverse list|read|write|exec [path or command].") }
        if operation == "exec" {
            guard commandsAllowed, args.count == 2 else { throw CommandError("Local command execution was not enabled for this agent.") }
            let id = UUID(), command = ManagedCommand()
            lock.lock()
            guard !closed, commands.count < 8 else { lock.unlock(); throw CancellationError() }
            commands[id] = command; lock.unlock()
            defer { lock.lock(); commands.removeValue(forKey: id); lock.unlock() }
            let result = try command.run("/bin/sh", ["-c", args[1]], directory: root, timeout: 55)
            guard result.status == 0 else { throw CommandError("Local command exited with status \(result.status).\n" + String(decoding: result.data, as: UTF8.self)) }
            return .init(kind: "reply", id: frame.id, data: result.data)
        }
        guard ["list", "read", "write"].contains(operation), args.count <= 2 else { throw CommandError("Unknown reverse operation.") }
        let path = args.count == 2 ? args[1] : "."
        guard !path.hasPrefix("/"), !path.utf8.contains(0) else { throw CommandError("Use a path relative to the permitted local folder.") }
        let components = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !components.contains(".."), !components.isEmpty || operation == "list" else { throw CommandError("This path is outside the permitted folder.") }
        var parent = dup(rootFD); guard parent >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(parent) }
        for part in components.dropLast() {
            let child = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw CommandError("Folder access denied; symbolic links are not followed.") }
            Darwin.close(parent); parent = child
        }
        let last = components.last ?? "."
        let flags = operation == "write" ? (O_WRONLY | O_CREAT) : O_RDONLY
        let fd = openat(parent, last, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw CommandError("File access denied; symbolic links are not followed.") }
        defer { Darwin.close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
        if operation == "list" {
            guard (info.st_mode & S_IFMT) == S_IFDIR, let directory = fdopendir(dup(fd)) else { throw CommandError("This path is not a directory.") }
            defer { closedir(directory) }; rewinddir(directory)
            var names: [String] = []
            while let entry = readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
                if name != ".", name != ".." { names.append(name) }
                guard names.count <= 10000 else { throw CommandError("This directory has too many entries.") }
            }
            return .init(kind: "reply", id: frame.id, data: Data(names.sorted().joined(separator: "\n").utf8))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw CommandError("Only regular files without hard links are supported.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        if operation == "read" {
            guard info.st_size <= 1024 * 1024 else { throw CommandError("File exceeds the 1 MB reverse transfer limit.") }
            let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
            guard data.count <= 1024 * 1024 else { throw CommandError("File grew beyond the transfer limit.") }
            return .init(kind: "reply", id: frame.id, data: data)
        }
        guard let data = frame.data, data.count <= 1024 * 1024 else { throw CommandError("Write exceeds the 1 MB reverse transfer limit.") }
        guard ftruncate(fd, 0) == 0 else { throw POSIXError(.EIO) }
        try handle.write(contentsOf: data)
        return .init(kind: "reply", id: frame.id, data: Data())
    }
}

enum ManagedClientRunner {
    static func run(pairing: ManagedPairing, port: UInt16, request: ManagedStart, localRoot: String, commands: Bool) throws {
        let wire = ManagedWire(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: try ManagedWire.parameters(pairing)))
        let access = try ManagedLocalAccess(root: localRoot, commandsAllowed: commands)
        defer { access.close(); wire.close() }
        let signals = [SIGTERM, SIGHUP, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { access.close(); wire.close() }; source.resume(); return source
        }
        defer { signals.forEach { $0.cancel() } }
        try wire.begin()
        try wire.send(.init(kind: "start", start: request))
        var old = termios()
        let terminal = tcgetattr(STDIN_FILENO, &old) == 0
        if terminal { var raw = old; cfmakeraw(&raw); _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw) }
        defer { if terminal { _ = tcsetattr(STDIN_FILENO, TCSANOW, &old) } }
        let heartbeat = DispatchSource.makeTimerSource(queue: .global())
        heartbeat.schedule(deadline: .now() + 3, repeating: .seconds(3))
        heartbeat.setEventHandler { try? wire.send(.init(kind: "ping")) }; heartbeat.resume()
        defer { heartbeat.cancel() }
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        signal(SIGWINCH, SIG_IGN)
        let sendSize: @Sendable () -> Void = {
            var size = winsize()
            if ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0 { try? wire.send(.init(kind: "resize", columns: size.ws_col, rows: size.ws_row)) }
        }
        resize.setEventHandler(handler: sendSize); resize.resume(); defer { resize.cancel() }
        DispatchQueue.global().async {
            while true {
                let data = FileHandle.standardInput.availableData
                guard !data.isEmpty else { try? wire.send(.init(kind: "stop")); wire.close(); return }
                do { try wire.send(.init(kind: "input", data: data)) } catch { return }
            }
        }
        while true {
            let frame = try wire.receive()
            switch frame.kind {
            case "ready": sendSize()
            case "output": if let bytes = frame.data { try FileHandle.standardOutput.write(contentsOf: bytes) }
            case "error": throw CommandError(frame.text ?? "Crow server rejected the request.")
            case "exit": return
            case "reverse":
                DispatchQueue.global().async {
                    do { try wire.send(access.perform(frame)) }
                    catch { try? wire.send(.init(kind: "reply", id: frame.id, text: error.localizedDescription)) }
                }
            default: break
            }
        }
    }
}

/// Executed before SwiftUI startup. Privileged modes cannot be invoked by an SSH
/// account; the reverse helper itself has no key and must pass the server UID gate.
enum ManagedEntry {
    static func handle(_ arguments: [String] = CommandLine.arguments) -> Bool {
        guard arguments.count > 1, arguments[1].hasPrefix("--crow-") else { return false }
        do {
            switch arguments[1] {
            case "--crow-server": try ManagedDaemon.shared.run()
            case "--crow-server-setup":
                let key = arguments.count == 3 ? Data(base64Encoded: arguments[2]) : nil
                if arguments.count > 2, key?.count != 32 { throw CommandError("Invalid client public key.") }
                let pairing = try ManagedSystem.setup(clientPublicKey: key)
                try ManagedSystem.write(ManagedSystem.makeLaunchPlist(), to: ManagedSystem.launchPlist, mode: 0o644)
                print(try ManagedSystem.exportedPairing(pairing))
            case "--crow-server-pair": print(try ManagedSystem.exportedPairing(ManagedSystem.config()))
            case "--crow-server-reset-pairing": print(try ManagedSystem.exportedPairing(ManagedSystem.resetPairing()))
            case "--crow-server-install-agent":
                guard arguments.count == 4, let provider = AgentProvider(rawValue: arguments[2]) else { throw CommandError("Invalid agent installation request.") }
                try ManagedSystem.installAgent(provider: provider, source: arguments[3])
            case "--crow-agent-child":
                try ManagedSystem.requireRoot()
                guard arguments.count >= 7, let uid = UInt32(arguments[2]), uid >= 60000,
                      arguments[3].hasPrefix(ManagedSystem.storage + "/jobs/"),
                      arguments[5].hasPrefix(ManagedSystem.storage + "/agents/") else { throw CommandError("Invalid isolated child request.") }
                guard setsid() >= 0 else { throw POSIXError(.EPERM) }
                _ = ioctl(STDIN_FILENO, TIOCSCTTY, 0)
                let home = arguments[3] + "/home"
                guard setgroups(0, nil) == 0, setgid(65534) == 0, setuid(uid) == 0, geteuid() == uid,
                      chdir(arguments[4]) == 0 else { throw CommandError("Could not enter the isolated agent identity.") }
                unsetenv("DYLD_INSERT_LIBRARIES"); unsetenv("SSH_AUTH_SOCK")
                setenv("HOME", home, 1); setenv("USER", getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "crow-agent", 1)
                setenv("PATH", arguments[3] + "/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1)
                setenv("TMPDIR", home, 1); setenv("TERM", "xterm-256color", 1); setenv("SHELL", "/bin/zsh", 1)
                setenv("LANG", "en_US.UTF-8", 1); setenv("LC_CTYPE", "en_US.UTF-8", 1)
                let command = Array(arguments.dropFirst(5))
                let pointers = command.map { strdup($0) }; defer { pointers.forEach { free($0) } }
                (pointers + [nil]).withUnsafeBufferPointer { _ = execv(command[0], UnsafeMutablePointer(mutating: $0.baseAddress!)) }
                throw POSIXError(.ENOEXEC)
            case "--crow-reverse":
                guard arguments.count >= 4 else { throw CommandError("Use crow-reverse list|read|write|exec [path or command].") }
                let channel = try ManagedUnix.connect(arguments[2]); defer { try? channel.close() }
                let args = Array(arguments.dropFirst(3))
                let input = args.first == "write" ? try FileHandle.standardInput.read(upToCount: 1024 * 1024 + 1) : nil
                try ManagedUnix.write(.init(kind: "reverse", data: input, arguments: args), channel)
                let response = try ManagedUnix.read(channel)
                if let error = response.text { throw CommandError(error) }
                try FileHandle.standardOutput.write(contentsOf: response.data ?? Data())
            default: return false
            }
            exit(0)
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
#endif
