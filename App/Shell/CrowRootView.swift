import CrowCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

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
        .sheet(isPresented: Bindable(model).hostEditorVisible, onDismiss: {
            model.finishHostEditorDismissal()
        }) { HostEditorView(host: model.editingHost).environment(model) }
        .sheet(isPresented: Bindable(model).settingsVisible) { CrowSettingsView().environment(model) }
        .sheet(isPresented: Bindable(model).sshCommandVisible, onDismiss: {
            if model.pendingHostEditor { model.pendingHostEditor = false; model.hostEditorVisible = true }
            if let pending = model.pendingCredentialRequest { model.pendingCredentialRequest = nil; model.credentialRequest = pending }
            #if os(macOS)
            if model.selectedWorkspace.isRemote, let id = model.current.snapshot.selectedTerminalID,
               let session = model.current.terminals[id] { session.view.window?.makeFirstResponder(session.view) }
            #endif
        }) { SSHCommandView().environment(model) }
        .sheet(item: Bindable(model).credentialRequest) { host in SSHPasswordView(host: host).environment(model) }
        .alert("Crow", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
        .alert("Save changes before closing?", isPresented: Binding(get: { model.closeRequest != nil }, set: { if !$0 { model.closeRequest = nil } }), presenting: model.closeRequest) { id in
            Button("Save") { Task { if await model.saveBuffer(id) { model.discardBuffer(id) } } }
            Button("Discard Changes", role: .destructive) { model.discardBuffer(id) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Close this terminal?", isPresented: Binding(
            get: { model.terminalCloseRequest != nil }, set: { if !$0 { model.terminalCloseRequest = nil } }),
            presenting: model.terminalCloseRequest) { id in
                Button("Close Terminal", role: .destructive) { model.closeTerminal(id) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("The shell and its running commands will be terminated.") }
        .alert("Remove vault from list?", isPresented: Binding(
            get: { model.workspaceRemovalRequest != nil },
            set: { if !$0 { model.workspaceRemovalRequest = nil } }), presenting: model.workspaceRemovalRequest) { id in
                let dirty = model.states.first { $0.id == id }?.snapshot.buffers.contains(where: \.isDirty) == true
                if dirty {
                    Button("Save and Remove") { Task { await model.saveAndRemoveWorkspace(id) } }
                }
                Button(dirty ? "Discard Changes and Remove" : "Remove", role: .destructive) {
                    model.removeWorkspace(id, discardChanges: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: { id in
                let name = model.states.first { $0.id == id }?.snapshot.workspace.name ?? "This vault"
                Text("\(name) will be removed from the list and its terminal sessions will end. Folders and saved files will not be deleted.")
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
        .buttonStyle(CrowButtonStyle(kind: .filled))
    }
}

struct RegularWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("crow.sidebarWidth") private var sidebarWidth = Double(CrowTheme.sidebarWidth)
    @State private var sidebarDragStart: CGFloat?
    @State private var liveSidebarWidth: CGFloat?
    @AppStorage("crow.inspectorWidth") private var savedInspectorWidth = 260.0
    @State private var inspectorDragStart: CGFloat?
    @State private var liveInspectorWidth: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            #if !os(macOS)
            WorkspaceSwitcher()
            #endif
            GeometryReader { workspaceGeometry in
              let inspectorWidth = min(max(200, liveInspectorWidth ?? savedInspectorWidth), max(200, workspaceGeometry.size.width * 0.35))
              #if os(macOS)
              let sidebarAvailable = workspaceGeometry.size.width - (model.inspectorVisible ? inspectorWidth + 6 : 0)
              #else
              let sidebarAvailable = workspaceGeometry.size.width
              #endif
              HStack(spacing: 0) {
                ActivityBar()
                    #if os(macOS)
                    .padding(.top, 40)
                    .background(CrowTheme.bg1)
                    .windowDragBackground()
                    .overlay(alignment: .top) { WindowDragRegion().frame(height: 12) }
                    .overlay(alignment: .top) {
                        CrowDivider().padding(.top, 40).allowsHitTesting(false)
                    }
                    #endif
                if model.sidebarVisible {
                    VStack(spacing: 0) {
                        #if os(macOS)
                        SidebarTopBar()
                        CrowDivider()
                        #endif
                        SidebarView()
                        #if os(macOS)
                        CrowDivider()
                        WorkspaceSwitcher()
                        #endif
                    }
                        .frame(width: SplitSizing.sidebarWidth(liveSidebarWidth ?? sidebarWidth, available: sidebarAvailable))
                        .background(CrowTheme.bg1)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(CrowTheme.border).frame(width: 1)
                                #if os(macOS)
                                .padding(.top, 40)
                                #endif
                                .allowsHitTesting(false)
                        }
                    ResizeHandle(axis: .horizontal, label: "Resize file explorer", onDrag: { translation in
                        if sidebarDragStart == nil {
                            sidebarDragStart = SplitSizing.sidebarWidth(sidebarWidth, available: sidebarAvailable)
                        }
                        liveSidebarWidth = SplitSizing.sidebarWidth((sidebarDragStart ?? sidebarWidth) + translation,
                            available: sidebarAvailable)
                    }, onEnd: {
                        if let width = liveSidebarWidth { sidebarWidth = width }
                        sidebarDragStart = nil; liveSidebarWidth = nil
                    })
                }
                VStack(spacing: 0) {
                    if !model.hasWorkspace { EmptyWorkspaceView() }
                    else { WorkspaceAreaView() }
                }
                #if os(macOS)
                .overlay(alignment: .topLeading) {
                    if !model.sidebarVisible {
                        SidebarTopBar(height: 36).frame(width: SidebarTopBar.collapsedWidth)
                    }
                }
                #endif
                #if os(macOS)
                if model.inspectorVisible {
                    ResizeHandle(axis: .horizontal, label: "Resize right sidebar", onDrag: { translation in
                        if inspectorDragStart == nil { inspectorDragStart = inspectorWidth }
                        liveInspectorWidth = min(max(200, (inspectorDragStart ?? inspectorWidth) - translation),
                            max(200, workspaceGeometry.size.width * 0.35))
                    }, onEnd: {
                        if let width = liveInspectorWidth { savedInspectorWidth = width }
                        inspectorDragStart = nil; liveInspectorWidth = nil
                    })
                    InspectorPanel().frame(width: inspectorWidth)
                }
                #endif
              }
              .transaction { $0.animation = nil }
            }
            StatusBarView()
        }
        .background(CrowTheme.bg0)
        #if os(macOS)
        .ignoresSafeArea(.container, edges: .top)
        #endif
    }
}

struct CompactWorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSwitcher()
            Picker("Surface", selection: Bindable(model).compactSurface) {
                Text("Hosts").tag(CompactSurface.hosts)
                Text("Files").tag(CompactSurface.files)
                Text("Editor").tag(CompactSurface.editor)
                Text("Terminal").tag(CompactSurface.terminal)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(CrowTheme.bg1)

            Group {
                if !model.hasWorkspace && model.compactSurface != .hosts {
                    EmptyWorkspaceView()
                } else {
                    switch model.compactSurface {
                    case .hosts, .files:
                        SidebarView()
                    case .editor:
                        EditorAreaView()
                    case .terminal:
                        TerminalPanelView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StatusBarView()
                .contextMenu { Button("Settings…") { model.settingsVisible = true } }
        }
        .background(CrowTheme.bg0)
    }
}

private struct EmptyWorkspaceView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 16) {
            Text("Open a folder to get started").crowForeground(CrowTheme.textDim)
            Button("Open Folder…") { model.folderImporterVisible = true }
            Button("SSH Command…") { model.sshCommandVisible = true }
            Button("Settings…") { model.settingsVisible = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum SplitSizing {
    static func sidebarWidth(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        min(max(180, proposed), max(180, min(520, available - CrowTheme.activityWidth - 326)))
    }
    static func terminalHeight(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        let maximum = max(0, available - 126) // editor + divider
        return min(max(min(CrowTheme.terminalMinHeight, maximum), proposed), maximum)
    }
}

struct ResizeHandle: View {
    let axis: Axis
    let label: String
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    var body: some View {
        ZStack {
            CrowTheme.bg1
            Rectangle().fill(CrowTheme.border)
                .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            #if os(macOS)
            NativeResizeHandle(axis: axis, label: label, onDrag: onDrag, onEnd: onEnd)
            #else
            Color.clear.contentShape(Rectangle()).gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        onDrag(axis == .horizontal ? value.translation.width : value.translation.height)
                    }
                    .onEnded { _ in onEnd() }
            )
            #endif
        }
        .frame(width: axis == .horizontal ? 6 : nil, height: axis == .vertical ? 6 : nil)
        .accessibilityLabel(label)
    }
}

#if os(macOS)
private struct NativeResizeHandle: NSViewRepresentable {
    let axis: Axis
    let label: String
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    func makeNSView(context: Context) -> ResizeHandleView { ResizeHandleView() }
    func updateNSView(_ view: ResizeHandleView, context: Context) {
        view.axis = axis; view.onDrag = onDrag; view.onEnd = onEnd
        view.setAccessibilityLabel(label)
        view.setAccessibilityIdentifier(axis == .horizontal ? "crow.resize.sidebar" : "crow.resize.terminal")
    }
}

final class ResizeHandleView: NSView {
    var axis: Axis = .vertical
    var onDrag: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}
    private var dragOrigin: NSPoint?
    private var cursorTracking: NSTrackingArea?
    var resizeCursor: NSCursor { axis == .horizontal ? .resizeLeftRight : .resizeUpDown }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: resizeCursor) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .cursorUpdate, .inVisibleRect], owner: self)
        addTrackingArea(area); cursorTracking = area
    }
    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }
    override func mouseDown(with event: NSEvent) {
        // Screen coordinates stay fixed while this divider moves under the pointer.
        dragOrigin = window?.convertPoint(toScreen: event.locationInWindow)
        resizeCursor.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, let point = window?.convertPoint(toScreen: event.locationInWindow) else { return }
        resizeCursor.set()
        onDrag(axis == .horizontal ? point.x - dragOrigin.x : dragOrigin.y - point.y)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        mouseDragged(with: event)
        dragOrigin = nil; onEnd()
        NSCursor.arrow.set()
        window?.invalidateCursorRects(for: self)
    }
}
#endif
