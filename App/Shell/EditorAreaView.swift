import CrowCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorAreaView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.crowPhoneLayout) private var phoneLayout

    var body: some View {
        VStack(spacing: 0) {
            if !phoneLayout { tabStrip; CrowDivider() }
            if case .browser(let id) = model.current.snapshot.layout?.activePane?.selected {
                BrowserView(session: model.browser(id, in: model.current), workspace: model.current).id(id)
            } else if case .start = model.current.snapshot.layout?.activePane?.selected,
                      let pane = model.current.snapshot.layout?.activePane {
                NewTabPage(paneID: pane.id)
            } else if let buffer = model.selectedBuffer {
                HStack(spacing: 1) {
                    CrowEditorView(buffer: buffer).id(buffer.id)
                    if !phoneLayout, sizeClass != .compact, let splitID = model.current.snapshot.splitBufferID,
                       let split = model.buffers.first(where: { $0.id == splitID }) {
                        CrowEditorView(buffer: split).id("split-\(split.id.rawValue)")
                    }
                }
            } else {
                emptyState
            }
        }
        .background(CrowTheme.bg0)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.buffers) { buffer in
                    tab(buffer)
                }
            }
        }
        .frame(height: 36)
        .background(CrowTheme.bg1)
    }

    private func tab(_ buffer: OpenBuffer) -> some View {
        let selected = buffer.id == model.selectedBufferID
        return HStack(spacing: 8) {
            Button {
                model.selectedBufferID = buffer.id
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(buffer.isDirty ? CrowTheme.accent : Color.clear)
                        .frame(width: 6, height: 6)
                    Text(buffer.title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                    if buffer.isRemote {
                        Image(systemName: "network")
                            .font(.system(size: 9))
                            .crowForeground(CrowTheme.textDim)
                    }
                }
                .crowForeground(selected ? CrowTheme.text : CrowTheme.textDim)
            }
            .buttonStyle(CrowButtonStyle())
            .contextMenu {
                if sizeClass != .compact {
                    Button("Open in Split") { model.current.snapshot.splitBufferID = buffer.id; model.schedulePersist() }
                }
            }

            Button {
                model.closeBuffer(buffer.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .crowForeground(CrowTheme.textDim)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(CrowButtonStyle())
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(selected ? CrowTheme.bg0 : Color.clear)
        .overlay(alignment: .bottom) {
            if selected {
                Rectangle().fill(CrowTheme.accent).frame(height: 1)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 28, weight: .light))
                .crowForeground(CrowTheme.textDim)
            Text("Open a file")
                .font(.system(size: 15, weight: .medium))
                .crowForeground(CrowTheme.text)
            Text("마크다운만이 아니라 txt, json, conf도 같은 에디터입니다.")
                .font(.system(size: 12))
                .crowForeground(CrowTheme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CrowEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let buffer: OpenBuffer
    var isActive = false
    #if os(iOS)
    @State private var editorKeyboard = EditorKeyboardFocus()
    #endif
    @State private var sourceForFind = false
    private var previewMarkdown: Bool {
        buffer.language == .markdown && model.markdownPreviewEnabled && !sourceForFind
    }
    @State private var findRequest = 0
    @State private var pendingFind = false
    @State private var findToggleRequest = 0
    @State private var findVisible = false
    @State private var confirmReload = false

    var body: some View {
        if buffer.isImage { CrowImagePreviewView(buffer: buffer) }
        else if ["canvas", "base"].contains((buffer.path as NSString).pathExtension.lowercased()) {
            ObsidianDocumentView(buffer: buffer, isActive: isActive)
        } else { textEditor }
    }

    private var textEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(buffer.language.label)
                    .font(.system(size: 11, weight: .semibold))
                    .crowForeground(CrowTheme.textDim)
                Spacer()
                if buffer.language == .markdown {
                    Button {
                        model.markdownPreviewEnabled = !previewMarkdown
                        sourceForFind = false
                    } label: {
                        Image(systemName: previewMarkdown ? "chevron.left.forwardslash.chevron.right" : "book")
                    }
                    .help(previewMarkdown ? "Markdown Source" : "Live Preview")
                    .accessibilityLabel(previewMarkdown ? "Markdown Source" : "Live Preview")
                    .accessibilityIdentifier("crow.markdown-preview")
                    .windowDragExcluded()
                }
                Button {
                    if previewMarkdown { showFind() }
                    else { findToggleRequest += 1 }
                } label: { Image(systemName: "magnifyingglass") }
                    .help(findVisible ? "Hide Find and Replace" : "Find and Replace")
                    .accessibilityLabel(findVisible ? "Hide Find and Replace" : "Find and Replace")
                    .accessibilityIdentifier("crow.document-find-toggle")
                    .windowDragExcluded()
                EditorFileMenu(buffer: buffer)
            }
            .buttonStyle(CrowButtonStyle())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(CrowTheme.bg0)
            .windowDragBackground()

            if model.externallyChangedBuffers.contains(buffer.id) {
                HStack {
                    Label("Changed externally. Your edits are kept.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                    Spacer(minLength: 4)
                    Button("Reload…") { confirmReload = true }.font(.caption)
                }.padding(8).background(CrowTheme.bg1)
            }
            if let error = model.externalFileErrors[buffer.id] {
                Text(error).font(.caption).foregroundStyle(CrowTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }

            #if os(iOS)
            ZStack {
                sourceEditor
                    .opacity(previewMarkdown ? 0 : 1)
                    .allowsHitTesting(!previewMarkdown)
                    .accessibilityHidden(previewMarkdown)
                    .environment(\.editorRendererActive, !previewMarkdown)
                if buffer.language == .markdown {
                    renderedEditor
                        .opacity(previewMarkdown ? 1 : 0)
                        .allowsHitTesting(previewMarkdown)
                        .accessibilityHidden(!previewMarkdown)
                        .environment(\.editorRendererActive, previewMarkdown)
                        .environment(\.editorRendererPreview, true)
                }
            }
            .environment(\.editorKeyboardFocus, editorKeyboard)
            .onChange(of: previewMarkdown, initial: true) { _, preview in
                editorKeyboard.selectPreview(preview)
                if !preview && pendingFind { pendingFind = false; findRequest += 1 }
            }
            #else
            if previewMarkdown { renderedEditor } else { sourceEditor }
            #endif
        }
        .onChange(of: model.documentFindRequest) { _, _ in
            if isActive { showFind() }
        }
        .task(id: buffer.path) { await model.observeBuffer(buffer.id) }
        .confirmationDialog("Discard your edits and reload this file?", isPresented: $confirmReload, titleVisibility: .visible) {
            Button("Discard Edits and Reload", role: .destructive) {
                Task { await model.refreshBufferFromSource(buffer.id, discardChanges: true) }
            }
        }
    }

    private var renderedEditor: some View {
        MarkdownPreviewView(text: textBinding, fontSize: model.settings.fontSize,
            onSave: { Task { await model.saveBuffer(buffer.id) } }, locationRequest: locationRequest)
    }

    private var sourceEditor: some View {
        NativeEditor(text: textBinding, fontSize: model.settings.fontSize,
            indentWidth: model.settings.indentWidth, lineNumbers: model.settings.lineNumbers, findRequest: findRequest,
            onSave: { Task { await model.saveBuffer(buffer.id) } }, focused: isActive, locationRequest: locationRequest,
            findToggleRequest: findToggleRequest, onFindVisibility: {
                findVisible = $0
                if !$0 { sourceForFind = false }
            })
            .onAppear { if pendingFind { pendingFind = false; findRequest += 1 } }
    }

    private func showFind() {
        if previewMarkdown { pendingFind = true; sourceForFind = true }
        else { findRequest += 1 }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { model.locate(buffer.id).map { $0.0.snapshot.buffers[$0.1].text } ?? buffer.text },
            set: { model.updateBufferText(buffer.id, $0) }
        )
    }

    private var locationRequest: EditorLocationRequest? {
        guard isActive, model.editorLocationBufferID == buffer.id else { return nil }
        return model.editorLocationRequest
    }

}


struct NewTabPopover: View {
    @Environment(AppModel.self) private var model
    let paneID: UUID
    let dismiss: () -> Void
    private var connected: Bool { !model.selectedWorkspace.isRemote || model.current.remote?.isConnected == true }

    var body: some View {
        CrowPopupPanel(title: "New Tab") {
            CrowPopupAction(title: "Terminal", symbol: "terminal") {
                dismiss(); model.activatePane(paneID); model.newTerminal()
            }
            ForEach(AgentProvider.allCases) { provider in
                Button {
                    dismiss(); model.newAgentTerminal(provider, in: paneID)
                } label: {
                    HStack(spacing: 7) {
                        AgentProviderIcon(provider: provider, size: 14).frame(width: 18)
                        Text(provider.title)
                        Spacer(minLength: 0)
                    }
                }.buttonStyle(CrowPopupButtonStyle()).disabled(!connected)
                    .accessibilityIdentifier("crow.new-tab.agent.\(provider.rawValue)")
            }
            CrowDivider().padding(.vertical, 3)
            CrowPopupAction(title: "Web Browser", symbol: "globe") {
                dismiss(); model.newBrowser(in: paneID)
            }
            CrowPopupAction(title: "Browse Files", symbol: "folder") {
                dismiss(); model.activatePane(paneID); model.showFileExplorer()
            }
        }.accessibilityIdentifier("crow.new-tab-popover")
    }
}

struct NewTabPage: View {
    @Environment(AppModel.self) private var model
    let paneID: UUID

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("New Tab").font(.system(size: 22, weight: .semibold))
                    Text(model.workspaceTitle).font(.system(size: 12)).crowForeground(CrowTheme.textDim)
                        .lineLimit(1).truncationMode(.middle).padding(.bottom, 8)
                    Text("Agents").font(.system(size: 11, weight: .semibold)).crowForeground(CrowTheme.textDim)
                    ForEach(AgentProvider.allCases) { provider in
                        Button { model.newAgentTerminal(provider, in: paneID) } label: {
                            HStack(spacing: 10) {
                                AgentProviderIcon(provider: provider, size: 20)
                                Text(provider.title).font(.system(size: 13))
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(CrowTheme.textDim)
                            }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).padding(8)
                                .background(CrowTheme.bg1, in: RoundedRectangle(cornerRadius: 5))
                                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(CrowTheme.border) }
                        }.buttonStyle(CrowButtonStyle()).windowDragExcluded()
                            .accessibilityIdentifier("crow.new-tab.agent.\(provider.rawValue)")
                    }
                    CrowDivider().padding(.vertical, 8)
                    action("New Terminal", symbol: "terminal") {
                        model.activatePane(paneID); model.newTerminal()
                    }
                    action("Browse Files", symbol: "folder") {
                        model.activatePane(paneID)
                        model.showFileExplorer()
                    }
                    action("Web Browser", symbol: "globe") { model.newBrowser(in: paneID) }
                    action("SSH Hosts", symbol: "network") {
                        model.activatePane(paneID); model.showHosts()
                    }
                }
                .frame(maxWidth: 320).padding(24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .crowForeground(CrowTheme.text).background(CrowTheme.bg0)
        .accessibilityIdentifier("crow.new-tab-page")
    }

    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol).font(.system(size: 13))
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).padding(8)
                .background(CrowTheme.bg1, in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(CrowTheme.border) }
        }.buttonStyle(CrowButtonStyle()).windowDragExcluded()
    }
}

struct WorkspaceAreaView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let saved = model.current.snapshot.layout {
            let panes = saved.panes.compactMap { pane -> WorkspacePane? in
                var pane = pane
                if !model.terminalVisible { pane.tabs.removeAll { if case .terminal = $0 { return true }; return false } }
                if !pane.tabs.contains(where: { $0 == pane.selected }) { pane.selected = pane.tabs.first }
                return pane.tabs.isEmpty ? nil : pane
            }
            let root = model.current.maximizedPaneID.flatMap { id in panes.contains { $0.id == id } ? PaneNode.pane(id) : nil }
                ?? saved.root?.retaining(Set(panes.map(\.id)))
            if let root { WorkspaceNodeView(node: root, panes: panes, isTopLeading: true, isTopTrailing: true) }
            else { empty }
        } else { empty }
    }
    private var empty: some View {
        VStack(spacing: 14) {
            Text("No open tabs").crowForeground(CrowTheme.textDim)
            Button("New Terminal Tab") { model.newTerminal() }.windowDragExcluded()
            Button("Open Folder…") { model.folderImporterVisible = true }.windowDragExcluded()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .windowDragBackground()
    }
}

private struct WorkspaceNodeView: View {
    @Environment(AppModel.self) private var model
    let node: PaneNode
    let panes: [WorkspacePane]
    let isTopLeading: Bool
    let isTopTrailing: Bool
    var body: AnyView {
        switch node {
        case .pane(let id):
            if let pane = panes.first(where: { $0.id == id }) {
                return AnyView(WorkspacePaneView(pane: pane, isTopLeading: isTopLeading, isTopTrailing: isTopTrailing).id(id))
            }
            return AnyView(EmptyView())
        case .split(let id, let axis, let fraction, let first, let second):
            return AnyView(WorkspaceSplitView(id: id, axis: axis, fraction: fraction,
                first: first, second: second, panes: panes, isTopLeading: isTopLeading, isTopTrailing: isTopTrailing))
        }
    }
}

private struct WorkspaceSplitView: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let axis: PaneAxis
    let fraction: Double
    let first: PaneNode
    let second: PaneNode
    let panes: [WorkspacePane]
    let isTopLeading: Bool
    let isTopTrailing: Bool
    @State private var dragStart: CGFloat?
    @State private var liveSize: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, (axis == .horizontal ? geometry.size.width : geometry.size.height) - ResizeHandle.thickness)
            let minimum = min(100, available / 3)
            let size = min(max(minimum, liveSize ?? available * fraction), max(minimum, available - minimum))
            let handle = ResizeHandle(axis: axis == .horizontal ? .horizontal : .vertical, label: "Resize split", onDrag: { delta in
                if dragStart == nil { dragStart = size }
                liveSize = min(max(minimum, (dragStart ?? size) + delta), max(minimum, available - minimum))
            }, onEnd: {
                if let liveSize { model.resizePaneSplit(id, fraction: liveSize / max(1, available)) }
                liveSize = nil; dragStart = nil
            })
            if axis == .horizontal {
                HStack(spacing: 0) {
                    WorkspaceNodeView(node: first, panes: panes, isTopLeading: isTopLeading, isTopTrailing: false).frame(width: size)
                    handle
                    WorkspaceNodeView(node: second, panes: panes, isTopLeading: false, isTopTrailing: isTopTrailing).frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    WorkspaceNodeView(node: first, panes: panes, isTopLeading: isTopLeading, isTopTrailing: isTopTrailing).frame(height: size)
                    handle
                    WorkspaceNodeView(node: second, panes: panes, isTopLeading: false, isTopTrailing: false).frame(maxHeight: .infinity)
                }
            }
        }
    }
}

private let workspaceTabType = UTType(exportedAs: "dev.chajinwoo.crow.workspace-tab", conformingTo: .data)

#if os(iOS)
import UIKit

private struct IOSWorkspaceTabSource: UIViewRepresentable {
    let model: AppModel
    let payload: WorkspaceTabDrag
    let title: String
    func makeUIView(context: Context) -> IOSWorkspaceTabDragView { IOSWorkspaceTabDragView() }
    func updateUIView(_ view: IOSWorkspaceTabDragView, context: Context) {
        view.model = model; view.payload = payload; view.title = title
    }
}

/// UIKit owns the complete drag lifecycle, including cancellation outside a pane.
final class IOSWorkspaceTabDragView: UIView, UIDragInteractionDelegate {
    weak var model: AppModel?
    var payload: WorkspaceTabDrag?
    var title = ""
    override init(frame: CGRect) {
        super.init(frame: frame)
        let drag = UIDragInteraction(delegate: self); drag.isEnabled = true; addInteraction(drag)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(selectTab)))
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func selectTab() {
        guard let model, let payload else { return }
        model.selectTab(payload.tab, in: payload.paneID)
    }
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        guard let model, let payload, payload.workspaceID == model.selectedWorkspaceID,
              model.current.snapshot.layout?.panes.contains(where: { $0.id == payload.paneID && $0.tabs.contains(payload.tab) }) == true,
              let data = try? JSONEncoder().encode(payload) else { return [] }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: workspaceTabType.identifier, visibility: .ownProcess) { completion in
            completion(data, nil); return nil
        }
        let item = UIDragItem(itemProvider: provider); item.localObject = payload
        return [item]
    }
    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
        guard let payload = session.items.first?.localObject as? WorkspaceTabDrag,
              payload.workspaceID == model?.selectedWorkspaceID else { return }
        model?.draggedTab = payload
    }
    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool { true }
    func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: any UIDragSession) -> Bool { true }
    func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) { endDrag() }
    func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, willEndWith operation: UIDropOperation) {
        if operation == .cancel || operation == .forbidden { endDrag() }
    }
    func endDrag() { if model?.draggedTab == payload { model?.draggedTab = nil } }
    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession) -> UITargetedDragPreview? {
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: min(260, max(100, bounds.width)), height: 32))
        label.text = "  " + title; label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = UIColor(CrowTheme.text); label.backgroundColor = UIColor(CrowTheme.bg1)
        label.layer.cornerRadius = 5; label.clipsToBounds = true
        return UITargetedDragPreview(view: label, parameters: UIDragPreviewParameters(),
            target: UIDragPreviewTarget(container: self, center: CGPoint(x: bounds.midX, y: bounds.midY)))
    }
}

private struct IOSWorkspacePaneDrop: UIViewRepresentable {
    let model: AppModel
    let paneID: UUID
    @Binding var placement: PanePlacement?
    func makeUIView(context: Context) -> IOSWorkspacePaneDropView { IOSWorkspacePaneDropView() }
    func updateUIView(_ view: IOSWorkspacePaneDropView, context: Context) {
        view.model = model; view.paneID = paneID; view.isHidden = model.draggedTab == nil
        view.highlight = { placement = $0 }
    }
}

/// During tab drags this sits above UITextView, WKWebView and SwiftTerm, so their
/// native text/attachment drop interactions cannot claim workspace tabs.
final class IOSWorkspacePaneDropView: UIView, UIDropInteractionDelegate {
    weak var model: AppModel?
    var paneID = UUID()
    var highlight: (PanePlacement?) -> Void = { _ in }
    override init(frame: CGRect) {
        super.init(frame: frame); addInteraction(UIDropInteraction(delegate: self))
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard model?.draggedTab != nil else { return nil }
        return super.hitTest(point, with: event)
    }
    func acceptedPayload(_ session: any UIDropSession) -> WorkspaceTabDrag? {
        guard session.localDragSession != nil, session.items.count == 1,
              session.hasItemsConforming(toTypeIdentifiers: [workspaceTabType.identifier]),
              let payload = session.items.first?.localObject as? WorkspaceTabDrag,
              payload == model?.draggedTab, payload.workspaceID == model?.selectedWorkspaceID,
              model?.current.snapshot.layout?.panes.contains(where: { $0.id == payload.paneID && $0.tabs.contains(payload.tab) }) == true else { return nil }
        return payload
    }
    func destination(at point: CGPoint) -> (PanePlacement, WorkspaceTab?) {
        if point.y < 36 {
            func sources(_ view: UIView) -> [IOSWorkspaceTabDragView] {
                if let source = view as? IOSWorkspaceTabDragView { return [source] }
                return view.subviews.flatMap(sources)
            }
            let tabs = window.map(sources)?.filter { $0.payload?.paneID == paneID && $0.convert($0.bounds, to: self).intersects(bounds) }
                .sorted { $0.convert($0.bounds, to: self).minX < $1.convert($1.bounds, to: self).minX } ?? []
            return (.center, tabs.first { point.x < $0.convert($0.bounds, to: self).midX }?.payload?.tab)
        }
        if point.x < min(90, bounds.width * 0.25) { return (.left, nil) }
        if point.x > bounds.width - min(90, bounds.width * 0.25) { return (.right, nil) }
        if point.y < 36 + min(70, max(0, bounds.height - 36) * 0.25) { return (.top, nil) }
        if point.y > bounds.height - min(70, bounds.height * 0.25) { return (.bottom, nil) }
        return (.center, nil)
    }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool { acceptedPayload(session) != nil }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        guard acceptedPayload(session) != nil else { highlight(nil); return UIDropProposal(operation: .forbidden) }
        highlight(destination(at: session.location(in: self)).0)
        return UIDropProposal(operation: .move)
    }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        defer { highlight(nil); model?.draggedTab = nil }
        guard let payload = acceptedPayload(session), let model else { return }
        let (edge, before) = destination(at: session.location(in: self))
        _ = model.moveTab(payload, to: paneID, placement: edge, before: before)
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) { highlight(nil) }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) { highlight(nil) }
}
#endif

private struct WorkspacePaneView: View {
    @Environment(AppModel.self) private var model
    let pane: WorkspacePane
    let isTopLeading: Bool
    let isTopTrailing: Bool
    @State private var dropPlacement: PanePlacement?
    @State private var showingNewTab = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                CrowDivider()
                Group {
                    if let selected = pane.selected {
                        switch selected {
                        case .file(let id):
                            if let buffer = model.buffers.first(where: { $0.id == id }) {
                                CrowEditorView(buffer: buffer, isActive: model.current.snapshot.layout?.activePaneID == pane.id).id(id)
                            }
                        case .terminal(let id):
                            terminal(id)
                        case .start:
                            NewTabPage(paneID: pane.id)
                        case .browser(let id):
                            BrowserView(session: model.browser(id, in: model.current), workspace: model.current).id(id)
                        }
                    }
                }
                .simultaneousGesture(TapGesture().onEnded { model.activatePane(pane.id) })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CrowTheme.bg0)
            .overlay { dropHighlight(size: geometry.size).allowsHitTesting(false) }
            #if os(macOS)
            .overlay {
                NativeWorkspacePaneDrop(model: model, paneID: pane.id, placement: $dropPlacement)
                    .allowsHitTesting(model.draggedTab != nil)
            }
            .onChange(of: model.draggedTab) { _, drag in if drag == nil { dropPlacement = nil } }
            #else
            .overlay {
                IOSWorkspacePaneDrop(model: model, paneID: pane.id, placement: $dropPlacement)
                    .allowsHitTesting(model.draggedTab != nil)
            }
            .onChange(of: model.draggedTab) { _, drag in if drag == nil { dropPlacement = nil } }
            #endif
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            ScrollViewReader { scroll in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(pane.tabs, id: \.self) { tab in tabView(tab).id(tab.key) }
                        Button { showingNewTab.toggle() } label: { PanelActionIcon(symbol: "plus") }
                            .buttonStyle(CrowButtonStyle())
                            .frame(width: 32, height: 36)
                            .help("New Tab").accessibilityLabel("New Tab")
                            .accessibilityIdentifier("crow.pane.new-tab")
                            .windowDragExcluded()
                            .id("add-tab")
                            .popover(isPresented: $showingNewTab, arrowEdge: .bottom) {
                                NewTabPopover(paneID: pane.id) { showingNewTab = false }.environment(model)
                            }
                    }
                }
                #if os(macOS)
                .overlay { WindowDragRegion() }
                #endif
                .onChange(of: pane.selected) { _, tab in
                    if case .start = tab { scroll.scrollTo("add-tab", anchor: .trailing) }
                    else if let tab { scroll.scrollTo(tab.key) }
                }
            }
            Menu {
                Button("New Tab") { showingNewTab = true }
                Button("New Terminal Tab") { model.activatePane(pane.id); model.newTerminal() }
                Button("SSH Command…") { model.sshCommandVisible = true }
                if let tab = pane.selected {
                    Divider()
                    Button("Split Right") { model.splitTab(tab, in: pane.id, placement: .right) }
                    Button("Split Down") { model.splitTab(tab, in: pane.id, placement: .bottom) }
                }
                if model.selectedWorkspace.isRemote {
                    Divider()
                    Button("Reconnect") { model.reconnectCurrent() }
                    Button("Disconnect") { model.disconnectCurrent() }
                }
            } label: { PanelActionIcon(symbol: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 28, height: 28).help("Pane actions")
            .crowMenuHover()
            .windowDragExcluded()
            if !model.inspectorVisible && showsInspectorToggle {
            Button {
                model.current.maximizedPaneID = nil
                model.inspectorVisible = true
            } label: {
                PanelActionIcon(symbol: "sidebar.right")
            }
            .buttonStyle(CrowButtonStyle())
            .help("Show Right Sidebar")
            .accessibilityLabel("Show Right Sidebar")
            .accessibilityIdentifier("crow.inspector-toggle")
            .windowDragExcluded()
            }
        }
        // Only the top-left pane shares its header with the collapsed sidebar controls.
        .padding(.leading, !model.sidebarVisible && isTopLeading ? SidebarTopBar.collapsedWidth : 0)
        .padding(.trailing, 5).frame(height: 36).background(CrowTheme.bg1)
    }

    private var showsInspectorToggle: Bool {
        #if os(macOS)
        true
        #else
        isTopTrailing
        #endif
    }

    private func title(_ tab: WorkspaceTab) -> String {
        switch tab {
        case .start: return "New Tab"
        case .browser(let id): return model.browser(id, in: model.current).title
        case .file(let id): return model.buffers.first { $0.id == id }?.title ?? "File"
        case .terminal(let id): return model.current.snapshot.agentTerminals.first { $0.id == id }?.title ?? "Terminal \((model.current.snapshot.terminalIDs.firstIndex(of: id) ?? 0) + 1)"
        }
    }
    private func tabView(_ tab: WorkspaceTab) -> some View {
        let selected = pane.selected == tab
        let dirty: Bool = { if case .file(let id) = tab { return model.buffers.first { $0.id == id }?.isDirty == true }; return false }()
        return HStack(spacing: 6) {
            Button { model.selectTab(tab, in: pane.id) } label: {
                HStack(spacing: 5) {
                    if case .terminal(let id) = tab, let agent = model.current.snapshot.agentTerminals.first(where: { $0.id == id }) {
                        AgentProviderIcon(provider: agent.provider, size: 13)
                    } else {
                        Image(systemName: {
                            switch tab {
                            case .terminal: return "terminal"
                            case .file(let id): return model.buffers.first { $0.id == id }?.isImage == true ? "photo" : "doc.text"
                            case .start: return "square.grid.2x2"
                            case .browser: return "globe"
                            }
                        }())
                            .font(.system(size: 10))
                    }
                    Text(title(tab)).font(.system(size: 12)).lineLimit(1)
                    if dirty { Circle().fill(CrowTheme.accent).frame(width: 5, height: 5) }
                }
            }
            Button { model.closeTab(tab, in: pane.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8)).frame(width: 18, height: 24)
            }.help("Close \(title(tab))")
        }
        .buttonStyle(CrowButtonStyle()).crowForeground(selected ? CrowTheme.text : CrowTheme.textDim)
        .padding(.horizontal, 10).frame(height: 36)
        .background(selected ? CrowTheme.bg0 : CrowTheme.bg1)
        .overlay(alignment: .bottom) { if selected { CrowTheme.accent.frame(height: 1) } }
        .contentShape(Rectangle())
        .accessibilityIdentifier("crow.tab.\(tab.key)")
        .contextMenu {
            Button("Split Right") { model.splitTab(tab, in: pane.id, placement: .right) }
            Button("Split Down") { model.splitTab(tab, in: pane.id, placement: .bottom) }
            if let layout = model.current.snapshot.layout {
                ForEach(layout.panes.filter { $0.id != pane.id }) { destination in
                    Button("Move to Pane \((layout.root?.paneIDs.firstIndex(of: destination.id) ?? 0) + 1)") {
                        _ = model.moveTab(.init(workspaceID: model.selectedWorkspaceID, paneID: pane.id, tab: tab),
                            to: destination.id, placement: .center)
                    }
                }
            }
            Divider()
            Button("Close Tab") { model.closeTab(tab, in: pane.id) }
        }
        #if os(macOS)
        .background { WindowDragExclusion() }
        .overlay {
            GeometryReader { geometry in
                NativeWorkspaceTabSource(model: model,
                    payload: .init(workspaceID: model.selectedWorkspaceID, paneID: pane.id, tab: tab), title: title(tab))
                    .frame(width: max(0, geometry.size.width - 28), height: geometry.size.height)
            }
        }
        #else
        .overlay {
            GeometryReader { geometry in
                IOSWorkspaceTabSource(model: model,
                    payload: .init(workspaceID: model.selectedWorkspaceID, paneID: pane.id, tab: tab), title: title(tab))
                    .frame(width: max(0, geometry.size.width - 28), height: geometry.size.height)
            }
        }
        #endif
    }
    private func terminal(_ id: UUID) -> some View {
        let session = model.terminal(id, in: model.current)
        return VStack(spacing: 0) {
            TerminalViewHost(session: session, fontSize: model.settings.terminalFontSize)
                .id(session.instanceID).task(id: session.instanceID) { session.start() }
                .task(id: model.current.snapshot.layout?.activePaneID == pane.id) {
                    guard model.current.snapshot.layout?.activePaneID == pane.id else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    #if os(macOS)
                    session.view.window?.makeFirstResponder(session.view)
                    #endif
                }
            ImagePasteStatusView(session: session)
            Text(session.status).font(.system(size: 10)).crowForeground(CrowTheme.textDim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
        }
    }
    @ViewBuilder private func dropHighlight(size: CGSize) -> some View {
        if let edge = dropPlacement {
            let horizontal = edge == .left || edge == .right
            let vertical = edge == .top || edge == .bottom
            let alignment: Alignment = edge == .left ? .leading : edge == .right ? .trailing : edge == .top ? .top : edge == .bottom ? .bottom : .center
            CrowTheme.accent.opacity(0.12)
                .overlay(Rectangle().stroke(CrowTheme.accent, lineWidth: 2))
                .frame(width: horizontal ? size.width / 2 : size.width, height: vertical ? size.height / 2 : size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
    }
}

#if os(macOS)
import AppKit

private struct NativeWorkspaceTabSource: NSViewRepresentable {
    let model: AppModel
    let payload: WorkspaceTabDrag
    let title: String
    func makeNSView(context: Context) -> WorkspaceTabDragView { WorkspaceTabDragView() }
    func updateNSView(_ view: WorkspaceTabDragView, context: Context) {
        view.model = model; view.payload = payload; view.title = title
    }
}

/// Own the mouse-to-drag transition in AppKit, rather than competing with a SwiftUI Button's gesture.
final class WorkspaceTabDragView: NSControl, NSDraggingSource {
    weak var model: AppModel?
    var payload: WorkspaceTabDrag?
    var filePayload: ExplorerFileDrag?
    var onClick: (() -> Void)?
    var title = ""
    private var mouseDownPoint: NSPoint?
    private var startedDrag = false
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        WorkspaceDragRouter.shared.register(self)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if NSApp.currentEvent?.type == .rightMouseDown || NSApp.currentEvent?.modifierFlags.contains(.control) == true { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow; startedDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard !startedDrag, let origin = mouseDownPoint, let model,
              hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4 else { return }
        let item = NSPasteboardItem()
        if let payload, let data = try? JSONEncoder().encode(payload) {
            item.setData(data, forType: WorkspacePaneDropView.pasteboardType); model.draggedTab = payload
        } else if let filePayload, let data = try? JSONEncoder().encode(filePayload) {
            item.setData(data, forType: ExplorerFileDropView.pasteboardType); model.draggedFile = filePayload
        } else { return }
        startedDrag = true
        WorkspaceDragRouter.shared.finish(self) // AppKit owns subsequent events until the drag session ends.
        if let window { WorkspaceDragRouter.shared.beginDrag(in: window, model: model) }
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let previewSize = NSSize(width: min(260, max(100, bounds.width)), height: 30)
        let image = NSImage(size: previewSize, flipped: true) { rect in
            NSColor(CrowTheme.bg1).setFill(); NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            (self.title as NSString).draw(at: NSPoint(x: 8, y: 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(CrowTheme.text)])
            return true
        }
        draggingItem.setDraggingFrame(NSRect(origin: bounds.origin, size: previewSize), contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
            .animatesToStartingPositionsOnCancelOrFail = true
    }
    override func mouseUp(with event: NSEvent) {
        if !startedDrag, bounds.contains(convert(event.locationInWindow, from: nil)) {
            if let payload { model?.selectTab(payload.tab, in: payload.paneID) }
            else { onClick?() }
        }
        mouseDownPoint = nil
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        model?.draggedTab = nil; model?.draggedFile = nil; mouseDownPoint = nil; startedDrag = false
        WorkspaceDragRouter.shared.finish(self)
        WorkspaceDragRouter.shared.endDrag()
    }
}

/// SwiftUI List/ScrollView can route mouse events to NSHostingView instead of a transparent
/// representable. Route only presses inside our visible tab/row sources, before those gestures.
@MainActor final class WorkspaceDragRouter {
    static let shared = WorkspaceDragRouter()
    private let sources = NSHashTable<WorkspaceTabDragView>.weakObjects()
    private weak var pressedSource: WorkspaceTabDragView?
    private var monitor: Any?
    private(set) var dropSurface: WorkspaceWindowDropView?
    func beginDrag(in window: NSWindow, model: AppModel) {
        endDrag()
        guard let content = window.contentView, let frameView = content.superview else { return }
        let surface = WorkspaceWindowDropView(frame: content.convert(content.bounds, to: frameView))
        surface.model = model; surface.autoresizingMask = [.width, .height]
        frameView.addSubview(surface, positioned: .above, relativeTo: content)
        dropSurface = surface
    }
    func endDrag() {
        dropSurface?.draggingExited(nil); dropSurface?.removeFromSuperview(); dropSurface = nil
    }
    func register(_ source: WorkspaceTabDragView) {
        if source.window == nil {
            sources.remove(source)
            if pressedSource === source { pressedSource = nil }
        } else { sources.add(source) }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.route(event) == nil
            }
            return consumed ? nil : event
        }
    }
    func source(at point: NSPoint, in window: NSWindow) -> WorkspaceTabDragView? {
        sources.allObjects.first {
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor &&
                $0.model?.draggedTab == nil && $0.model?.draggedFile == nil &&
                $0.visibleRect.intersection($0.bounds).contains($0.convert(point, from: nil))
        }
    }
    func route(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            pressedSource = nil
            guard !event.modifierFlags.contains(.control), let window = event.window,
                  let source = source(at: event.locationInWindow, in: window) else { return event }
            pressedSource = source; source.mouseDown(with: event)
            return nil
        case .leftMouseDragged:
            guard let source = pressedSource, source.window === event.window else { return event }
            source.mouseDragged(with: event)
            return nil
        case .leftMouseUp:
            guard let source = pressedSource else { return event }
            pressedSource = nil; source.mouseUp(with: event)
            return nil
        default: return event
        }
    }
    func finish(_ source: WorkspaceTabDragView) { if pressedSource === source { pressedSource = nil } }
}

/// An AppKit sibling of NSHostingView, only for the lifetime of a drag. SwiftUI's hit-test
/// graph and native text views cannot swallow drop events before they reach this surface.
final class WorkspaceWindowDropView: NSView {
    weak var model: AppModel?
    private weak var currentTarget: NSView?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([WorkspacePaneDropView.pasteboardType, ExplorerFileDropView.pasteboardType])
    }
    required init?(coder: NSCoder) { nil }
    func destination(at point: NSPoint) -> NSView? {
        func targets(_ view: NSView) -> [NSView] {
            if model?.draggedTab != nil, view is WorkspacePaneDropView { return [view] }
            if model?.draggedFile != nil, view is ExplorerFileDropView { return [view] }
            return view.subviews.flatMap(targets)
        }
        return window?.contentView.map(targets)?.first { $0.bounds.contains($0.convert(point, from: nil)) }
    }
    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = destination(at: sender.draggingLocation)
        if target !== currentTarget { currentTarget?.draggingExited(sender); currentTarget = target }
        return target?.draggingUpdated(sender) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { currentTarget?.draggingExited(sender); currentTarget = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { update(sender) == .move }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let target = destination(at: sender.draggingLocation) else { return false }
        return target.performDragOperation(sender)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { currentTarget?.draggingEnded(sender); currentTarget = nil }
}

private struct NativeWorkspacePaneDrop: NSViewRepresentable {
    let model: AppModel
    let paneID: UUID
    @Binding var placement: PanePlacement?
    func makeNSView(context: Context) -> WorkspacePaneDropView { WorkspacePaneDropView() }
    func updateNSView(_ view: WorkspacePaneDropView, context: Context) {
        view.model = model; view.paneID = paneID
        view.isHidden = model.draggedTab == nil
        view.highlight = { placement = $0 }
    }
}

/// Shown only during an internal tab drag, above NSTextView and SwiftTerm's own drop destinations.
final class WorkspacePaneDropView: NSView {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.chajinwoo.crow.workspace-tab")
    weak var model: AppModel?
    var paneID = UUID()
    var highlight: (PanePlacement?) -> Void = { _ in }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); registerForDraggedTypes([Self.pasteboardType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard model?.draggedTab != nil else { return nil }
        return super.hitTest(point)
    }
    func payload(from pasteboard: NSPasteboard) -> WorkspaceTabDrag? {
        guard let data = pasteboard.data(forType: Self.pasteboardType),
              let payload = try? JSONDecoder().decode(WorkspaceTabDrag.self, from: data),
              payload == model?.draggedTab, payload.workspaceID == model?.selectedWorkspaceID,
              model?.current.snapshot.layout?.panes.contains(where: { $0.id == payload.paneID && $0.tabs.contains(payload.tab) }) == true else { return nil }
        return payload
    }
    func destination(at point: NSPoint) -> (PanePlacement, WorkspaceTab?) {
        if point.y < 36 {
            func sources(_ view: NSView) -> [WorkspaceTabDragView] {
                if let source = view as? WorkspaceTabDragView { return [source] }
                return view.subviews.flatMap(sources)
            }
            let tabs = window?.contentView.map(sources)?.filter { $0.payload?.paneID == paneID }
                .sorted { $0.convert($0.bounds, to: self).minX < $1.convert($1.bounds, to: self).minX } ?? []
            return (.center, tabs.first { point.x < $0.convert($0.bounds, to: self).midX }?.payload?.tab)
        }
        if point.x < min(90, bounds.width * 0.25) { return (.left, nil) }
        if point.x > bounds.width - min(90, bounds.width * 0.25) { return (.right, nil) }
        if point.y < 36 + min(70, (bounds.height - 36) * 0.25) { return (.top, nil) }
        if point.y > bounds.height - min(70, bounds.height * 0.25) { return (.bottom, nil) }
        return (.center, nil)
    }
    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard payload(from: sender.draggingPasteboard) != nil else { highlight(nil); return [] }
        highlight(destination(at: convert(sender.draggingLocation, from: nil)).0)
        return .move
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight(nil) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { payload(from: sender.draggingPasteboard) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { highlight(nil) }
        guard let payload = payload(from: sender.draggingPasteboard), let model else { return false }
        let (placement, before) = destination(at: convert(sender.draggingLocation, from: nil))
        return model.moveTab(payload, to: paneID, placement: placement, before: before)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlight(nil) }
}
#endif
