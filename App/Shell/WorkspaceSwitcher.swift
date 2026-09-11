import CrowCore
import SwiftUI

struct WorkspaceSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.workspaces) { workspace in
                Button { model.selectWorkspace(workspace.id) } label: {
                    Label(workspace.name, systemImage: workspace.id == model.selectedWorkspaceID ? "checkmark" : (workspace.isRemote ? "network" : "folder"))
                }
            }
            Divider()
            Button("Saved SSH Hosts", systemImage: "server.rack") { model.showHosts() }
            Button("Open Folder…", systemImage: "folder.badge.plus") { model.folderImporterVisible = true }
            Button("SSH Command…", systemImage: "network") { model.sshCommandVisible = true }
            if model.hasWorkspace {
                Divider()
                workspaceActions(model.selectedWorkspace)
                Menu("Manage Vaults") {
                    ForEach(model.workspaces) { workspace in
                        Menu(workspace.name) { workspaceActions(workspace) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.hasWorkspace && model.selectedWorkspace.isRemote ? "network" : "folder")
                    .crowForeground(CrowTheme.textDim)
                Text(model.hasWorkspace ? model.selectedWorkspace.name : "Open Vault")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
            }
            .crowForeground(CrowTheme.text)
            .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize(horizontal: false, vertical: true)
        .crowMenuHover()
        .windowDragExcluded()
        .padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: 40)
        .background(CrowTheme.bg1)
        .windowDragBackground()
        .accessibilityLabel("Switch vault")
        .accessibilityIdentifier("crow.vault-menu")
        .contextMenu { if model.hasWorkspace { workspaceActions(model.selectedWorkspace) } }
    }

    @ViewBuilder private func workspaceActions(_ workspace: Workspace) -> some View {
        #if os(macOS)
        Button("Open in Finder", systemImage: "folder") { model.openWorkspaceInFinder(workspace.id) }
            .disabled(workspace.isRemote)
        #endif
        Button("New Terminal Tab", systemImage: "terminal") { model.newTerminal(inWorkspace: workspace.id) }
        Button("Remove from List…", systemImage: "trash", role: .destructive) { model.requestWorkspaceRemoval(workspace.id) }
    }
}
