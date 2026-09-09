import CrowCore
import SwiftUI
import UniformTypeIdentifiers

struct CrowRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

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
        .fileImporter(isPresented: Bindable(model).folderImporterVisible, allowedContentTypes: [.folder]) { result in
            do { model.openFolder(try result.get()) } catch { model.report(error) }
        }
        .sheet(isPresented: Bindable(model).hostEditorVisible) { HostEditorView(host: model.editingHost).environment(model) }
        .sheet(isPresented: Bindable(model).settingsVisible) { CrowSettingsView().environment(model) }
        .alert("Crow", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
        .alert("Save changes before closing?", isPresented: Binding(get: { model.closeRequest != nil }, set: { if !$0 { model.closeRequest = nil } }), presenting: model.closeRequest) { id in
            Button("Save") { Task { if await model.saveBuffer(id) { model.discardBuffer(id) } } }
            Button("Discard Changes", role: .destructive) { model.discardBuffer(id) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("File changed externally", isPresented: Binding(get: { model.conflictRequest != nil }, set: { if !$0 { model.conflictRequest = nil } }), presenting: model.conflictRequest) { id in
            Button("Overwrite", role: .destructive) { Task { await model.saveBuffer(id, overwrite: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("The original changed after you opened it. Overwrite only if you want to replace those changes with your edited text.") }
        .alert("Move to recovery folder?", isPresented: Binding(get: { model.deleteRequest != nil }, set: { if !$0 { model.deleteRequest = nil } }), presenting: model.deleteRequest) { entry in
            Button("Move", role: .destructive) { model.trash(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in Text("\(entry.name) will be moved to a hidden .crow-trash location. The recovery path will appear in the status bar.") }
        .alert("Verify SSH host key", isPresented: Binding(get: { model.hostKeyChallenge != nil }, set: { if !$0 { model.hostKeyChallenge = nil } }), presenting: model.hostKeyChallenge) { challenge in
            Button(challenge.changed ? "Replace Trusted Key" : "Trust and Connect", role: challenge.changed ? .destructive : nil) {
                model.trustHostKey(challenge)
            }
            Button("Cancel", role: .cancel) {}
        } message: { challenge in Text(challenge.localizedDescription) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resume() } else { model.suspend() }
        }
    }
}

struct RegularWorkspaceView: View {
    @Environment(AppModel.self) private var model

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
                            ResizeHandle(fraction: Bindable(model).settings.terminalFraction, totalHeight: geo.size.height)
                            TerminalPanelView()
                                .frame(height: max(CrowTheme.terminalMinHeight, geo.size.height * model.settings.terminalFraction))
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
    @Binding var fraction: Double
    let totalHeight: Double
    @State private var startingFraction: Double?

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
                        if startingFraction == nil { startingFraction = fraction }
                        let delta = -value.translation.height / max(totalHeight, 1)
                        fraction = min(0.65, max(0.18, (startingFraction ?? fraction) + delta))
                    }
                    .onEnded { _ in startingFraction = nil }
            )
            .accessibilityLabel("Resize terminal")
    }
}
