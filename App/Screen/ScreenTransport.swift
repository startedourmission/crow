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

    func open(in state: WorkspaceState, port: Int) async throws -> AsyncThrowingStream<Data, Error> {
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
            task.arguments = ["-T", "-W", "127.0.0.1:\(port)"] + spec.multiplexArguments
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
        let opened = try await Self.openChannel(ScreenSSHClient(value: client), port: port, sink: pair.continuation)
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

    nonisolated private static func openChannel(_ client: ScreenSSHClient, port: Int,
        sink: AsyncThrowingStream<Data, Error>.Continuation) async throws -> Channel {
        try await client.value.createDirectTCPIPChannel(using: .init(targetHost: "127.0.0.1", targetPort: port,
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
