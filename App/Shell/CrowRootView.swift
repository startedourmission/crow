import CrowCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct CrowRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.crowFloatingMode) private var floating
    #endif

    var body: some View {
        Group {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone || sizeClass == .compact {
                CompactWorkspaceView()
            } else {
                RegularWorkspaceView()
            }
            #else
            if floating.wrappedValue { FloatingWorkspaceView() }
            else { RegularWorkspaceView() }
            #endif
        }
        .background(CrowTheme.bg0)
        #if os(iOS)
        .environment(\.keyboardBarItems, model.settings.effectiveKeyboardBarItems)
        #endif
        .tint(CrowTheme.accent)
        .fileImporter(isPresented: Bindable(model).folderImporterVisible, allowedContentTypes: [.folder]) { result in
            do { model.openFolder(try result.get()) } catch { model.report(error) }
        }
        .sheet(isPresented: Bindable(model).hostEditorVisible, onDismiss: {
            model.finishHostEditorDismissal()
        }) { HostEditorView(host: model.editingHost).environment(model) }
        .sheet(isPresented: Bindable(model).settingsVisible) { CrowSettingsView().environment(model) }
        #if os(iOS)
        .fullScreenCover(item: Bindable(model).screenRequest) { request in
            RemoteScreenView(workspaceID: request.id).environment(model)
        }
        #else
        .sheet(item: Bindable(model).screenRequest) { request in
            RemoteScreenView(workspaceID: request.id).environment(model)
        }
        #endif
        .sheet(isPresented: Bindable(model).sshKeysVisible) { SSHKeysView().environment(model) }
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
            if phase == .active { model.resume() } else if phase == .background { model.suspend() }
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
            GeometryReader { workspaceGeometry in
              let inspectorWidth = min(max(200, liveInspectorWidth ?? savedInspectorWidth), max(200, workspaceGeometry.size.width * 0.35))
              let sidebarAvailable = workspaceGeometry.size.width - (model.inspectorVisible ? inspectorWidth + ResizeHandle.thickness : 0)
              HStack(spacing: 0) {
                ActivityBar()
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(CrowTheme.border).frame(width: 1).allowsHitTesting(false)
                    }
                    .padding(.top, SidebarTopBar.height)
                    .background(CrowTheme.bg1)
                    .windowDragBackground()
                    #if os(macOS)
                    .overlay(alignment: .top) { WindowDragRegion().frame(height: 12) }
                    #endif
                    .overlay(alignment: .top) {
                        CrowDivider().padding(.top, SidebarTopBar.height).allowsHitTesting(false)
                    }
                if model.sidebarVisible {
                    VStack(spacing: 0) {
                        SidebarTopBar()
                        CrowDivider()
                        SidebarView()
                        CrowDivider()
                        WorkspaceSwitcher()
                    }
                        .frame(width: SplitSizing.sidebarWidth(liveSidebarWidth ?? sidebarWidth, available: sidebarAvailable))
                        .background(CrowTheme.bg1)
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
                .overlay(alignment: .topLeading) {
                    if !model.sidebarVisible {
                        SidebarTopBar().frame(width: SidebarTopBar.collapsedWidth)
                    }
                }
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
              }
              .transaction { $0.animation = nil }
            }
            StatusBarView()
        }
        .background(CrowTheme.bg0)
        // The regular workspace owns the top row, just like the Mac title/tab bar.
        .ignoresSafeArea(.container, edges: .top)
        #if os(iOS)
        .statusBarHidden(true)
        #endif
    }
}

private struct CrowPhoneLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var crowPhoneLayout: Bool {
        get { self[CrowPhoneLayoutKey.self] }
        set { self[CrowPhoneLayoutKey.self] = newValue }
    }
}

#if os(iOS)
/// Keeps keyboard restoration scoped to the input currently displayed in this workspace.
@MainActor final class PhoneKeyboardFocus {
    private final class Input {
        weak var view: UIView?
        var focus: (() -> Void)?
        init(view: UIView, focus: (() -> Void)?) { self.view = view; self.focus = focus }
    }
    private var inputs: [CompactSurface: Input] = [:]

    func register(_ view: UIView, surface: CompactSurface, focus: (() -> Void)? = nil) {
        inputs[surface] = Input(view: view, focus: focus)
    }

    @discardableResult func show(for surface: CompactSurface) -> Bool {
        guard let input = inputs[surface], let view = input.view, view.window != nil else { return false }
        if let focus = input.focus { focus(); return true }
        return view.becomeFirstResponder()
    }

    @discardableResult func insert(_ text: String, for surface: CompactSurface) -> Bool {
        guard let view = inputs[surface]?.view, view.window != nil, let target = view as? any SnippetInput else { return false }
        target.insertSnippet(text); return true
    }

    func transition(from previous: CompactSurface, to next: CompactSurface) {
        guard let view = inputs[previous]?.view, containsFirstResponder(view) else { return }
        // Both input views remain mounted, so UIKit can transfer focus without
        // dismissing and presenting the keyboard between document and shell.
        if (next == .editor || next == .terminal), show(for: next) { return }
        view.endEditing(true)
    }

    private func containsFirstResponder(_ view: UIView) -> Bool {
        view.isFirstResponder || view.subviews.contains(where: containsFirstResponder)
    }
}

private struct PhoneKeyboardFocusKey: EnvironmentKey {
    static let defaultValue: PhoneKeyboardFocus? = nil
}

extension EnvironmentValues {
    var phoneKeyboardFocus: PhoneKeyboardFocus? {
        get { self[PhoneKeyboardFocusKey.self] }
        set { self[PhoneKeyboardFocusKey.self] = newValue }
    }
}

struct CompactWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State var keyboard = PhoneKeyboardFocus()

    var body: some View {
        Group {
            if !model.hasWorkspace && model.compactSurface != .hosts {
                EmptyWorkspaceView()
            } else {
                ZStack {
                    if model.compactSurface == .hosts || model.compactSurface == .files {
                        SidebarView()
                    }
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
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.crowPhoneLayout, true)
        .background(CrowTheme.bg0)
        .safeAreaInset(edge: .bottom, spacing: 0) { PhoneWorkspaceBar() }
        .environment(\.phoneKeyboardFocus, keyboard)
        .onChange(of: model.compactSurface) { previous, next in
            keyboard.transition(from: previous, to: next)
        }
    }
}

/// One thumb-reachable bar above the keyboard; the work area has no app header.
private struct PhoneWorkspaceBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.phoneKeyboardFocus) private var keyboard
    @State private var keyboardVisible = false
    @State private var showingSnippets = false
    @State private var snippetSurface: CompactSurface = .editor
    @State private var restoreSnippetKeyboard = false
    @State private var showingTabs = false
    @State private var restoreTabsKeyboard = false
    @State private var copyToast: (id: UUID, message: String)?

    private var title: String {
        switch model.compactSurface {
        case .hosts: return "Hosts"
        case .editor: return model.selectedBuffer.map { $0.title + ($0.isDirty ? " •" : "") } ?? "Editor"
        case .files, .terminal:
            if case .remote(let id, _) = model.selectedWorkspace.kind,
               let host = model.hosts.first(where: { $0.id == id }) { return host.hostname }
            return model.hasWorkspace ? model.selectedWorkspace.name : "Crow"
        }
    }
    private var symbol: String {
        switch model.compactSurface {
        case .hosts: "server.rack"
        case .files: "folder"
        case .editor: "doc.text"
        case .terminal: "terminal"
        }
    }
    private var canClose: Bool {
        model.compactSurface == .editor ? model.selectedBufferID != nil
            : model.compactSurface == .terminal && model.current.snapshot.selectedTerminalID != nil
    }

    private var titleCopyValue: (text: String, label: String)? {
        switch model.compactSurface {
        case .editor:
            guard let buffer = model.selectedBuffer else { return nil }
            return (buffer.path, "Copy Absolute Path")
        case .terminal:
            guard case .remote(let id, _) = model.selectedWorkspace.kind,
                  let host = model.hosts.first(where: { $0.id == id }) else { return nil }
            return (host.hostname, "Copy Server Address")
        case .files, .hosts:
            return nil
        }
    }

    private func copyTitleValue() {
        guard let value = titleCopyValue, !value.text.isEmpty else { return }
        UIPasteboard.general.string = value.text
        let message = model.compactSurface == .editor ? "Path copied" : "Address copied"
        copyToast = (UUID(), message)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.35)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private var otherSurfaces: [CompactSurface] {
        [.terminal, .editor, .files].filter { $0 != model.compactSurface }
    }
    private var canShowKeyboard: Bool {
        switch model.compactSurface {
        case .terminal: return model.hasWorkspace && model.current.snapshot.selectedTerminalID != nil
        case .editor: return model.selectedBuffer != nil
        case .hosts, .files: return false
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                Button { model.showHosts() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: symbol).font(.system(size: 17))
                        Text(title).font(.system(size: 14, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 12).padding(.trailing, canClose ? 0 : 12)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Show Hosts and Workspaces")
                .accessibilityIdentifier("crow.phone.hosts")
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.4).exclusively(before: TapGesture())
                        .onEnded { gesture in
                            switch gesture {
                            case .first(true): copyTitleValue()
                            case .second: model.showHosts()
                            default: break
                            }
                        }
                )
                .accessibilityActions {
                    if let value = titleCopyValue {
                        Button(value.label, action: copyTitleValue)
                    }
                }
                if canClose {
                    Button {
                        if model.compactSurface == .editor { model.saveSelectedBuffer() }
                        else { model.terminalCloseRequest = model.current.snapshot.selectedTerminalID }
                    } label: {
                        Group {
                            if model.compactSurface == .editor {
                                SaveDiskIcon().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                    .frame(width: 17, height: 17)
                            } else { Image(systemName: "xmark.circle").font(.system(size: 16)) }
                        }.frame(width: 36, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel(model.compactSurface == .editor ? "Save File" : "Close Terminal")
                    .accessibilityIdentifier(model.compactSurface == .editor ? "crow.phone.save" : "crow.phone.close-terminal")
                }
            }
            .background(CrowTheme.bg2, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityIdentifier("crow.phone.session")

            ForEach(otherSurfaces, id: \.self) { surfaceButton($0) }
            Button {
                snippetSurface = model.compactSurface; restoreSnippetKeyboard = keyboardVisible
                showingSnippets = true
            } label: { controlIcon("text.badge.plus") }
                .accessibilityLabel("Snippets").accessibilityIdentifier("crow.phone.snippets")
                .popover(isPresented: $showingSnippets) {
                    SnippetsView(onInsert: canShowKeyboard ? { text in _ = keyboard?.insert(text, for: snippetSurface) } : nil)
                        .environment(model).frame(width: 320, height: 420)
                        .presentationCompactAdaptation(.popover)
                        .onDisappear { if restoreSnippetKeyboard { keyboard?.show(for: snippetSurface) } }
                }
            if canShowKeyboard && !keyboardVisible {
                Button { keyboard?.show(for: model.compactSurface) } label: { controlIcon("keyboard") }
                    .accessibilityLabel("Show Keyboard").accessibilityIdentifier("crow.phone.keyboard")
            } else {
                Menu {
                    sessionMenu
                    generalMenu
                    if keyboardVisible {
                        Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down", action: hideKeyboard)
                    }
                } label: { controlIcon("square.grid.2x2") }
                    .accessibilityLabel("Session and Settings").accessibilityIdentifier("crow.phone.screens")
            }
        }
        .buttonStyle(CrowButtonStyle())
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(CrowTheme.accent)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(CrowTheme.bg1)
        .overlay(alignment: .top) { CrowDivider().allowsHitTesting(false) }
        .overlay(alignment: .top) {
            if let toast = copyToast {
                Label(toast.message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CrowTheme.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(CrowTheme.bg3, in: RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(CrowTheme.border) }
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .fixedSize().padding(.bottom, 8)
                    .alignmentGuide(.top) { $0[.bottom] }
                    .allowsHitTesting(false).accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: copyToast != nil)
        .task(id: copyToast?.id) {
            guard copyToast != nil else { return }
            do { try await Task.sleep(for: .seconds(1.5)) }
            catch { return }
            copyToast = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .accessibilityIdentifier("crow.phone.navigation")
        .sheet(isPresented: $showingTabs, onDismiss: {
            if restoreTabsKeyboard { keyboard?.show(for: model.compactSurface) }
        }) {
            WorkspaceTabsView().environment(model).presentationDetents([.large])
        }
    }

    private func controlIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .regular))
            .crowForeground(CrowTheme.textDim)
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }
    private func surfaceButton(_ surface: CompactSurface) -> some View {
        let label = surface == .terminal ? "Terminal" : surface == .editor ? "Editor" : "Files"
        let icon = surface == .terminal ? "terminal" : surface == .editor ? "doc.text" : "folder"
        return Button { if !showingTabs { navigate(surface) } } label: { controlIcon(icon) }
            .accessibilityLabel(label).accessibilityIdentifier("crow.phone.surface.\(surface.rawValue)")
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                guard surface == .terminal || surface == .editor else { return }
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.35)
                restoreTabsKeyboard = keyboardVisible; showingTabs = true
            })
            .accessibilityAction(named: Text("Show All Open Tabs")) {
                restoreTabsKeyboard = keyboardVisible; showingTabs = true
            }
    }

    @ViewBuilder private var generalMenu: some View {
        if model.selectedWorkspace.isRemote {
            Button("Server Screen", systemImage: "desktopcomputer") { model.screenRequest = ScreenRequest(id: model.selectedWorkspaceID) }
                .disabled(model.selectedWorkspace.connection != .connected)
                .accessibilityIdentifier("crow.phone.server-screen")
        }
        Button("Settings…", systemImage: "gearshape") { model.settingsVisible = true }
            .accessibilityIdentifier("crow.phone.settings")
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    private func navigate(_ surface: CompactSurface) {
        model.compactSurface = surface
    }

    @ViewBuilder private var sessionMenu: some View {
        if model.compactSurface == .terminal {
            Button("New Terminal", systemImage: "plus") { model.newTerminal() }
                .disabled(!model.hasWorkspace)
            ForEach(Array(model.current.snapshot.terminalIDs.enumerated()), id: \.element) { index, id in
                Button {
                    model.current.snapshot.selectedTerminalID = id; model.schedulePersist()
                } label: {
                    Label("Terminal \(index + 1)", systemImage: id == model.current.snapshot.selectedTerminalID ? "checkmark" : "terminal")
                }
            }
            if model.selectedWorkspace.isRemote {
                Button("Reconnect", systemImage: "arrow.clockwise") { model.reconnectCurrent() }
                Button("Disconnect", systemImage: "network.slash") { model.disconnectCurrent() }
            }
            Divider()
        } else if model.compactSurface == .editor {
            ForEach(model.buffers) { buffer in
                Button { model.selectedBufferID = buffer.id } label: {
                    Label(buffer.title + (buffer.isDirty ? " •" : ""), systemImage: buffer.id == model.selectedBufferID ? "checkmark" : "doc.text")
                }
            }
            Button("Save File", systemImage: "square.and.arrow.down") { model.saveSelectedBuffer() }
                .disabled(model.selectedBuffer == nil)
            Button("Close File", systemImage: "xmark") {
                if let id = model.selectedBufferID { model.closeBuffer(id) }
            }.disabled(model.selectedBuffer == nil)
            Divider()
        }
    }
}
#endif

private struct SaveDiskIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 2, y: 1)); path.addLine(to: CGPoint(x: 12, y: 1))
        path.addLine(to: CGPoint(x: 16, y: 5)); path.addLine(to: CGPoint(x: 16, y: 16))
        path.addLine(to: CGPoint(x: 1, y: 16)); path.addLine(to: CGPoint(x: 1, y: 2)); path.closeSubpath()
        path.addRect(CGRect(x: 4, y: 1, width: 7, height: 5))
        path.addRect(CGRect(x: 4, y: 10, width: 9, height: 6))
        return path.applying(CGAffineTransform(scaleX: rect.width / 17, y: rect.height / 17))
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
        #if os(iOS)
        let contentReserve: CGFloat = 200 + ResizeHandle.thickness
        #else
        let contentReserve: CGFloat = 326
        #endif
        return min(max(180, proposed), max(180, min(520, available - CrowTheme.activityWidth - contentReserve)))
    }
    static func terminalHeight(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        let maximum = max(0, available - 126) // editor + divider
        return min(max(min(CrowTheme.terminalMinHeight, maximum), proposed), maximum)
    }
}

struct ResizeHandle: View {
    #if os(macOS)
    nonisolated static let thickness: CGFloat = 6
    #else
    nonisolated static let thickness: CGFloat = 20
    #endif
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
            Capsule().fill(CrowTheme.textDim.opacity(0.45))
                .frame(width: axis == .horizontal ? 3 : 28, height: axis == .vertical ? 3 : 28)
                .allowsHitTesting(false)
            Color.clear.contentShape(Rectangle()).highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        onDrag(axis == .horizontal ? value.translation.width : value.translation.height)
                    }
                    .onEnded { _ in onEnd() }
            )
            #endif
        }
        .frame(width: axis == .horizontal ? Self.thickness : nil, height: axis == .vertical ? Self.thickness : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onDrag(20)
            case .decrement: onDrag(-20)
            @unknown default: return
            }
            onEnd()
        }
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
