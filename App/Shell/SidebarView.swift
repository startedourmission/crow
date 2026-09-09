import CrowCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

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
    }

    private var header: some View {
        HStack {
            Text(model.sidebarPane == .hosts ? "HOSTS" : model.selectedWorkspace.name.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(CrowTheme.textDim)
            Spacer()
            if model.sidebarPane == .files {
                Button {
                    model.newUntitledBuffer()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CrowTheme.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var filesList: some View {
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
            .listRowBackground(Color.clear)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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
            .listRowBackground(Color.clear)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            Text("호스트를 열면 워크스페이스가 갈라집니다. SSH 전송은 다음 슬라이스입니다.")
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
