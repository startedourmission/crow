import Foundation
import CrowCore
@preconcurrency import Citadel
@preconcurrency import NIOCore
@preconcurrency import NIOSSH
#if os(macOS)
import Darwin
#endif

/// Only a child channel is owned here; closing the screen never closes SSH/SFTP.
@MainActor final class ScreenTransport {
    private var channel: Channel?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    #if os(macOS)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var diagnostics: FileHandle?
    #endif

    func open(in state: WorkspaceState, port: Int, host: String = "127.0.0.1") async throws -> AsyncThrowingStream<Data, Error> {
        guard (1...65535).contains(port), state.snapshot.workspace.isRemote else {
            throw CommandError("Choose a connected SSH server and a screen sharing port between 1 and 65535.")
        }
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        continuation = pair.continuation
        #if os(macOS)
        if let spec = state.systemSSH {
            guard FileManager.default.fileExists(atPath: spec.socket) else { throw FileFailure.disconnected }
            let task = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            task.arguments = ["-T", "-W", "\(host.contains(":") ? "[\(host)]" : host):\(port)"] + spec.multiplexArguments
            task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
            try SystemSFTP.protectWrites(to: stdin.fileHandleForWriting)
            let sink = pair.continuation
            stdout.fileHandleForReading.readabilityHandler = { handle in
                do {
                    let data = try Self.readAvailable(handle)
                    if data.isEmpty { sink.finish(); handle.readabilityHandler = nil }
                    else if case .dropped = sink.yield(data) {
                        sink.finish(throwing: CommandError("Screen data arrived faster than it could be displayed. Reconnect to try again."))
                        handle.readabilityHandler = nil
                    }
                } catch { sink.finish(throwing: error); handle.readabilityHandler = nil }
            }
            // Drain stderr without logging credentials or allowing a full pipe to stall ssh.
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = (try? Self.readAvailable(handle)) ?? Data()
                if data.isEmpty { handle.readabilityHandler = nil }
                else { sink.finish(throwing: CommandError(String(decoding: data.prefix(2000), as: UTF8.self))) }
            }
            process = task; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
            diagnostics = stderr.fileHandleForReading
            do { try task.run() } catch { close(); throw error }
            return pair.stream
        }
        #endif
        guard let client = state.remote?.client, client.isConnected else { throw FileFailure.disconnected }
        let opened = try await Self.openChannel(ScreenSSHClient(value: client), host: host, port: port, sink: pair.continuation)
        guard !Task.isCancelled else { try? await opened.close(); throw CancellationError() }
        channel = opened
        return pair.stream
    }

    #if os(macOS)
    nonisolated private static func readAvailable(_ handle: FileHandle) throws -> Data {
        // FileHandle.read(upToCount:) can wait to fill the requested count on a pipe.
        // RFB sends a short greeting and then waits for us, so read one available chunk.
        var buffer = [UInt8](repeating: 0, count: 32_768)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Data(buffer.prefix(count))
    }
    #endif

    nonisolated private static func openChannel(_ client: ScreenSSHClient, host: String, port: Int,
        sink: AsyncThrowingStream<Data, Error>.Continuation) async throws -> Channel {
        try await client.value.createDirectTCPIPChannel(using: .init(targetHost: host, targetPort: port,
            originatorAddress: SocketAddress(ipAddress: "127.0.0.1", port: 0))) { channel in
                channel.pipeline.addHandler(ScreenChannelHandler(sink))
            }
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        if let channel { try await channel.writeAndFlush(ByteBuffer(bytes: data)); return }
        #if os(macOS)
        if let input {
            try await Task.detached { try input.write(contentsOf: data) }.value
            return
        }
        #endif
        throw FileFailure.disconnected
    }

    func close() {
        continuation?.finish(); continuation = nil
        let old = channel; channel = nil
        if let old { old.close(promise: nil) }
        #if os(macOS)
        output?.readabilityHandler = nil
        diagnostics?.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        try? input?.close(); input = nil
        try? output?.close(); output = nil
        try? diagnostics?.close(); diagnostics = nil
        #endif
    }
}

// Citadel's channel factory schedules operations on its NIO event loop.
private struct ScreenSSHClient: @unchecked Sendable { let value: SSHClient }

private final class ScreenChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let sink: AsyncThrowingStream<Data, Error>.Continuation
    init(_ sink: AsyncThrowingStream<Data, Error>.Continuation) { self.sink = sink }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if case .dropped = sink.yield(Data(buffer.readableBytesView)) {
            sink.finish(throwing: CommandError("Screen data arrived faster than it could be displayed. Reconnect to try again."))
            context.close(promise: nil)
        }
    }
    func channelInactive(context: ChannelHandlerContext) { sink.finish(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { sink.finish(throwing: error); context.close(promise: nil) }
}

#if os(macOS)
/// Uses the existing SSH account and macOS pasteboard APIs. No remote files or service are installed.
@MainActor enum MacScreenClipboard {
    struct Packet: Codable, Sendable {
        var revision: Int?
        var png: String?
        var text: String?
        var includeImages: Bool?
    }
    nonisolated static let outputLimit = 32 * 1024 * 1024
    static let helper = #"""
ObjC.import('AppKit');
function run(args) {
    const limit = 20 * 1024 * 1024;
    const length = Number(args[0]);
    if (!(length > 0 && length <= 30 * 1024 * 1024)) throw Error('Clipboard request is too large.');
    const input = $.NSMutableData.data;
    while (input.length < length) {
        const part = $.NSFileHandle.fileHandleWithStandardInput.readDataOfLength(Math.min(65536, length - input.length));
        if (!part.length) throw Error('Incomplete clipboard request.');
        input.appendData(part);
    }
    const request = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding)));
    const board = args[1] ? $.NSPasteboard.pasteboardWithName(args[1]) : $.NSPasteboard.generalPasteboard;
    function bitmap(data) {
        if (!data || !data.length || data.length > limit) throw Error('Clipboard image exceeds 20 MB.');
        const rep = $.NSBitmapImageRep.imageRepWithData(data);
        if (!rep || rep.isNil() || !(rep.pixelsWide > 0 && rep.pixelsHigh > 0 && rep.pixelsWide <= 40000000 / rep.pixelsHigh)) throw Error('Invalid clipboard image (maximum 40 megapixels).');
        return rep;
    }
    if (request.png != null) {
        const data = $.NSData.alloc.initWithBase64EncodedStringOptions(request.png, 0);
        const rep = bitmap(data);
        board.clearContents;
        if (!board.setDataForType(data, $.NSPasteboardTypePNG)) throw Error('Could not write the image clipboard.');
        board.setDataForType(rep.TIFFRepresentation, $.NSPasteboardTypeTIFF);
        if (request.text != null) {
            if (request.text.length > 1000000) throw Error('Clipboard text is too large.');
            if (!board.setStringForType(request.text, $.NSPasteboardTypeString)) throw Error('Could not write the text clipboard.');
        }
        return JSON.stringify({revision: Number(board.changeCount)});
    }
    if (request.text != null) {
        if (request.text.length > 1000000) throw Error('Clipboard text is too large.');
        board.clearContents;
        if (!board.setStringForType(request.text, $.NSPasteboardTypeString)) throw Error('Could not write the text clipboard.');
        return JSON.stringify({revision: Number(board.changeCount)});
    }
    const revision = Number(board.changeCount);
    if (request.revision === revision) return JSON.stringify({revision});
    let image = request.includeImages === false ? null : board.dataForType($.NSPasteboardTypePNG);
    if (request.includeImages !== false && (!image || image.isNil())) image = board.dataForType($.NSPasteboardTypeTIFF);
    const text = board.stringForType($.NSPasteboardTypeString);
    const result = text && !text.isNil() ? {revision, text: ObjC.unwrap(text)} : {revision};
    if (image && !image.isNil()) {
        const png = bitmap(image).representationUsingTypeProperties($.NSPNGFileType, $({}));
        if (!png || png.isNil() || png.length > limit) throw Error('Clipboard image exceeds 20 MB.');
        result.png = ObjC.unwrap(png.base64EncodedStringWithOptions(0));
    }
    return JSON.stringify(result);
}
"""#

    static func exchange(_ packet: Packet, in state: WorkspaceState, pasteboardName: String? = nil) async throws -> Packet {
        let input = try JSONEncoder().encode(packet)
        let command = command(length: input.count, pasteboardName: pasteboardName)
        let output: Data
        if let spec = state.systemSSH {
            let work = Task.detached { try run(spec: spec, command: command, input: input) }
            output = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } else if let client = state.remote?.client {
            output = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    var data = Data(), diagnostic = Data(), completed = false
                    do {
                        try await client.withExec(command) { inbound, outbound in
                            for offset in stride(from: 0, to: input.count, by: 32768) {
                                try Task.checkCancellation()
                                try await outbound.write(ByteBuffer(bytes: input[offset..<min(offset + 32768, input.count)]))
                            }
                            for try await chunk in inbound {
                                try Task.checkCancellation()
                                if case .stdout(let bytes) = chunk { data.append(contentsOf: bytes.readableBytesView) }
                                if case .stderr(let bytes) = chunk { diagnostic.append(contentsOf: bytes.readableBytesView) }
                                guard data.count <= outputLimit else { throw CommandError("Image clipboard response exceeds 32 MB.") }
                                guard diagnostic.count <= 8192 else { throw CommandError("Image clipboard command failed.") }
                            }
                            completed = true
                        }
                    } catch ChannelError.alreadyClosed where completed { }
                    catch {
                        if !diagnostic.isEmpty { throw CommandError("Image clipboard: " + String(decoding: diagnostic.prefix(2000), as: UTF8.self)) }
                        throw error
                    }
                    if data.isEmpty, !diagnostic.isEmpty {
                        throw CommandError("Image clipboard: " + String(decoding: diagnostic.prefix(2000), as: UTF8.self))
                    }
                    return data
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw CommandError("Image clipboard timed out. The screen connection remains open.")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? Data()
            }
        } else { throw FileFailure.disconnected }
        try Task.checkCancellation()
        guard let result = try? JSONDecoder().decode(Packet.self, from: output), result.revision != nil else {
            throw CommandError("The Mac clipboard helper did not return a valid response. Check that this SSH account can access its desktop clipboard.")
        }
        return result
    }

    private static func command(length: Int, pasteboardName: String?) -> String {
        // /dev/console can belong to root while the user's GUI session still exists.
        // Use the SSH account's own pasteboard service; do not infer access from console ownership.
        return "exec /usr/bin/osascript -l JavaScript -e " + GitRepository.quote(helper)
            + " -- " + String(length) + " " + GitRepository.quote(pasteboardName ?? "")
    }

    nonisolated private static func run(spec: SystemSSHSpec, command: String, input: Data) throws -> Data {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-screen-clipboard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let inputURL = root.appendingPathComponent("input"), outputURL = root.appendingPathComponent("output")
        let errorURL = root.appendingPathComponent("error")
        try input.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let stdin = try FileHandle(forReadingFrom: inputURL), stdout = try FileHandle(forWritingTo: outputURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-T"] + spec.multiplexArguments + [command]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw CommandError("Image clipboard timed out.") }
            guard ((try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= 32 * 1024 * 1024 else {
                throw CommandError("Image clipboard response exceeds 32 MB.")
            }
            guard ((try? errorURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= 8192 else {
                throw CommandError("Image clipboard command failed.")
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: (try Data(contentsOf: errorURL)).prefix(2000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandError(detail.isEmpty ? "The Mac clipboard command failed (SSH exit \(process.terminationStatus))."
                : "Image clipboard: " + detail)
        }
        let data = try Data(contentsOf: outputURL)
        guard data.count <= 32 * 1024 * 1024 else { throw CommandError("Image clipboard response exceeds 32 MB.") }
        return data
    }
}
#endif
