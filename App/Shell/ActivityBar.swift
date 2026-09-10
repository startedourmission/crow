import CrowCore
import SwiftUI

struct ActivityBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 4) {
            paneButton(.files, symbol: "doc.text")
            paneButton(.hosts, symbol: "network")
            Spacer()
                #if os(macOS)
                .frame(maxWidth: .infinity)
                .overlay { WindowDragRegion() }
                #endif
            Button {
                model.terminalVisible.toggle()
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 18, weight: .regular))
                    .crowForeground(model.terminalVisible ? CrowTheme.accent : CrowTheme.textDim)
                    .frame(width: CrowTheme.activityWidth, height: 40)
            }
            .buttonStyle(CrowButtonStyle())
            .windowDragExcluded()
            .help("Terminal")
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
        .help(pane == .files ? "Files" : "Hosts")
    }
}
