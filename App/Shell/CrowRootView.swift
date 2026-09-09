import CrowCore
import SwiftUI

struct CrowRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
                CompactWorkspaceView()
            } else {
                RegularWorkspaceView()
            }
        }
        .background(CrowTheme.bg0)
        .tint(CrowTheme.accent)
    }
}

struct RegularWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var terminalFraction: CGFloat = 0.34

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSwitcher()
            HStack(spacing: 0) {
                ActivityBar()
                if model.sidebarVisible {
                    SidebarView()
                        .frame(width: CrowTheme.sidebarWidth)
                    Rectangle().fill(CrowTheme.border).frame(width: 1)
                }
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        EditorAreaView()
                        if model.terminalVisible {
                            ResizeHandle(fraction: $terminalFraction)
                            TerminalPanelView()
                                .frame(height: max(CrowTheme.terminalMinHeight, geo.size.height * terminalFraction))
                        }
                    }
                }
            }
            StatusBarView()
        }
        .background(CrowTheme.bg0)
    }
}

struct CompactWorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSwitcher()
            Picker("Surface", selection: Bindable(model).compactSurface) {
                Text("Files").tag(CompactSurface.files)
                Text("Editor").tag(CompactSurface.editor)
                Text("Terminal").tag(CompactSurface.terminal)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(CrowTheme.bg1)

            Group {
                switch model.compactSurface {
                case .files:
                    SidebarView()
                case .editor:
                    EditorAreaView()
                case .terminal:
                    TerminalPanelView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StatusBarView()
        }
        .background(CrowTheme.bg0)
    }
}

private struct ResizeHandle: View {
    @Binding var fraction: CGFloat

    var body: some View {
        Rectangle()
            .fill(CrowTheme.border)
            .frame(height: 6)
            .overlay(
                Capsule()
                    .fill(CrowTheme.textDim.opacity(0.5))
                    .frame(width: 36, height: 2)
            )
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta = value.translation.height / -400
                        fraction = min(0.65, max(0.18, fraction + delta))
                    }
            )
            .accessibilityLabel("Resize terminal")
    }
}
