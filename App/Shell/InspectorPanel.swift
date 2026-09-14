import CrowCore
import SwiftUI

struct InspectorPanel: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "Summary"
    @State private var outline: [OutlineItem] = []
    @State private var outlineBufferID: BufferID?
    @State private var outlineSource = ""
    @State private var projects: [String] = []
    @State private var selectedProject: String?
    @State private var projectScope: String?
    @State private var projectError: String?
    @State private var projectWarning: String?
    @State private var discovering = false
    @State private var discoveryGeneration = UUID()
    @State private var refreshID = UUID()

    private var gitScopeID: String { "\(model.selectedWorkspaceID)-\(model.current.snapshot.rootPath)" }
    private var activeProject: String? { projectScope == gitScopeID ? selectedProject : nil }

    private var gitTaskID: String {
        "\(model.selectedWorkspaceID)-\(model.current.snapshot.rootPath)-\(model.selectedWorkspace.connection)-\(tab)-\(refreshID)"
    }

    private var buffer: OpenBuffer? { model.inspectedBuffer }
    private let tabs = ["Summary", "Git"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(tabs, id: \.self) { item in
                    Button { tab = item } label: {
                        Label(item, systemImage: item == "Summary" ? "list.bullet.indent" : "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 11, weight: tab == item ? .semibold : .regular))
                            .crowForeground(tab == item ? CrowTheme.accent : CrowTheme.textDim)
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
            if tab == "Summary" { summary } else { git }
        }
        .background(CrowTheme.bg1)
        .crowForeground(CrowTheme.text)
        .task(id: buffer) {
            guard let buffer, !buffer.isImage else { outline = []; outlineBufferID = nil; return }
            if outlineBufferID != buffer.id { outline = []; outlineBufferID = buffer.id }
            do {
                try await Task.sleep(for: .milliseconds(180))
                let items = await Task.detached(priority: .utility) { DocumentOutline.items(buffer.text, language: buffer.language) }.value
                try Task.checkCancellation()
                outline = items; outlineSource = buffer.text
            } catch {}
        }
        .task(id: gitTaskID) {
            let generation = UUID(); discoveryGeneration = generation
            if projectScope != gitScopeID {
                projectScope = gitScopeID; projects = []; selectedProject = nil
            }
            projectError = nil; projectWarning = nil; discovering = false
            guard tab == "Git", model.hasWorkspace else { return }
            let state = model.current, path = state.snapshot.rootPath
            #if os(iOS)
            guard state.snapshot.workspace.isRemote else {
                projectError = "Open an SSH workspace to view Git projects on iPad and iPhone."; return
            }
            #endif
            discovering = true
            defer { if discoveryGeneration == generation { discovering = false } }
            do {
                let result: GitProjectList
                #if os(macOS)
                if let remote = state.systemSSH {
                    result = try await GitRepository.projects(path: path, remote: remote)
                } else if !state.snapshot.workspace.isRemote {
                    result = try await GitRepository.projects(path: path)
                } else {
                    guard let remote = state.remote else { throw FileFailure.disconnected }
                    result = try await remote.gitProjects(path: path)
                }
                #else
                guard let remote = state.remote else { throw FileFailure.disconnected }
                result = try await remote.gitProjects(path: path)
                #endif
                try Task.checkCancellation()
                projects = result.paths; projectWarning = result.warning
                if let selectedProject, !result.paths.contains(selectedProject) { self.selectedProject = nil }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                projects = []; selectedProject = nil; projectError = error.localizedDescription
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let buffer {
                Text(buffer.title).font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).padding(12)
                if buffer.isImage {
                    if let preview = model.imagePreviews[buffer.id] {
                        Text("\(preview.format) · \(preview.width) × \(preview.height)")
                            .font(.system(size: 12)).crowForeground(CrowTheme.textDim).padding(.horizontal, 12)
                    }
                    Text(buffer.path).font(.system(size: 11)).textSelection(.enabled)
                        .crowForeground(CrowTheme.textDim).padding(12)
                    Spacer()
                } else if outline.isEmpty {
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

    private var git: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if activeProject != nil {
                    Button { selectedProject = nil } label: {
                        Label("Projects", systemImage: "chevron.left")
                    }
                    .buttonStyle(CrowButtonStyle()).accessibilityIdentifier("crow.git-projects-back")
                }
                Text(activeProject.map { ($0 as NSString).lastPathComponent } ?? "Git Projects")
                    .font(.system(size: 11, weight: .medium)).lineLimit(2)
                Spacer(minLength: 0)
                if discovering { ProgressView().controlSize(.mini) }
                Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(CrowButtonStyle()).help("Refresh Git Projects and Status")
                    .disabled(discovering).accessibilityIdentifier("crow.git-refresh")
            }.padding(.horizontal, 12).padding(.top, 12)
            if let error = projectError {
                Text(error).font(.system(size: 11)).crowForeground(CrowTheme.textDim).textSelection(.enabled).padding(.horizontal, 12)
            }
            if activeProject == nil {
                projectList
            } else if let path = activeProject {
                GitProjectStatusView(path: path, refreshID: refreshID)
                    .id(gitScopeID + "-" + path)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let projectWarning {
                Text(projectWarning).font(.system(size: 11)).crowForeground(CrowTheme.textDim).padding(.horizontal, 12)
            }
            Text(discovering ? "Finding Git projects…" : "Select a Git project to view its status")
                .font(.system(size: 11)).crowForeground(CrowTheme.textDim).padding(.horizontal, 12)
            if projects.isEmpty && !discovering && projectError == nil && projectWarning == nil {
                Text("No Git projects in this folder or its subfolders")
                    .font(.system(size: 12)).crowForeground(CrowTheme.textDim).padding(12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(projectScope == gitScopeID ? projects : [], id: \.self) { path in
                        Button { selectedProject = path } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "point.3.connected.trianglepath.dotted").crowForeground(CrowTheme.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text((path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium))
                                    Text(projectLocation(path)).font(.system(size: 10)).crowForeground(CrowTheme.textDim)
                                }.lineLimit(2).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 10)).crowForeground(CrowTheme.textDim)
                            }.padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                        }
                        .buttonStyle(CrowButtonStyle()).help(path).windowDragExcluded()
                        .accessibilityIdentifier("crow.git-project." + path)
                    }
                }
            }
        }
    }

    private func projectLocation(_ path: String) -> String {
        let root = model.current.snapshot.rootPath
        if path == root { return "This folder" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}


/// Mounting a selected project starts its own query. Going back or choosing a
/// different project cancels that query with the view's lifetime.
@MainActor @Observable
final class GitProjectStatusState {
    var repository: RepositorySnapshot?
    var error: String?
}

struct GitProjectStatusView: View {
    @Environment(AppModel.self) private var model
    let path: String
    let refreshID: UUID
    @State var status = GitProjectStatusState()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let repository = status.repository {
                Text(repository.status.branch).font(.system(size: 11, weight: .medium)).padding(.horizontal, 12)
                    .accessibilityIdentifier("crow.git-branch")
                Text(repository.root).font(.system(size: 10)).crowForeground(CrowTheme.textDim)
                    .lineLimit(2).truncationMode(.middle).padding(.horizontal, 12)
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
            } else if status.error == nil {
                ProgressView("Loading Git status…").padding(12)
                    .accessibilityIdentifier("crow.git-status-loading")
            }
            if let gitError = status.error {
                Text(gitError).font(.system(size: 11)).crowForeground(CrowTheme.danger)
                    .textSelection(.enabled).padding(.horizontal, 12)
                    .accessibilityIdentifier("crow.git-status-error")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(model.selectedWorkspaceID)-\(model.selectedWorkspace.connection)-\(refreshID)") {
            status.error = nil
            let state = model.current
            while !Task.isCancelled {
                do {
                    let result: RepositorySnapshot
                    #if os(macOS)
                    if let remote = state.systemSSH {
                        result = try await GitRepository.read(path: path, remote: remote)
                    } else if !state.snapshot.workspace.isRemote {
                        result = try await GitRepository.read(path: path)
                    } else {
                        guard let remote = state.remote else { throw FileFailure.disconnected }
                        result = try await remote.gitStatus(path: path)
                    }
                    #else
                    guard let remote = state.remote else { throw FileFailure.disconnected }
                    result = try await remote.gitStatus(path: path)
                    #endif
                    try Task.checkCancellation()
                    status.repository = result; status.error = nil
                } catch is CancellationError { return }
                catch { guard !Task.isCancelled else { return }; status.repository = nil; status.error = error.localizedDescription }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}
