import CrowCore
import SwiftUI

struct WorkspaceSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.workspaces) { workspace in
                        workspaceChip(workspace)
                    }
                }
                .padding(.vertical, 6)
                .padding(.leading, 12)
            }

            Spacer(minLength: 0)
            Menu {
                Button("Open Folder…") { model.folderImporterVisible = true }
                Button("SSH Command…") { model.sshCommandVisible = true }
                Button("Settings…") { model.settingsVisible = true }
            } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .fixedSize().padding(.trailing, 12)
        }
        .frame(height: 40)
        .background(CrowTheme.bg1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CrowTheme.border).frame(height: 1)
        }
    }

    private func workspaceChip(_ workspace: Workspace) -> some View {
        let selected = workspace.id == model.selectedWorkspaceID
        return Button {
            model.selectWorkspace(workspace.id)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor(workspace))
                    .frame(width: 6, height: 6)
                Text(workspace.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                if workspace.isRemote {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.5)
                }
            }
            .foregroundStyle(selected ? CrowTheme.text : CrowTheme.textDim)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? CrowTheme.bg3 : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func dotColor(_ workspace: Workspace) -> Color {
        switch workspace.connection {
        case .local: return CrowTheme.accent
        case .connected: return CrowTheme.ok
        case .connecting: return CrowTheme.accent
        case .disconnected: return CrowTheme.textDim
        case .failed: return CrowTheme.danger
        }
    }
}
