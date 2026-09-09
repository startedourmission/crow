import CrowCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var entryName = ""
    @State private var renameEntry: FileEntry?
    @State private var createDirectory = false
    @State private var removeHost: SSHHost?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            CrowDivider()
            if model.sidebarPane == .hosts {
                hostsList
            } else {
                filesList
            }
        }
        .background(CrowTheme.bg1)
        .foregroundStyle(CrowTheme.text)
        .alert(renameEntry == nil ? (createDirectory ? "New Folder" : "New File") : "Rename", isPresented: $naming) {
            TextField("Name", text: $entryName)
            Button("Save") {
                if let entry = renameEntry { model.rename(entry, to: entryName) }
                else { model.createEntry(name: entryName, directory: createDirectory) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Remove SSH host?", isPresented: Binding(get: { removeHost != nil }, set: { if !$0 { removeHost = nil } }), presenting: removeHost) { host in
            Button("Remove", role: .destructive) { model.removeHost(host) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("The saved credentials will be removed from this device. Server files will not be changed.") }
    }

    private var header: some View {
        HStack {
            Text(model.sidebarPane == .hosts ? "HOSTS" : model.selectedWorkspace.name.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(CrowTheme.textDim)
            Spacer()
            if model.sidebarPane == .files {
                Button { model.refreshFiles() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Menu {
                    Button("New File…") { renameEntry = nil; createDirectory = false; entryName = ""; naming = true }
                    Button("New Folder…") { renameEntry = nil; createDirectory = true; entryName = ""; naming = true }
                    Button("Open Folder…") { model.folderImporterVisible = true }
                } label: { Image(systemName: "plus") }
                .fixedSize()
            } else { Button { model.editHost() } label: { Image(systemName: "plus") }.help("Add SSH Host") }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var filesList: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.navigateUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(model.current.snapshot.directoryPath == model.current.snapshot.rootPath)
                Text(model.current.snapshot.directoryPath).font(.system(size: 10)).lineLimit(1).truncationMode(.head)
                if model.current.isLoading { ProgressView().controlSize(.small) }
            }.padding(8)
        List(model.files, selection: Binding(
            get: { model.selectedBuffer?.path },
            set: { path in
                if let path, let entry = model.files.first(where: { $0.path == path }) {
                    model.openFile(entry)
                }
            }
        )) { entry in
            Button {
                model.openFile(entry)
            } label: {
                Label {
                    Text(entry.name)
                        .font(.system(size: 13))
                        .foregroundStyle(CrowTheme.text)
                } icon: {
                    Image(systemName: entry.isDirectory ? "folder" : icon(for: entry.name))
                        .font(.system(size: 12))
                        .foregroundStyle(CrowTheme.textDim)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rename…") { renameEntry = entry; entryName = entry.name; naming = true }
                Button("Move to Recovery Folder…", role: .destructive) { model.deleteRequest = entry }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        }
    }

    private var hostsList: some View {
        List(model.hosts) { (host: SSHHost) in
            Button {
                model.connect(host)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                        .font(.system(size: 13, weight: .medium))
                    Text("\(host.userAtHost):\(host.port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CrowTheme.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Connect") { model.connect(host) }
                Button("Edit…") { model.editHost(host) }
                Button("Remove Host…", role: .destructive) { removeHost = host }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            Text(model.hosts.isEmpty ? "Add an SSH host with +. Each host has its own files and terminal sessions." : "Credentials are stored in Keychain. Right-click or long-press a host to edit it.")
                .font(.system(size: 11))
                .foregroundStyle(CrowTheme.textDim)
                .padding(12)
        }
    }

    private func icon(for name: String) -> String {
        switch LanguageMode.infer(filename: name) {
        case .markdown: return "doc.richtext"
        case .json, .yaml, .toml, .ini: return "curlybraces"
        case .shell: return "terminal"
        default: return "doc.plaintext"
        }
    }
}
