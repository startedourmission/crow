import CrowCore
import SwiftUI

struct InspectorPanel: View {
    @Environment(AppModel.self) private var model
    private var tab: String { model.inspectorTab }
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

    private var gitScopeID: String { "\(model.selectedWorkspaceID)-\(model.current.contextRootPath)" }
    private var activeProject: String? { projectScope == gitScopeID ? selectedProject : nil }

    private var gitTaskID: String {
        "\(model.selectedWorkspaceID)-\(model.current.contextRootPath)-\(model.selectedWorkspace.connection)-\(tab)-\(refreshID)"
    }

    private var buffer: OpenBuffer? { model.inspectedBuffer }
    private let tabs = ["Files", "Agents", "Summary", "Git"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(tabs, id: \.self) { item in
                    Button { model.inspectorTab = item } label: {
                        Group {
                            if item == "Git" {
                                GitBranchIcon(selected: tab == item)
                            } else {
                                Image(systemName: item == "Files" ? "folder" : item == "Summary" ? "list.bullet.indent" : "bubble.left.and.bubble.right")
                            }
                        }
                            .font(.system(size: 11, weight: tab == item ? .semibold : .regular))
                            .crowForeground(tab == item ? CrowTheme.accent : CrowTheme.textDim)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }.windowDragExcluded()
                        .help(item)
                        .accessibilityLabel(item)
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
            if tab == "Files" { SidebarView(filesOnly: true) }
            else if tab == "Agents" { AgentHistoryPanel() }
            else if tab == "Summary" { summary }
            else { git }
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
            let state = model.current, path = state.contextRootPath
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
                Spacer(minLength: 0)
                GitRepositoryAccountFooter(repository: nil)
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
        let root = model.current.contextRootPath
        if path == root { return "This folder" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

private struct GitBranchIcon: View {
    @Environment(\.crowControlHovered) private var hovered
    let selected: Bool

    var body: some View {
        let color = selected ? CrowTheme.accent : CrowTheme.textDim
        GitBranchShape()
            .stroke(hovered ? CrowTheme.hoveredForeground(color) : color,
                    style: StrokeStyle(lineWidth: selected ? 1.2 : 1, lineCap: .round, lineJoin: .round))
            .frame(width: 13, height: 13)
    }
}

private struct GitBranchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 4, y: 7.5))
        path.addLine(to: CGPoint(x: 4, y: 8))
        path.addCurve(to: CGPoint(x: 9, y: 13), control1: CGPoint(x: 4, y: 11), control2: CGPoint(x: 6, y: 13))
        path.addLine(to: CGPoint(x: 15, y: 13))
        path.addCurve(to: CGPoint(x: 20, y: 8), control1: CGPoint(x: 18, y: 13), control2: CGPoint(x: 20, y: 11))
        path.addLine(to: CGPoint(x: 20, y: 7.5))
        path.move(to: CGPoint(x: 12, y: 13))
        path.addLine(to: CGPoint(x: 12, y: 16.5))
        for center in [CGPoint(x: 4, y: 4), CGPoint(x: 20, y: 4), CGPoint(x: 12, y: 20)] {
            path.addEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
        }
        // Leave room for the outline so none of the three nodes gets clipped.
        let scale = min(rect.width, rect.height) / 27
        return path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale)))
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GitRepositoryAccountFooter(repository: status.repository)
        }
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


private struct GitRepositoryAccountFooter: View {
    @Environment(AppModel.self) private var model
    let repository: RepositorySnapshot?
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            CrowDivider()
            VStack(alignment: .leading, spacing: 7) {
                if let repository {
                    if let remote = repository.remote {
                        Label(remote.displayAddress, systemImage: "network")
                            .textSelection(.enabled).help(remote.displayAddress)
                            .accessibilityIdentifier("crow.git-remote")
                        Text(remote.name + " · " + remote.transport)
                            .foregroundStyle(CrowTheme.textDim)
                    } else {
                        Label("No remote configured", systemImage: "network")
                            .foregroundStyle(CrowTheme.textDim)
                    }
                    if !repository.authorName.isEmpty || !repository.authorEmail.isEmpty {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repository.authorName.isEmpty ? "Commit author" : "Author · " + repository.authorName)
                                if !repository.authorEmail.isEmpty {
                                    Text(repository.authorEmail).foregroundStyle(CrowTheme.textDim)
                                }
                            }
                        } icon: { Image(systemName: "person") }
                        .textSelection(.enabled).help("Git commit author (user.name / user.email)")
                        .accessibilityIdentifier("crow.git-author")
                    }
                }
                Button { showingSettings = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle")
                        if let account = model.gitAccounts.account {
                            Text("Saved GitHub · @" + account.login)
                        } else {
                            Text(model.gitAccounts.storageError == nil ? "Set Up GitHub Account" : "Git Account Unavailable")
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "gearshape")
                    }.contentShape(Rectangle())
                }
                .buttonStyle(CrowButtonStyle()).help("Git Accounts")
                .accessibilityIdentifier("crow.git-account-settings")
            }.padding(.horizontal, 12).padding(.bottom, 12)
        }
        .font(.system(size: 11)).lineLimit(2).truncationMode(.middle)
        .background(CrowTheme.bg1)
        .onAppear { model.gitAccounts.reload() }
        .sheet(isPresented: $showingSettings) { GitSettingsView().environment(model) }
    }
}
