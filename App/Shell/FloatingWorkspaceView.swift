#if os(macOS)
import CrowCore
import SwiftUI

/// The compact workspace uses the same editor, terminal and explorer as iPhone.
struct FloatingWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.crowFloatingMode) private var floating

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 80)
                Button { floating.wrappedValue = false } label: {
                    Image(systemName: "pip.exit").frame(width: 28, height: 28)
                }
                .help("Restore Window").accessibilityLabel("Restore Window")
                .accessibilityIdentifier("crow.window.restore").windowDragExcluded()
            }
            .padding(.horizontal, 8).frame(height: 36).background(CrowTheme.bg1).windowDragBackground()
            CrowDivider()
            ZStack {
                if model.compactSurface == .files || model.compactSurface == .hosts { SidebarView() }
                if model.hasWorkspace {
                    EditorAreaView()
                        .opacity(model.compactSurface == .editor ? 1 : 0)
                        .allowsHitTesting(model.compactSurface == .editor)
                        .accessibilityHidden(model.compactSurface != .editor)
                    TerminalPanelView()
                        .opacity(model.compactSurface == .terminal ? 1 : 0)
                        .allowsHitTesting(model.compactSurface == .terminal)
                        .accessibilityHidden(model.compactSurface != .terminal)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            CrowDivider()
            HStack(spacing: 4) {
                Button { model.showHosts() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up")
                        Text(title).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 36)
                        .background(CrowTheme.bg2, in: RoundedRectangle(cornerRadius: 5))
                }.accessibilityLabel("Show Workspaces")
                ForEach([CompactSurface.terminal, .editor, .files].filter { $0 != model.compactSurface }, id: \.self) { surface in
                    Button { model.compactSurface = surface } label: {
                        Image(systemName: surface == .terminal ? "terminal" : surface == .editor ? "doc.text" : "folder")
                            .frame(width: 32, height: 36)
                    }.help(surface.rawValue.capitalized)
                }
                MacSnippetButton()
                Menu {
                    if model.compactSurface == .terminal {
                        Button("New Terminal") { model.newTerminal() }
                        ForEach(Array(model.current.snapshot.terminalIDs.enumerated()), id: \.element) { index, id in
                            Button("Terminal \(index + 1)") { model.current.snapshot.selectedTerminalID = id; model.schedulePersist() }
                        }
                        Button("Close Terminal") { model.requestTerminalClose(model.current.snapshot.selectedTerminalID) }
                    } else if model.compactSurface == .editor {
                        ForEach(model.buffers) { buffer in
                            Button(buffer.title + (buffer.isDirty ? " •" : "")) { model.selectedBufferID = buffer.id }
                        }
                        Button("Save File") { model.saveSelectedBuffer() }.disabled(model.selectedBuffer == nil)
                    }
                    Divider()
                    Button("SSH Keys…") { model.sshKeysVisible = true }
                    Button("Settings…") { model.settingsVisible = true }
                } label: { Image(systemName: "square.grid.2x2").frame(width: 32, height: 36) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }.padding(8).background(CrowTheme.bg1)
        }
        .environment(\.crowPhoneLayout, true).buttonStyle(CrowButtonStyle())
        .foregroundStyle(CrowTheme.textDim).background(CrowTheme.bg0)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { if !model.hasWorkspace { model.showHosts() } }
    }
    private var title: String {
        if model.compactSurface == .hosts { return "Hosts" }
        if model.compactSurface == .editor { return model.selectedBuffer?.title ?? "Editor" }
        return model.workspaceTitle
    }
}
#endif
