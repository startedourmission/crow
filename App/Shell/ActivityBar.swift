import CrowCore
import SwiftUI

struct ActivityBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 4) {
            paneButton(.files, symbol: "doc.text")
            paneButton(.hosts, symbol: "network")
            paneButton(.agents, symbol: "sparkles")
            paneButton(.tmux, symbol: "rectangle.split.2x2")
            Button { model.screenRequest = ScreenRequest(id: model.selectedWorkspaceID) } label: {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 18)).crowForeground(CrowTheme.textDim)
                    .frame(width: CrowTheme.activityWidth, height: 40)
            }
            .buttonStyle(CrowButtonStyle()).windowDragExcluded()
            .help("Server Screen").accessibilityLabel("Server Screen")
            .accessibilityIdentifier("crow.window.server-screen")
            .disabled(!model.hasWorkspace || !model.selectedWorkspace.isRemote || model.selectedWorkspace.connection != .connected)
            #if os(macOS)
            MacSnippetButton(width: CrowTheme.activityWidth, height: 40)
            #else
            IPadSnippetButton()
            #endif
            Spacer()
                #if os(macOS)
                .frame(maxWidth: .infinity)
                .overlay { WindowDragRegion() }
                #endif
            Button { model.settingsVisible = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .crowForeground(CrowTheme.textDim)
                    .frame(width: CrowTheme.activityWidth, height: 40)
            }
            .buttonStyle(CrowButtonStyle())
            .windowDragExcluded()
            .help("Settings")
        }
        .padding(.vertical, 8)
        .frame(width: CrowTheme.activityWidth)
        .background(CrowTheme.bg1)
        .windowDragBackground()
    }

    private func paneButton(_ pane: SidebarPane, symbol: String) -> some View {
        Button {
            if model.sidebarPane == pane {
                model.sidebarVisible.toggle()
            } else {
                model.sidebarPane = pane
                model.sidebarVisible = true
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .crowForeground(model.sidebarPane == pane && model.sidebarVisible ? CrowTheme.accent : CrowTheme.textDim)
                .frame(width: CrowTheme.activityWidth, height: 40)
                .overlay(alignment: .leading) {
                    if model.sidebarPane == pane && model.sidebarVisible {
                        Rectangle()
                            .fill(CrowTheme.accent)
                            .frame(width: 2)
                    }
                }
        }
        .buttonStyle(CrowButtonStyle())
        .windowDragExcluded()
        .help(pane == .files ? "Files" : pane == .hosts ? "Hosts" : pane == .agents ? "Agents" : "tmux")
        .accessibilityLabel(pane == .files ? "Files" : pane == .hosts ? "Hosts" : pane == .agents ? "Agents" : "tmux")
        .accessibilityIdentifier("crow.activity." + pane.rawValue)
    }
}
