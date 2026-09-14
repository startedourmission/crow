import Foundation
import Network
import CrowCore

/// Browser-owned loopback TCP forwards, including HTTPS and WebSocket traffic.
@MainActor final class BrowserTunnel {
    private struct Forward {
        let listener: NWListener
        let host: String
        let remotePort: Int
        let localPort: Int
    }
    private var forwards: [Forward] = []
    private var pending: [UUID: (NWListener, CheckedContinuation<Int, Error>)] = [:]
    private var peers: [UUID: BrowserTunnelPeer] = [:]
    private(set) var acceptedConnections = 0
    var localPorts: [Int] { forwards.map(\.localPort) }
    func forward(_ url: URL, in workspace: WorkspaceState) async throws -> URL {
        guard let host = url.host, BrowserAddress.isLoopback(host) else { return url }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let localPort: Int
        if let existing = forwards.first(where: { $0.remotePort == port && $0.host == host }) {
            localPort = existing.localPort
        } else {
            guard forwards.count < 32 else { throw CommandError("This browser has opened 32 forwarded ports. Close the tab to reset them.") }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters), id = UUID()
            listener.newConnectionHandler = { [weak self, weak workspace, weak listener] connection in
                Task { @MainActor in
                    guard let self, let workspace, self.forwards.contains(where: { $0.listener === listener }), self.peers.count < 64 else { connection.cancel(); return }
                    let id = UUID(), peer = BrowserTunnelPeer(connection: connection)
                    self.acceptedConnections += 1; self.peers[id] = peer
                    peer.start(in: workspace, host: host.contains(":") ? "::1" : "127.0.0.1", port: port) { [weak self] in self?.peers.removeValue(forKey: id) }
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, let (_, continuation) = self.pending[id] else { return }
                    switch state {
                    case .ready:
                        guard let localPort = listener.port.map({ Int($0.rawValue) }) else { return }
                        self.pending.removeValue(forKey: id)
                        self.forwards.append(Forward(listener: listener, host: host, remotePort: port, localPort: localPort))
                        continuation.resume(returning: localPort)
                    case .failed(let error): self.pending.removeValue(forKey: id); listener.cancel(); continuation.resume(throwing: error)
                    case .cancelled: self.pending.removeValue(forKey: id); continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
            }
            localPort = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in pending[id] = (listener, continuation); listener.start(queue: .main) }
            } onCancel: { listener.cancel() }
        }
        try Task.checkCancellation()
        var result = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        result.host = "127.0.0.1"; result.port = localPort
        return result.url!
    }
    func original(_ url: URL) -> URL {
        guard url.host == "127.0.0.1", let forward = forwards.first(where: { $0.localPort == url.port }),
              var result = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        result.host = forward.host; result.port = forward.remotePort
        return result.url ?? url
    }
    func stop() {
        let old = forwards; forwards.removeAll(); old.forEach { $0.listener.cancel() }
        let waiting = pending; pending.removeAll()
        waiting.values.forEach { listener, continuation in listener.cancel(); continuation.resume(throwing: CancellationError()) }
        let connections = peers; peers.removeAll(); connections.values.forEach { $0.close() }
    }
}

@MainActor private final class BrowserTunnelPeer {
    let connection: NWConnection
    let transport = ScreenTransport()
    var task: Task<Void, Never>?
    var upstream: Task<Void, Never>?
    var watchdog: Task<Void, Never>?
    init(connection: NWConnection) { self.connection = connection }
    func start(in workspace: WorkspaceState, host: String, port: Int, completion: @escaping () -> Void) {
        connection.start(queue: .main)
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { self?.close() }
        }
        task = Task {
            defer { close(); completion() }
            do {
                let inbound = try await transport.open(in: workspace, port: port, host: host)
                try Task.checkCancellation()
                watchdog?.cancel(); watchdog = nil
                upstream = Task {
                    defer { close() }
                    do {
                        while !Task.isCancelled {
                            let data = try await receive()
                            if data.isEmpty { break }
                            try await transport.send(data)
                        }
                    } catch { }
                }
                for try await data in inbound { try Task.checkCancellation(); try await send(data) }
            } catch { }
        }
    }
    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }
    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func close() {
        watchdog?.cancel(); watchdog = nil; task?.cancel(); task = nil; upstream?.cancel(); upstream = nil
        connection.cancel(); transport.close()
    }
}
