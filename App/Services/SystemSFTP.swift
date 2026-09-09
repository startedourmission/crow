#if os(macOS)
import Foundation
import CrowCore

/// SFTP v3 over an authenticated OpenSSH multiplex channel. No second password,
/// private-key import, command-shell escaping, or parsing of `ls` output.
final class SystemSFTP: @unchecked Sendable {
    private let queue = DispatchQueue(label: "crow.system-sftp")
    private let wire: Wire
    init(spec: SystemSSHSpec) throws { wire = try Wire(spec: spec) }
    var isConnected: Bool { wire.process.isRunning }

    private func run<T: Sendable>(_ body: @escaping @Sendable (Wire) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [wire] in
                let timeout = DispatchWorkItem { if wire.process.isRunning { wire.process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
                defer { timeout.cancel() }
                do { try wire.initialize(); continuation.resume(returning: try body(wire)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func close() { if wire.process.isRunning { wire.process.terminate() } }
    deinit { close() }

    func realPath(_ path: String) async throws -> String {
        try await run { wire in
            let home = try wire.realPath(".")
            return try wire.realPath(path == "~" ? home : path.hasPrefix("~/") ? home + "/" + path.dropFirst(2) : path)
        }
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
    func read(_ path: String) async throws -> String { try await run { try $0.read(path) } }
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

    private final class Wire: @unchecked Sendable {
        let process = Process()
        let input = Pipe(), output = Pipe()
        private var ready = false
        private var nextID: UInt32 = 0
        init(spec: SystemSSHSpec) throws {
            guard FileManager.default.fileExists(atPath: spec.socket) else { throw FileFailure.disconnected }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-T", "-s"] + spec.multiplexArguments + ["sftp"]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
        }
        func initialize() throws {
            guard !ready else { return }
            try send(Data([1]) + .u32(3))
            var packet = Packet(data: try receive())
            guard try packet.byte() == 2, try packet.uint32() == 3 else { throw CommandError("The server does not support SFTP v3.") }
            ready = true
        }
        private func send(_ data: Data) throws { try input.fileHandleForWriting.write(contentsOf: .u32(UInt32(data.count)) + data) }
        private func exact(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let part = try output.fileHandleForReading.read(upToCount: count - data.count), !part.isEmpty else {
                    throw CommandError("SSH/SFTP connection closed. Reconnect from the terminal.")
                }
                data.append(part)
            }
            return data
        }
        private func receive() throws -> Data {
            var header = Packet(data: try exact(4))
            let count = Int(try header.uint32())
            guard count > 0, count <= 2_097_152 else { throw CommandError("Invalid SFTP packet size.") }
            return try exact(count)
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
        func read(_ path: String) throws -> String {
            guard (try stat(path).size ?? 0) <= UInt64(TextFiles.sizeLimit) else { throw FileFailure.tooLarge }
            let handle = try open(path, flags: 1); defer { try? close(handle) }
            var data = Data()
            while true {
                var response = try request(5, .bytes(handle) + .u64(UInt64(data.count)) + .u32(32_768), expecting: 103, allowEOF: true)
                if response.eof { break }
                let chunk = try response.bytes()
                guard !chunk.isEmpty else { break }
                data.append(chunk)
                guard data.count <= TextFiles.sizeLimit else { throw FileFailure.tooLarge }
            }
            return try TextFiles.decode(data)
        }
    }
    private struct Attributes { var size: UInt64?; var permissions: UInt32? }
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
            if flags & 8 != 0 { _ = try uint32(); _ = try uint32() }
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
