import CrowCore
import SwiftUI

struct InspectorPanel: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "Summary"
    @State private var outline: [OutlineItem] = []
    @State private var outlineBufferID: BufferID?
    @State private var outlineSource = ""
    #if os(macOS)
    @State private var repository: RepositorySnapshot?
    @State private var gitError: String?
    @State private var refreshing = false
    @State private var refreshID = UUID()

    private var gitTaskID: String {
        "\(model.selectedWorkspaceID)-\(model.current.snapshot.rootPath)-\(model.selectedWorkspace.connection)-\(tab)-\(refreshID)"
    }

    #endif
    private var buffer: OpenBuffer? { model.inspectedBuffer }
    private var tabs: [String] {
        #if os(macOS)
        ["Summary", "Git"]
        #else
        ["Summary"]
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(tabs, id: \.self) { item in
                    Button { tab = item } label: {
                        Label(item, systemImage: item == "Summary" ? "list.bullet.indent" : "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 11, weight: tab == item ? .semibold : .regular))
                            .crowForeground(CrowTheme.textDim)
                    }.windowDragExcluded()
                        .accessibilityIdentifier("crow.inspector-" + item.lowercased())
                }
                Spacer(minLength: 0)
                Button { model.inspectorVisible = false } label: { PanelActionIcon(symbol: "sidebar.right") }
                    .help("Hide Right Sidebar").accessibilityLabel("Hide Right Sidebar")
                    .accessibilityIdentifier("crow.inspector-close")
                    .windowDragExcluded()
            }
            .buttonStyle(CrowButtonStyle()).padding(.horizontal, 12).frame(height: 36)
            .windowDragBackground()
            CrowDivider()
            #if os(macOS)
            if tab == "Summary" { summary } else { git }
            #else
            summary
            #endif
        }
        .background(CrowTheme.bg1)
        .crowForeground(CrowTheme.text)
        .task(id: buffer) {
            guard let buffer else { outline = []; outlineBufferID = nil; return }
            if outlineBufferID != buffer.id { outline = []; outlineBufferID = buffer.id }
            do {
                try await Task.sleep(for: .milliseconds(180))
                let items = await Task.detached(priority: .utility) { DocumentOutline.items(buffer.text, language: buffer.language) }.value
                try Task.checkCancellation()
                outline = items; outlineSource = buffer.text
            } catch {}
        }
        #if os(macOS)
        .task(id: gitTaskID) {
            repository = nil; gitError = nil
            guard tab == "Git", model.hasWorkspace else { return }
            let state = model.current, path = state.snapshot.rootPath, remote = state.systemSSH
            if state.snapshot.workspace.isRemote && remote == nil {
                gitError = "Connect through the terminal to read remote Git status."; return
            }
            while !Task.isCancelled {
                refreshing = true
                do {
                    let result = try await GitRepository.read(path: path, remote: remote)
                    try Task.checkCancellation()
                    repository = result; gitError = nil
                } catch is CancellationError { return }
                catch { guard !Task.isCancelled else { return }; repository = nil; gitError = error.localizedDescription }
                refreshing = false
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        #endif
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let buffer {
                Text(buffer.title).font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).padding(12)
                if outline.isEmpty {
                    Text(buffer.language == .markdown ? "No headings" : "No recognized functions or methods")
                        .font(.system(size: 12)).crowForeground(CrowTheme.textDim).padding(12)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(outline) { item in
                                Button { model.navigateToOutline(item, in: buffer) } label: {
                                    HStack(spacing: 6) {
                                        if item.headingIndex == nil {
                                            Text("ƒ").font(.system(size: 10, design: .monospaced)).crowForeground(CrowTheme.textDim)
                                        }
                                        Text(item.title).font(.system(size: 12)).crowForeground(CrowTheme.textDim)
                                            .lineLimit(1).truncationMode(.tail)
                                        Spacer(minLength: 2)
                                        Text(String(item.line)).font(.system(size: 10, design: .monospaced)).crowForeground(CrowTheme.textDim)
                                    }
                                    .padding(.leading, CGFloat(item.depth) * 10).padding(.horizontal, 10).padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(CrowButtonStyle()).help("\(item.title) — line \(item.line)")
                                .disabled(outlineSource != buffer.text)
                                .windowDragExcluded()
                                .accessibilityIdentifier("crow.outline.\(item.line)")
                            }
                        }
                    }
                }
            } else {
                Text("Open a Markdown or code file").font(.system(size: 12))
                    .crowForeground(CrowTheme.textDim).padding(12)
                Spacer()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    #if os(macOS)
    private var git: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(repository?.status.branch ?? "Repository").font(.system(size: 11, weight: .medium)).lineLimit(2)
                Spacer(minLength: 0)
                if refreshing { ProgressView().controlSize(.mini) }
                Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(CrowButtonStyle()).help("Refresh Git Status")
            }.padding(.horizontal, 12).padding(.top, 12)
            if let gitError { Text(gitError).font(.system(size: 11)).crowForeground(CrowTheme.textDim).textSelection(.enabled).padding(.horizontal, 12) }
            if let repository {
                if repository.status.changes.isEmpty {
                    Text("Working tree clean").font(.system(size: 12)).crowForeground(CrowTheme.textDim).padding(12)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(repository.status.changes) { change in
                                Button {
                                    guard !change.path.hasPrefix("/"), !change.path.split(separator: "/").contains("..") else { return }
                                    let path = (repository.root as NSString).appendingPathComponent(change.path)
                                    model.openFile(FileEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: false))
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(change.status).font(.system(size: 10, design: .monospaced)).crowForeground(CrowTheme.accent)
                                        Text(change.path).font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }.padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                                }.buttonStyle(CrowButtonStyle()).disabled(change.isDeleted)
                                    .help(change.previousPath.map { "\($0) → \(change.path)" } ?? change.path)
                            }
                        }
                    }
                }
                Text("Saved files · index / working tree status").font(.system(size: 10)).crowForeground(CrowTheme.textDim).padding(12)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    #endif
}
