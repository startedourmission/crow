#if os(macOS)
import Foundation
import CrowCore
import Darwin

/// SFTP v3 over an authenticated OpenSSH multiplex channel. No second password,
/// private-key import or parsing of `ls` output. File paths use SFTP packets,
/// never shell interpolation (including the login-shell server fallback).
final class SystemSFTP: @unchecked Sendable {
    private let queue = DispatchQueue(label: "crow.system-sftp")
    private let wire: Wire
    init(spec: SystemSSHSpec) throws { wire = try Wire(spec: spec) }
    var isConnected: Bool { wire.isConnected }

    /// Negotiate capabilities, not OS names, distributions or host-specific settings.
    private enum Transport: String, CaseIterable {
        case subsystem = "SFTP subsystem"
        case command = "Remote command"
        case shell = "Shell stream"
    }

    /// A fixed POSIX bootstrap; no file paths or user commands are interpolated.
    /// Used only if the standard subsystem fails. No installation or server changes.
    private static func serverCommand(marker: String) -> String {
        "exec sh -c " + SystemSSHBridge.quote("""
        crow_sftp_path=$(command -v sftp-server 2>/dev/null)
        for crow_sftp_server in "$crow_sftp_path" /usr/lib/openssh/sftp-server /usr/lib/ssh/sftp-server /usr/libexec/openssh/sftp-server /usr/libexec/sftp-server /usr/local/libexec/sftp-server /usr/local/libexec/openssh/sftp-server; do
          if test -n "$crow_sftp_server" && test -x "$crow_sftp_server"; then
            # Preserve the SSH login environment's starting directory.
            printf '\\n%s\\n' '\(marker)'
            exec "$crow_sftp_server"
          fi
        done
        printf '%s\\n' 'No executable sftp-server found in the login environment (PATH or standard OpenSSH locations).' >&2
        exit 127
        """)
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (Wire) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [wire] in
                let timeout = DispatchWorkItem { wire.close() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
                defer { timeout.cancel() }
                do { try wire.initialize(); continuation.resume(returning: try body(wire)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func close() { wire.close() }
    deinit { close() }

    func uploadClipboardImage(_ data: Data) async throws -> String {
        try ClipboardImage.validate(data)
        return try await run { wire in
            let directory = "/tmp/crow-clipboard-" + UUID().uuidString
            let path = directory + "/image.png"
            _ = try wire.request(14, .string(directory) + .u32(4) + .u32(0o700))
            do {
                let handle = try wire.open(path, flags: 2 | 8 | 32, permissions: 0o600)
                do {
                    for offset in stride(from: 0, to: data.count, by: 32_768) {
                        _ = try wire.request(6, .bytes(handle) + .u64(UInt64(offset)) + .bytes(data.subdata(in: offset..<min(offset + 32_768, data.count))))
                    }
                    try wire.close(handle)
                } catch { try? wire.close(handle); throw error }
                return path
            } catch {
                _ = try? wire.request(13, .string(path)); _ = try? wire.request(15, .string(directory))
                throw error
            }
        }
    }

    static func protectWrites(to handle: FileHandle) throws {
        // Convert a closed reader into EPIPE instead of killing Crow with SIGPIPE.
        // This is descriptor-local: do not change signal behavior in users' child shells.
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func realPath(_ path: String) async throws -> String {
        try await run { try $0.resolvePath(path) }
    }
    func list(_ path: String) async throws -> [FileEntry] {
        try await run { wire in
            var opened = try wire.request(11, .string(path), expecting: 102)
            let handle = try opened.bytes(); defer { try? wire.close(handle) }
            var entries: [FileEntry] = []
            while true {
                var response = try wire.request(12, .bytes(handle), expecting: 104, allowEOF: true)
                if response.eof { break }
                let count = try response.uint32()
                guard count < 100_000 else { throw CommandError("Invalid SFTP directory response.") }
                for _ in 0..<count {
                    let name = try response.string(); _ = try response.string()
                    let attrs = try response.attributes()
                    if name == "." || name == ".." || name.contains("/") || name.contains("\0") { continue }
                    entries.append(FileEntry(name: name, path: (path as NSString).appendingPathComponent(name),
                        isDirectory: (attrs.permissions ?? 0) & 0o170000 == 0o040000))
                }
            }
            return entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }
    func revision(_ path: String) async throws -> FileRevision {
        try await run {
            let attributes = try $0.stat(path)
            return FileRevision(size: attributes.size, modified: attributes.modified.map { Date(timeIntervalSince1970: Double($0)) })
        }
    }
    func read(_ path: String, maximumSize: Int = TextFiles.sizeLimit) async throws -> String {
        try await run { try $0.read(path, maximumSize: maximumSize) }
    }
    func write(_ text: String, path: String, expected: String?, overwrite: Bool) async throws {
        try await run { wire in
            if !overwrite, let expected, try wire.read(path) != expected { throw FileFailure.conflict }
            let attrs = try wire.stat(path), temporary = path + ".crow-upload-" + UUID().uuidString
            do {
                let handle = try wire.open(temporary, flags: 2 | 8 | 32, permissions: attrs.permissions)
                do {
                    let data = Data(text.utf8)
                    for offset in stride(from: 0, to: data.count, by: 32_768) {
                        _ = try wire.request(6, .bytes(handle) + .u64(UInt64(offset)) + .bytes(data.subdata(in: offset..<min(offset + 32_768, data.count))))
                    }
                    try wire.close(handle)
                } catch { try? wire.close(handle); throw error }
                if !overwrite, let expected, try wire.read(path) != expected { throw FileFailure.conflict }
                let backup = path + ".crow-backup-" + UUID().uuidString
                try wire.rename(path, backup)
                do { try wire.rename(temporary, path) }
                catch {
                    do { try wire.rename(backup, path) }
                    catch { throw CommandError("Save failed. The original is recoverable at \(backup); your draft is still open.") }
                    throw error
                }
                _ = try? wire.request(13, .string(backup))
            } catch { _ = try? wire.request(13, .string(temporary)); throw error }
        }
    }
    func create(_ path: String, directory: Bool) async throws {
        try await run { wire in
            if directory { _ = try wire.request(14, .string(path) + .u32(0)) }
            else { let handle = try wire.open(path, flags: 2 | 8 | 32); try wire.close(handle) }
        }
    }
    func rename(_ source: String, to destination: String) async throws { try await run { try $0.rename(source, destination) } }

    /// Never place a client access key in a world-readable directory or follow an existing file.
    func installReverseSSHBundle(at path: String, identity: String, knownHosts: String, command: String) async throws {
        try await run { wire in
            _ = try wire.request(14, .string(path) + .u32(4) + .u32(0o700))
            guard let mode = try wire.stat(path).permissions, mode & 0o777 == 0o700 else {
                throw CommandError("The server must support private directory permissions for Reverse SSH.")
            }
            for (name, text, mode): (String, String, UInt32) in [
                ("identity", identity, 0o600), ("known_hosts", knownHosts, 0o600), ("connect", command, 0o700),
            ] {
                let file = path + "/" + name
                let handle = try wire.open(file, flags: 2 | 8 | 32, permissions: mode)
                do {
                    guard let permissions = try wire.stat(file).permissions, permissions & 0o777 == mode else {
                        throw CommandError("The server must support private file permissions for Reverse SSH.")
                    }
                    _ = try wire.request(6, .bytes(handle) + .u64(0) + .bytes(Data(text.utf8)))
                    try wire.close(handle)
                } catch { try? wire.close(handle); throw error }
            }
        }
    }

    func removeReverseSSHBundle(at path: String) async throws {
        guard (path as NSString).lastPathComponent.hasPrefix(".crow-client-") else {
            throw CommandError("Invalid Reverse SSH connection directory.")
        }
        try await run { wire in
            for name in ["identity", "known_hosts", "connect"] { _ = try? wire.request(13, .string(path + "/" + name)) }
            _ = try wire.request(15, .string(path))
        }
    }

    private final class Wire: @unchecked Sendable {
        private let spec: SystemSSHSpec
        private let lifecycle = NSLock()
        private var channel: Channel
        private var closed = false
        private var starting = true
        private var ready = false // Accessed only on the serial file queue.
        private var reportsHome = false
        private var nextID: UInt32 = 0
        init(spec: SystemSSHSpec) throws {
            self.spec = spec
            channel = try Channel(spec: spec, transport: .subsystem)
        }
        var isConnected: Bool {
            lifecycle.lock(); defer { lifecycle.unlock() }
            return !closed && (starting || channel.process.isRunning)
        }
        private func activeChannel() throws -> Channel {
            lifecycle.lock(); defer { lifecycle.unlock() }
            guard !closed else { throw FileFailure.disconnected }
            return channel
        }
        func close() {
            lifecycle.lock(); closed = true; let channel = channel; lifecycle.unlock()
            channel.close()
        }
        func initialize() throws {
            if ready { _ = try activeChannel(); return }
            var failures: [String] = []
            for transport in Transport.allCases {
                if transport != .subsystem {
                    // Never retry a file operation. Explicit close/timeout must not
                    // resurrect a channel, and every attempt reuses the same SSH master.
                    lifecycle.lock()
                    guard !closed else { lifecycle.unlock(); throw FileFailure.disconnected }
                    channel.close()
                    do { channel = try Channel(spec: spec, transport: transport) }
                    catch { closed = true; starting = false; lifecycle.unlock(); throw error }
                    lifecycle.unlock()
                }
                do {
                    let attempt = try activeChannel()
                    let deadline = DispatchWorkItem { attempt.expireNegotiation() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: deadline)
                    defer { deadline.cancel(); _ = attempt.finishNegotiation() }
                    try attempt.prepare()
                    try handshake()
                    guard attempt.finishNegotiation() else { throw CommandError("SFTP negotiation timed out.") }
                    lifecycle.lock()
                    guard !closed else { lifecycle.unlock(); throw FileFailure.disconnected }
                    starting = false; ready = true
                    lifecycle.unlock()
                    return
                }
                catch {
                    failures.append("\(transport.rawValue): \(error.localizedDescription)")
                    lifecycle.lock(); let cancelled = closed; lifecycle.unlock()
                    if cancelled { throw FileFailure.disconnected }
                }
            }
            close()
            throw CommandError("File connection unavailable. The server needs a working SFTP subsystem or a POSIX shell with an executable sftp-server. No server settings were changed; the terminal connection was left open.\n\n" + failures.joined(separator: "\n\n"))
        }
        private func handshake() throws {
            try send(Data([1]) + .u32(3))
            var packet = Packet(data: try receive())
            guard try packet.byte() == 2, try packet.uint32() == 3 else { throw CommandError("The server does not support SFTP v3.") }
            reportsHome = false
            while packet.offset < packet.data.count {
                let name = try packet.string(), version = try packet.string()
                if name == "home-directory", version == "1" { reportsHome = true }
            }
        }
        private func send(_ data: Data) throws {
            let channel = try activeChannel()
            guard channel.process.isRunning else { throw channel.closedError() }
            do { try channel.input.fileHandleForWriting.write(contentsOf: .u32(UInt32(data.count)) + data) }
            catch { throw channel.closedError() }
        }
        private func exact(_ count: Int) throws -> Data {
            let channel = try activeChannel()
            var data = Data()
            while data.count < count {
                let part = try channel.read(count - data.count)
                data.append(part)
            }
            return data
        }
        private func receive() throws -> Data {
            var header = Packet(data: try exact(4))
            let count = Int(try header.uint32())
            guard count > 0, count <= 2_097_152 else { throw CommandError("Invalid SFTP packet size. The noninteractive login shell may be printing startup text.") }
            return try exact(count)
        }

        private final class Channel: @unchecked Sendable {
            let process = Process()
            let input = Pipe(), output = Pipe(), errors = Pipe()
            private let diagnostics = Diagnostics()
            private let transport: Transport
            private let marker = "CROW_SFTP_READY_" + UUID().uuidString
            private var buffered = Data() // Only accessed on the serial file queue.
            private let negotiationLock = NSLock()
            private var negotiationEnded = false
            private var negotiationExpired = false
            init(spec: SystemSSHSpec, transport: Transport) throws {
                self.transport = transport
                guard FileManager.default.fileExists(atPath: spec.socket) else { throw FileFailure.disconnected }
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                let command: [String]
                switch transport {
                case .subsystem: command = ["sftp"]
                case .command: command = [SystemSFTP.serverCommand(marker: marker)]
                case .shell: command = [] // SSH shell request: no remote command option.
                }
                process.arguments = (transport == .subsystem ? ["-T", "-s"] : ["-T"]) + spec.multiplexArguments + command
                process.standardInput = input; process.standardOutput = output; process.standardError = errors
                let diagnostics = self.diagnostics
                errors.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil }
                    else { diagnostics.append(data) }
                }
                try SystemSFTP.protectWrites(to: input.fileHandleForWriting)
                try process.run()
            }
            func expireNegotiation() {
                negotiationLock.lock(); defer { negotiationLock.unlock() }
                guard !negotiationEnded else { return }
                negotiationExpired = true; negotiationEnded = true
                close()
            }
            @discardableResult func finishNegotiation() -> Bool {
                negotiationLock.lock(); defer { negotiationLock.unlock() }
                negotiationEnded = true
                return !negotiationExpired
            }
            func prepare() throws {
                guard transport != .subsystem else { return }
                if transport == .shell {
                    // Send the bootstrap as shell input, not an SSH exec request.
                    // It bypasses broken command wrappers/options while preserving
                    // the user's selected login environment. Never allocate a PTY:
                    // terminal echo/newline translation would corrupt binary SFTP.
                    do { try input.fileHandleForWriting.write(contentsOf: Data((SystemSFTP.serverCommand(marker: marker) + "\n").utf8)) }
                    catch { throw closedError() }
                }
                // Wait until the shell has consumed the entire bootstrap before sending
                // binary INIT. Discard bounded startup banners, never protocol packets.
                let delimiter = Data(("\n" + marker + "\n").utf8)
                var startup = Data()
                while startup.count < 65_536 {
                    startup.append(try read(4096))
                    if let range = startup.range(of: delimiter) {
                        buffered = Data(startup[range.upperBound...])
                        return
                    }
                }
                throw CommandError("Shell startup exceeded 64 KiB without an SFTP-ready marker.")
            }
            func read(_ count: Int) throws -> Data {
                if !buffered.isEmpty {
                    let result = Data(buffered.prefix(count)); buffered.removeFirst(result.count); return result
                }
                // One pipe read returns available bytes; FileHandle's sized read may
                // wait for a full buffer and deadlock on a short bootstrap marker.
                var bytes = [UInt8](repeating: 0, count: count)
                while true {
                    let received = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, count)
                    if received > 0 { return Data(bytes.prefix(received)) }
                    if received < 0 && errno == EINTR { continue }
                    throw closedError()
                }
            }
            func closedError() -> CommandError {
                negotiationLock.lock(); let expired = negotiationExpired; negotiationLock.unlock()
                let explanation = expired ? "SFTP negotiation timed out." : "The SFTP file channel closed."
                let detail = diagnostics.text
                return CommandError(detail.isEmpty ? explanation : explanation + "\n\n" + detail)
            }
            func close() {
                if process.isRunning { process.terminate() }
            }
            deinit { close(); errors.fileHandleForReading.readabilityHandler = nil }
        }
        func request(_ type: UInt8, _ payload: Data, expecting: UInt8 = 101, allowEOF: Bool = false) throws -> Packet {
            nextID &+= 1
            try send(Data([type]) + .u32(nextID) + payload)
            var response = Packet(data: try receive())
            let receivedType = try response.byte()
            guard try response.uint32() == nextID else { throw CommandError("Unexpected SFTP response identifier.") }
            if receivedType == 101 {
                let status = try response.uint32()
                if status == 1, allowEOF { return Packet(data: Data(), eof: true) }
                guard status == 0 else { throw CommandError("SFTP: \((try? response.string()) ?? "request failed") (\(status))") }
                guard expecting == 101 else { throw CommandError("Missing SFTP response data.") }
            } else if receivedType != expecting { throw CommandError("Unexpected SFTP response type.") }
            return response
        }
        func realPath(_ path: String) throws -> String {
            var response = try request(16, .string(path), expecting: 104)
            guard try response.uint32() > 0 else { throw CommandError("SFTP returned no path.") }
            return try response.string()
        }
        func resolvePath(_ path: String) throws -> String {
            guard path == "~" || path.hasPrefix("~/") else { return try realPath(path) }
            // A server's starting working directory isn't necessarily the user's home.
            // Keep the explicit Home action separate from initial "." discovery.
            let home: String
            if reportsHome {
                // expand-path("~") intentionally means server CWD in OpenSSH.
                // home-directory with an empty username reports the actual account home.
                var response = try request(200, .string("home-directory") + .string(""), expecting: 104)
                guard try response.uint32() > 0 else { throw CommandError("SFTP returned no home path.") }
                home = try response.string()
            } else { home = try realPath(".") }
            return try realPath(path == "~" ? home : home + "/" + path.dropFirst(2))
        }
        func stat(_ path: String) throws -> Attributes {
            var response = try request(17, .string(path), expecting: 105)
            return try response.attributes()
        }
        func open(_ path: String, flags: UInt32, permissions: UInt32? = nil) throws -> Data {
            let attrs: Data = permissions.map { .u32(4) + .u32($0) } ?? .u32(0)
            var response = try request(3, .string(path) + .u32(flags) + attrs, expecting: 102)
            return try response.bytes()
        }
        func close(_ handle: Data) throws { _ = try request(4, .bytes(handle)) }
        func rename(_ source: String, _ destination: String) throws { _ = try request(18, .string(source) + .string(destination)) }
        func read(_ path: String, maximumSize: Int = TextFiles.sizeLimit) throws -> String {
            guard (try stat(path).size ?? 0) <= UInt64(maximumSize) else { throw FileFailure.tooLarge }
            let handle = try open(path, flags: 1); defer { try? close(handle) }
            var data = Data()
            while true {
                var response = try request(5, .bytes(handle) + .u64(UInt64(data.count)) + .u32(32_768), expecting: 103, allowEOF: true)
                if response.eof { break }
                let chunk = try response.bytes()
                guard !chunk.isEmpty else { break }
                data.append(chunk)
                guard data.count <= maximumSize else { throw FileFailure.tooLarge }
            }
            return try TextFiles.decode(data)
        }
    }
    /// Drain stderr continuously without letting a noisy server block or grow memory unboundedly.
    private final class Diagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk); if data.count > 8192 { data = data.suffix(8192) }
        }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    private struct Attributes { var size: UInt64?; var permissions: UInt32?; var modified: UInt32? }
    private struct Packet {
        let data: Data
        var offset = 0
        var eof = false
        mutating func byte() throws -> UInt8 {
            guard offset < data.count else { throw CommandError("Truncated SFTP response.") }
            defer { offset += 1 }; return data[offset]
        }
        mutating func uint32() throws -> UInt32 { var result: UInt32 = 0; for _ in 0..<4 { result = (result << 8) | UInt32(try byte()) }; return result }
        mutating func uint64() throws -> UInt64 { (UInt64(try uint32()) << 32) | UInt64(try uint32()) }
        mutating func bytes() throws -> Data {
            let length = Int(try uint32())
            guard length <= data.count - offset else { throw CommandError("Truncated SFTP string.") }
            defer { offset += length }; return data.subdata(in: offset..<offset + length)
        }
        mutating func string() throws -> String {
            guard let text = String(data: try bytes(), encoding: .utf8) else { throw FileFailure.unsupportedText }; return text
        }
        mutating func attributes() throws -> Attributes {
            let flags = try uint32(); var attrs = Attributes()
            if flags & 1 != 0 { attrs.size = try uint64() }
            if flags & 2 != 0 { _ = try uint32(); _ = try uint32() }
            if flags & 4 != 0 { attrs.permissions = try uint32() }
            if flags & 8 != 0 { _ = try uint32(); attrs.modified = try uint32() }
            if flags & 0x80000000 != 0 {
                let count = try uint32(); guard count < 1000 else { throw CommandError("Invalid SFTP attributes.") }
                for _ in 0..<count { _ = try bytes(); _ = try bytes() }
            }
            return attrs
        }
    }
}

private extension Data {
    static func + (left: Data, right: Data) -> Data { var result = left; result.append(right); return result }
    static func u32(_ value: UInt32) -> Data { Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
    static func u64(_ value: UInt64) -> Data { .u32(UInt32(truncatingIfNeeded: value >> 32)) + .u32(UInt32(truncatingIfNeeded: value)) }
    static func bytes(_ value: Data) -> Data { .u32(UInt32(value.count)) + value }
    static func string(_ value: String) -> Data { .bytes(Data(value.utf8)) }
}
#endif
