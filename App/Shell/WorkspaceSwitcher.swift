import CrowCore
import SwiftUI

struct WorkspaceSwitcher: View {
    @Environment(AppModel.self) private var model

    private var title: String {
        if case .remote(let hostID, _) = model.selectedWorkspace.kind {
            return model.hosts.first { $0.id == hostID }?.hostname ?? model.selectedWorkspace.name
        }
        return model.hasWorkspace ? model.selectedWorkspace.name : "Open Vault"
    }

    var body: some View {
        Menu {
            ForEach(model.localWorkspaces) { workspace in
                Button { model.selectWorkspace(workspace.id) } label: {
                    Label(workspace.name, systemImage: workspace.id == model.selectedWorkspaceID ? "checkmark" : "folder")
                }
            }
            if !model.localWorkspaces.isEmpty { Divider() }
            Button("Open Folder…", systemImage: "folder.badge.plus") { model.folderImporterVisible = true }
            if model.hasWorkspace && !model.selectedWorkspace.isRemote {
                Divider()
                workspaceActions(model.selectedWorkspace)
            }
            if !model.localWorkspaces.isEmpty {
                Menu("Manage Vaults") {
                    ForEach(model.localWorkspaces) { workspace in
                        Menu(workspace.name) { workspaceActions(workspace) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.selectedWorkspace.isRemote ? "globe" : "folder")
                    .crowForeground(CrowTheme.textDim)
                Text(title)
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                #if os(iOS)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .crowForeground(CrowTheme.textDim)
                #endif
            }
            .crowForeground(CrowTheme.text)
            .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        #if os(macOS)
        .menuIndicator(.visible)
        #else
        .menuIndicator(.hidden)
        #endif
        .fixedSize(horizontal: false, vertical: true)
        .crowMenuHover()
        .windowDragExcluded()
        .padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: 40)
        .background(CrowTheme.bg1)
        .windowDragBackground()
        .accessibilityLabel("Switch vault")
        .accessibilityValue(title)
        .accessibilityIdentifier("crow.vault-menu")
        .contextMenu {
            if model.hasWorkspace && !model.selectedWorkspace.isRemote { workspaceActions(model.selectedWorkspace) }
        }
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
