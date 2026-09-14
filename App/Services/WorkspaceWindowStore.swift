#if os(macOS)
import SwiftUI
import CrowCore

private struct CrowWindowModelKey: FocusedValueKey { typealias Value = AppModel }
extension FocusedValues {
    var crowWindowModel: AppModel? {
        get { self[CrowWindowModelKey.self] }
        set { self[CrowWindowModelKey.self] = newValue }
    }
}

struct ScreenWindowID: Codable, Hashable {
    let windowID: UUID
    let workspaceID: WorkspaceID
}

/// Runtime state and drafts belong to a window, including its SSH connections.
@MainActor @Observable
final class WorkspaceWindowStore {
    private(set) var models: [UUID: AppModel] = [:]
    private(set) var activeID: UUID?
    let directory: URL
    let legacySessionURL: URL
    private let vaultURL: URL?
    var activeModel: AppModel? { activeID.flatMap { models[$0] } }

    init(directory: URL? = nil, vaultURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let root = directory ?? support.appendingPathComponent("Crow", isDirectory: true)
        self.directory = root.appendingPathComponent("Windows", isDirectory: true)
        legacySessionURL = root.appendingPathComponent("session-v1.json")
        self.vaultURL = vaultURL
    }

    func model(for id: UUID) -> AppModel? { models[id] }

    func open(_ id: UUID) -> AppModel {
        if let existing = models[id] { return existing }
        let sessionURL = directory.appendingPathComponent(id.uuidString + ".json")
        var preparationError: Error?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: sessionURL.path) {
                if let source = activeModel ?? models.values.first {
                    var seed = source.sessionSnapshot
                    seed.workspaces = seed.workspaces.map { previous in
                        var fresh = WorkspaceSnapshot(workspace: previous.workspace, rootPath: previous.rootPath, bookmark: previous.bookmark)
                        if fresh.workspace.isRemote { fresh.workspace.connection = .disconnected }
                        fresh.terminalIDs = []; fresh.selectedTerminalID = nil
                        fresh.layout = WorkspaceLayout(files: [], selectedFile: nil, terminals: [], selectedTerminal: nil)
                        fresh.layout?.open(.start(UUID()))
                        return fresh
                    }
                    try TextFiles.saveSession(seed, to: sessionURL)
                } else if FileManager.default.fileExists(atPath: legacySessionURL.path) {
                    // Preserve existing users' full session, including unsaved drafts.
                    try FileManager.default.copyItem(at: legacySessionURL, to: sessionURL)
                }
            }
        } catch { preparationError = error }
        let model = AppModel(vaultURL: vaultURL, sessionURL: sessionURL, windowID: id)
        models[id] = model
        if activeID == nil { activeID = id }
        if let preparationError {
            model.errorMessage = "Could not prepare this window’s session: \(preparationError.localizedDescription)"
        } else {
            model.onPersist = { [weak self, weak model] snapshot in
                guard let self, let model, self.activeID == id else { return }
                // A fallback for launching without macOS window restoration. Every
                // window still keeps its own authoritative session file above.
                do { try TextFiles.saveSession(snapshot, to: self.legacySessionURL) }
                catch { model.report(error) }
            }
        }
        return model
    }

    func activate(_ id: UUID) { if models[id] != nil { activeID = id } }

    func close(_ id: UUID) {
        guard let model = models[id] else { return }
        model.shutdown()
        model.onPersist = nil
        models.removeValue(forKey: id)
        if activeID == id { activeID = models.keys.first }
    }

    func shutdown() {
        for model in models.values { model.shutdown(); model.onPersist = nil }
        models.removeAll(); activeID = nil
    }
}

struct CrowWorkspaceWindow: View {
    let windows: WorkspaceWindowStore
    @SceneStorage("crow.workspace-window-id") private var savedID = ""
    @State private var model: AppModel?

    var body: some View {
        Group {
            if let model {
                CrowMacSceneView(model: model,
                    onActivate: { windows.activate(model.windowID) },
                    onClose: { windows.close(model.windowID) })
                    .focusedSceneValue(\.crowWindowModel, model)
            } else { ProgressView().frame(minWidth: 640, minHeight: 400) }
        }
        .task {
            guard model == nil else { return }
            let id = UUID(uuidString: savedID) ?? UUID()
            savedID = id.uuidString
            model = windows.open(id)
        }
    }
}
#endif
