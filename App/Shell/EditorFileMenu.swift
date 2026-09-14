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
        Menu {
            Button("Move File…", systemImage: "folder") { moving = true }
                .accessibilityIdentifier("crow.file-move")
            Button("Download File…", systemImage: "arrow.down.to.line") { prepareDownload() }
                .accessibilityIdentifier("crow.file-download")
        } label: {
            if preparing { ProgressView().controlSize(.mini) }
            else { Image(systemName: downloaded ? "checkmark" : "ellipsis") }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
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
    private var root: String { model.states.first { $0.id == workspaceID }?.snapshot.rootPath ?? "" }
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
