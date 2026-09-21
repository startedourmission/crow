import CrowCore
import SwiftUI

struct ActivityBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 4) {
            paneButton(.workspaces, symbol: "square.stack.3d.up")
            paneButton(.files, symbol: "folder")
            paneButton(.git, symbol: "")
            paneButton(.automation, symbol: "clock")
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
            paneButton(.crowmap, symbol: "point.3.connected.trianglepath.dotted")
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
        let selected = pane == .crowmap ? model.crowmapPanel.visible : model.sidebarPane == pane && model.sidebarVisible
        return Button {
            if pane == .crowmap { model.showCrowmap(); return }
            if model.sidebarPane == pane {
                model.sidebarVisible.toggle()
            } else {
                model.sidebarPane = pane
                model.sidebarVisible = true
            }
        } label: {
            Group {
                if pane == .crowmap { CrowmapIcon().frame(width: 21, height: 21) }
                else if pane == .git { GitBranchIcon(selected: model.sidebarPane == pane && model.sidebarVisible) }
                else { Image(systemName: symbol) }
            }
                .font(.system(size: 18, weight: .regular))
                .crowForeground(selected ? CrowTheme.accent : CrowTheme.textDim)
                .frame(width: CrowTheme.activityWidth, height: 40)
                .contentShape(Rectangle())
                .overlay(alignment: .leading) {
                    if selected {
                        Rectangle()
                            .fill(CrowTheme.accent)
                            .frame(width: 2)
                    }
                }
        }
        .buttonStyle(CrowButtonStyle())
        .windowDragExcluded()
        .help(pane == .crowmap ? "Crowmap" : pane == .files ? "Files" : pane == .git ? "Git" : pane == .automation ? "Automations" : "Workspaces")
        .accessibilityLabel(pane == .crowmap ? "Crowmap" : pane == .files ? "Files" : pane == .git ? "Git" : pane == .automation ? "Automations" : "Workspaces")
        .accessibilityIdentifier("crow.activity." + pane.rawValue)
    }
}

/// Paired folded arrows, shared by the activity bar and Crowmap file rows.
struct CrowmapIcon: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let scale = min(geometry.size.width, geometry.size.height) / 24
                let points: [CGPoint] = [.init(x: 3, y: 3), .init(x: 12, y: 12), .init(x: 3, y: 21), .init(x: 11, y: 21), .init(x: 21, y: 12), .init(x: 11, y: 3)]
                path.move(to: .init(x: points[0].x * scale, y: points[0].y * scale))
                for point in points.dropFirst() { path.addLine(to: .init(x: point.x * scale, y: point.y * scale)) }
                path.closeSubpath()
            }.stroke(style: StrokeStyle(lineWidth: max(1.2, geometry.size.width / 12), lineCap: .round, lineJoin: .round))
        }
    }
}
