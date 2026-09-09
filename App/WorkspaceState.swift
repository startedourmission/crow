import CrowCore
import Foundation
import Observation

@MainActor @Observable
final class WorkspaceState: Identifiable {
    var snapshot: WorkspaceSnapshot
    var files: [FileEntry] = []
    var isLoading = false
    let id: WorkspaceID
    @ObservationIgnored var remote: RemoteConnection?
    @ObservationIgnored var terminals: [UUID: TerminalSession] = [:]
    @ObservationIgnored var accessURL: URL?
    @ObservationIgnored var refreshGeneration = UUID()
    @ObservationIgnored var connectionTask: Task<Void, Never>?
    init(_ snapshot: WorkspaceSnapshot) { self.snapshot = snapshot; id = snapshot.workspace.id }
    func stopTerminals() {
        terminals.values.forEach { $0.stop() }
        terminals.removeAll()
    }
}
