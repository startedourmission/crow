import CrowCore
import SwiftUI

struct ActivityBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 4) {
            paneButton(.files, symbol: "doc.text")
            paneButton(.hosts, symbol: "network")
            Spacer()
            Button {
                model.terminalVisible.toggle()
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(model.terminalVisible ? CrowTheme.accent : CrowTheme.textDim)
                    .frame(width: CrowTheme.activityWidth, height: 40)
            }
            .buttonStyle(.plain)
            .help("Terminal")
        }
        .padding(.vertical, 8)
        .frame(width: CrowTheme.activityWidth)
        .background(CrowTheme.bg0)
        .overlay(alignment: .trailing) {
            Rectangle().fill(CrowTheme.border).frame(width: 1)
        }
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
                .foregroundStyle(model.sidebarPane == pane && model.sidebarVisible ? CrowTheme.accent : CrowTheme.textDim)
                .frame(width: CrowTheme.activityWidth, height: 40)
                .overlay(alignment: .leading) {
                    if model.sidebarPane == pane && model.sidebarVisible {
                        Rectangle()
                            .fill(CrowTheme.accent)
                            .frame(width: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(pane == .files ? "Files" : "Hosts")
    }
}
