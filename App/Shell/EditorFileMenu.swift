import SwiftUI
import UniformTypeIdentifiers
import CrowCore

struct FileDownload: FileDocument {
    static let sizeLimit = 50 * 1024 * 1024
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }

    static func read(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= sizeLimit else { throw FileFailure.tooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while let chunk = try file.read(upToCount: min(65_536, sizeLimit - data.count + 1)), !chunk.isEmpty {
            try Task.checkCancellation()
            data.append(chunk)
            guard data.count <= sizeLimit else { throw FileFailure.tooLarge }
        }
        return data
    }
}

#if os(macOS)
/// Launch Services supplies the installed handlers and the user's default app.
struct OpenWithMenu: View {
    @Environment(AppModel.self) private var model
    let path: String
    let workspaceID: WorkspaceID
    private var isRemote: Bool { model.states.first { $0.id == workspaceID }?.snapshot.workspace.isRemote == true }

    var body: some View {
        CrowMenu {
            let file = URL(fileURLWithPath: path)
            let type = UTType(filenameExtension: file.pathExtension) ?? .data
            let preferred = isRemote ? NSWorkspace.shared.urlForApplication(toOpen: type) : NSWorkspace.shared.urlForApplication(toOpen: file)
            let handlers = isRemote ? NSWorkspace.shared.urlsForApplications(toOpen: type) : NSWorkspace.shared.urlsForApplications(toOpen: file)
            let applications = Array(Set(handlers + (preferred.map { [$0] } ?? []))).sorted {
                if $0 == preferred { return true }
                if $1 == preferred { return false }
                return applicationName($0).localizedStandardCompare(applicationName($1)) == .orderedAscending
            }
            ForEach(applications, id: \.self) { application in
                Button { model.openFileExternally(path, workspaceID: workspaceID, application: application) } label: {
                    Label {
                        Text(applicationName(application) + (application == preferred ? " (Default)" : ""))
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: application.path)).resizable().frame(width: 16, height: 16)
                    }
                }
            }
            if !applications.isEmpty { Divider() }
            Button("Other…") { model.chooseApplication(for: path, workspaceID: workspaceID) }
            if isRemote {
                Divider()
                Text("Opens a local copy. Changes are not uploaded.")
            }
        } label: {
            Label(isRemote ? "Open Downloaded Copy With" : "Open With", systemImage: "arrow.up.forward.app")
        }.accessibilityIdentifier("crow.file.open-with")
    }

    private func applicationName(_ url: URL) -> String {
        (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }
}

extension AppModel {
    func chooseApplication(for path: String, workspaceID: WorkspaceID) {
        let panel = NSOpenPanel()
        panel.title = "Open With"; panel.prompt = "Open"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { [weak self] response in
            guard response == .OK, let application = panel.url else { return }
            self?.openFileExternally(path, workspaceID: workspaceID, application: application)
        }
    }

    func openFileExternally(_ path: String, workspaceID: WorkspaceID, application: URL) {
        guard let state = states.first(where: { $0.id == workspaceID }) else { return }
        guard !state.movingPaths.contains(path) else { report(CommandError("Wait for the file move to finish.")); return }
        let remote = state.snapshot.workspace.isRemote, connection = state.remote
        Task { @MainActor in
            var copyDirectory: URL?
            do {
                let file: URL
                if remote {
                    guard let connection, connection.isConnected else { throw FileFailure.disconnected }
                    let data: Data
                    if let buffer = state.snapshot.buffers.first(where: { $0.path == path }) {
                        data = try await downloadOpenFile(buffer.id)
                    } else { data = try await connection.readData(path, maximumSize: FileDownload.sizeLimit) }
                    guard states.contains(where: { $0 === state }), state.remote === connection,
                          !state.movingPaths.contains(path) else { throw CommandError("The remote file changed location. Try again.") }
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Crow-OpenWith-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    copyDirectory = directory
                    file = directory.appendingPathComponent((path as NSString).lastPathComponent)
                    try data.write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                } else {
                    if state.snapshot.buffers.contains(where: { $0.path == path && $0.isDirty }) {
                        throw CommandError("Save your changes in Crow before opening this file in another app.")
                    }
                    file = URL(fileURLWithPath: path)
                }
                _ = try await NSWorkspace.shared.open([file], withApplicationAt: application, configuration: .init())
                statusMessage = remote ? "Opened a local copy — changes are not uploaded to the host." : "Opened " + file.lastPathComponent
            } catch {
                if let copyDirectory { try? FileManager.default.removeItem(at: copyDirectory) }
                report(error)
            }
        }
    }
}
#endif

struct EditorFileMenu: View {
    @Environment(AppModel.self) private var model
    let buffer: OpenBuffer
    @State private var moving = false
    @State private var preparing = false
    @State private var exporting = false
    @State private var download: FileDownload?
    @State private var request: Task<Void, Never>?
    @State private var error: String?
    @State private var downloaded = false

    var body: some View {
        CrowMenu {
            #if os(macOS)
            if let state = model.locate(buffer.id)?.0 {
                OpenWithMenu(path: buffer.path, workspaceID: state.id)
                Divider()
            }
            #endif
            Button("Move File…", systemImage: "folder") { moving = true }
                .accessibilityIdentifier("crow.file-move")
            Button("Download File…", systemImage: "arrow.down.to.line") { prepareDownload() }
                .accessibilityIdentifier("crow.file-download")
        } label: {
            if preparing { ProgressView().controlSize(.mini) }
            else { Image(systemName: downloaded ? "checkmark" : "ellipsis") }
        }
        .fixedSize().buttonStyle(CrowButtonStyle())
        .disabled(preparing)
        .help(downloaded ? "File Downloaded" : "File Actions")
        .accessibilityLabel(downloaded ? "File Downloaded" : "File Actions")
        .accessibilityIdentifier("crow.file-menu")
        .windowDragExcluded()
        .sheet(isPresented: $moving) { FileMovePicker(bufferID: buffer.id).environment(model) }
        .fileExporter(isPresented: $exporting, document: download,
                      contentType: UTType(filenameExtension: (buffer.title as NSString).pathExtension) ?? .data,
                      defaultFilename: buffer.title) { result in
            download = nil
            switch result {
            case .success:
                downloaded = true
                model.statusMessage = "Downloaded \(buffer.title)"
            case .failure(let failure):
                if (failure as NSError).code != CocoaError.userCancelled.rawValue { error = failure.localizedDescription }
            }
        }
        .alert("File Action Failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .task(id: downloaded) {
            guard downloaded else { return }
            do { try await Task.sleep(for: .seconds(2)); downloaded = false } catch {}
        }
        .onDisappear { request?.cancel() }
    }

    private func prepareDownload() {
        preparing = true; error = nil; downloaded = false
        request = Task { @MainActor in
            defer { preparing = false }
            do {
                let data = try await model.downloadOpenFile(buffer.id)
                try Task.checkCancellation()
                download = FileDownload(data: data); exporting = true
            } catch is CancellationError {}
            catch FileFailure.tooLarge { error = "Downloads support files up to 50 MB." }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct FileMovePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var bufferID: BufferID? = nil
    var entry: ExplorerFileDrag? = nil
    @State private var path = ""
    @State private var workspaceRoot = ""
    @State private var folders: [FileEntry] = []
    @State private var loading = false
    @State private var moving = false
    @State private var error: String?
    @State private var request: Task<Void, Never>?
    private var workspaceID: WorkspaceID? {
        if let entry { return entry.workspaceID }
        if let bufferID { return model.locate(bufferID)?.0.id }
        return nil
    }
    private var root: String { model.states.first { $0.id == workspaceID }?.contextRootPath ?? "" }
    private var source: String? {
        if let entry { return entry.path }
        guard let bufferID, let (state, index) = model.locate(bufferID) else { return nil }
        return state.snapshot.buffers[index].path
    }
    private var atRoot: Bool {
        path == workspaceRoot
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Button { browse(root) } label: { Image(systemName: "house") }
                        .accessibilityLabel("Workspace Root")
                    Button { browse((path as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }
                        .disabled(atRoot).accessibilityLabel("Parent Folder")
                    Text(path).font(.caption).lineLimit(2).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.disabled(loading || moving)
                Text("Choose a destination inside this workspace. Unsaved edits stay open.")
                    .font(.caption).foregroundStyle(CrowTheme.textDim)
                List(folders) { folder in
                    Button { browse(folder.path) } label: {
                        HStack {
                            Label(folder.name, systemImage: "folder")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.contentShape(Rectangle())
                    }.buttonStyle(CrowButtonStyle()).disabled(moving)
                }
                .overlay {
                    if loading { ProgressView() }
                    else if folders.isEmpty && error == nil { Text("No subfolders").foregroundStyle(.secondary) }
                }
                if let error { Text(error).font(.caption).foregroundStyle(CrowTheme.danger).textSelection(.enabled) }
                HStack {
                    if moving { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Move Here") {
                        moving = true; error = nil
                        request = Task { @MainActor in
                            do {
                                if let entry { try await model.moveExplorerFile(entry, to: path) }
                                else if let bufferID { try await model.moveOpenFile(bufferID, to: path) }
                                else { throw CommandError("This item is no longer available.") }
                                dismiss()
                            }
                            catch { self.error = error.localizedDescription }
                            moving = false
                        }
                    }
                    .disabled(loading || moving || error != nil || path.isEmpty || source == nil || (source! as NSString).deletingLastPathComponent == path)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("crow.file-move-confirm")
                }
            }.padding(16)
            .navigationTitle(entry?.isDirectory == true ? "Move Folder" : "Move File")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(moving) } }
        }
        .interactiveDismissDisabled(moving)
        .onAppear { browse(root) }
        .onDisappear { if !moving { request?.cancel() } }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 500, minHeight: 380, idealHeight: 460)
        #endif
    }

    private func browse(_ destination: String) {
        request?.cancel(); loading = true; error = nil
        request = Task { @MainActor in
            defer { if !Task.isCancelled { loading = false } }
            do {
                guard let workspaceID else { throw CommandError("This workspace was removed.") }
                let result = try await model.fileMoveFolders(workspaceID: workspaceID, at: destination)
                try Task.checkCancellation()
                path = result.path; workspaceRoot = result.root; folders = result.folders.filter { folder in
                    guard let entry, entry.isDirectory else { return true }
                    return folder.path != entry.path && !folder.path.hasPrefix(entry.path + "/")
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
