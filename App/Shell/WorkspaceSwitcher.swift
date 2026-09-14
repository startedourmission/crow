import CrowCore
import SwiftUI

struct WorkspaceSwitcher: View {
    @Environment(AppModel.self) private var model

    private var title: String { model.hasWorkspace ? model.selectedWorkspace.name : "Workspaces" }

    var body: some View {
        Menu {
            ForEach(model.workspaces) { workspace in
                Button { model.activateWorkspace(workspace.id) } label: {
                    Label(workspace.name, systemImage: workspace.id == model.selectedWorkspaceID ? "checkmark" : workspace.isRemote ? "network" : "folder")
                }
            }
            if !model.workspaces.isEmpty { Divider() }
            Button("Manage Workspaces…", systemImage: "square.stack.3d.up") { model.showWorkspaces() }
            if model.hasWorkspace {
                Divider()
                workspaceActions(model.selectedWorkspace)
            }
            if !model.workspaces.isEmpty {
                Menu("Workspace Actions") {
                    ForEach(model.workspaces) { workspace in
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
        .accessibilityLabel("Switch workspace")
        .accessibilityValue(title)
        .accessibilityIdentifier("crow.vault-menu")
        .contextMenu {
            if model.hasWorkspace { workspaceActions(model.selectedWorkspace) }
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
