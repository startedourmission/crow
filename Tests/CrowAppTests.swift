import XCTest
import CrowCore
@testable import Crow

@MainActor final class FileExplorerTests: XCTestCase {
    private func entry(_ name: String, in parent: String = "/vault", directory: Bool = false) -> FileEntry {
        FileEntry(name: name, path: (parent as NSString).appendingPathComponent(name), isDirectory: directory)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the explorer")
    }
    func testLazyTreeExpansionCollapseAndCreationDirectory() async throws {
        let tree = FileExplorer(rootPath: "/vault")
        let folder = entry("Sources", directory: true), nested = entry("Nested", in: "/vault/Sources", directory: true)
        let file = entry("main.swift", in: nested.path)
        var reads: [String] = []
        tree.load = { path in
            reads.append(path)
            return path == "/vault" ? [self.entry("z.txt"), folder] : path == folder.path ? [nested] : [file]
        }
        await tree.refresh()
        XCTAssertEqual(reads, ["/vault"])
        XCTAssertEqual(tree.rows.map(\.entry.name), ["Sources", "z.txt"])
        await tree.toggle(folder); await tree.toggle(nested)
        XCTAssertEqual(tree.rows.map(\.depth), [0, 1, 2, 0])
        tree.selectedPath = nested.path
        XCTAssertEqual(tree.creationDirectory, nested.path)
        tree.selectedPath = file.path
        XCTAssertEqual(tree.creationDirectory, nested.path)
        await tree.toggle(folder)
        XCTAssertEqual(tree.rows.count, 2)
        await tree.toggle(folder)
        XCTAssertTrue(tree.rows.contains { $0.entry.path == file.path })
        tree.collapseAll()
        XCTAssertTrue(tree.expanded.isEmpty)
    }
    func testSearchInsideCollapsedFoldersAndRevealOnlyAncestors() async throws {
        let tree = FileExplorer(rootPath: "/vault")
        let folder = entry("docs", directory: true), nested = entry("notes", in: "/vault/docs", directory: true)
        let file = entry("한국어.md", in: nested.path)
        tree.load = { path in path == "/vault" ? [folder] : path == folder.path ? [nested] : [file] }
        await tree.refresh()
        tree.query = "한국어"
        try await waitUntil { !tree.isSearching }
        XCTAssertEqual(tree.results, [file])
        XCTAssertTrue(tree.expanded.isEmpty)
        tree.query = "not found"; tree.query = "docs/notes"
        try await waitUntil { !tree.isSearching }
        XCTAssertTrue(tree.results.contains(file))
        tree.query = ""
        await tree.toggle(folder); await tree.toggle(nested)
        XCTAssertEqual(tree.rows.map(\.entry.path), [folder.path, nested.path, file.path])
        tree.collapseAll()
        await tree.reveal(file)
        XCTAssertTrue(tree.expanded.contains(folder.path))
        XCTAssertTrue(tree.expanded.contains(nested.path))
        tree.stop()
    }
    func testRefreshReflectsExternalChangesAndPrunesDeletedBranches() async {
        let tree = FileExplorer(rootPath: "/vault")
        let folder = entry("folder", directory: true), file = entry("file.txt", in: folder.path)
        var rootEntries = [folder]
        tree.load = { path in path == "/vault" ? rootEntries : [file] }
        await tree.refresh(); await tree.toggle(folder)
        tree.selectedPath = file.path
        rootEntries = [entry("external.txt")]
        await tree.refresh()
        XCTAssertEqual(tree.rows.map(\.entry.name), ["external.txt"])
        XCTAssertNil(tree.selectedPath)
        XCTAssertFalse(tree.expanded.contains(folder.path))
        XCTAssertNil(tree.children[folder.path])
    }
    func testCollapseDuringFolderLoadNeverReopensItAndStaleVaultLoadsAreIgnored() async throws {
        let tree = FileExplorer(rootPath: "/vault")
        var reads = 0
        tree.load = { path in
            reads += 1
            try await Task.sleep(for: .milliseconds(80))
            return [self.entry("folder", in: path, directory: true)]
        }
        let pending = Task { await tree.toggle(self.entry("folder", directory: true)) }
        try await Task.sleep(for: .milliseconds(20))
        tree.collapseAll()
        await pending.value
        XCTAssertTrue(tree.expanded.isEmpty)
        let previousReads = reads
        tree.collapseAll() // Clicking again must not turn into an expand operation.
        XCTAssertTrue(tree.expanded.isEmpty)
        XCTAssertEqual(reads, previousReads)
        let oldLoad = Task { await tree.refresh() }
        try await Task.sleep(for: .milliseconds(20))
        tree.configure(rootPath: "/new") { _ in [] }
        await oldLoad.value
        XCTAssertTrue(tree.children.isEmpty)
    }
    func testUnreadableExpandedFolderDoesNotBlockOtherUpdates() async {
        let tree = FileExplorer(rootPath: "/vault")
        let folder = entry("private", directory: true)
        var denied = false
        tree.load = { path in
            if path == "/vault" { return denied ? [folder, self.entry("new.txt")] : [folder] }
            if denied { throw CocoaError(.fileReadNoPermission) }
            return []
        }
        await tree.refresh(); await tree.toggle(folder)
        denied = true
        await tree.refresh()
        XCTAssertTrue(tree.rows.contains { $0.entry.name == "new.txt" })
        XCTAssertNotNil(tree.errorMessage)
    }
    func testLocalScanRetainsHiddenMetadataAndDoesNotTraverseSymlinkLoops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-tree-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let entries = try FileExplorer.localEntries(root.path)
        XCTAssertTrue(try XCTUnwrap(entries.first { $0.name == ".hidden" }).isHidden)
        XCTAssertFalse(try XCTUnwrap(entries.first { $0.name == "loop" }).isDirectory)
    }

    func testHiddenSettingRefreshesTreeAndSearchWithoutAcceptingDotEntries() async throws {
        let tree = FileExplorer(rootPath: "/vault")
        let hidden = entry(".private", directory: true), file = entry("note.md", in: "/vault/.private")
        tree.load = { path in
            path == "/vault" ? [hidden, self.entry("visible.md"), self.entry(".", directory: true), self.entry("..", directory: true)] : [file]
        }
        await tree.refresh()
        XCTAssertEqual(tree.rows.map(\.entry.name), ["visible.md"])
        tree.query = "note"
        try await waitUntil { !tree.isSearching }
        XCTAssertTrue(tree.results.isEmpty)
        tree.showHiddenFiles = true
        try await waitUntil { tree.results == [file] && !tree.isSearching }
        tree.query = ""
        XCTAssertEqual(tree.rows.map(\.entry.name), [".private", "visible.md"])
        tree.showHiddenFiles = false
        try await waitUntil { tree.rows.map(\.entry.name) == ["visible.md"] }
        tree.stop()
    }
}

final class CrowAppTests: XCTestCase {
    // Generated solely for these tests; never used to access a server.
    private var hostEditorKey: String {
        """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACB+ZtlrnrQOWQ7t30+V4g3eyzjAaFq+UV/0bEjSlxYpFAAAAKBOEKHkThCh
        5AAAAAtzc2gtZWQyNTUxOQAAACB+ZtlrnrQOWQ7t30+V4g3eyzjAaFq+UV/0bEjSlxYpFA
        AAAEA2G7Y2YbfhqyHtM9Gr2pplS61CSH15VcSwvB2Umix9Hn5m2WuetA5ZDu3fT5XiDd7L
        OMBoWr5RX/RsSNKXFikUAAAAFmNyb3ctdGVzdC1maXh0dXJlLW9ubHkBAgMEBQYH
        -----END OPENSSH PRIVATE KEY-----
        """
    }

    @MainActor func testSavingManagedKeyHostStoresReferenceAndReplacesSystemCommand() throws {
        let model = fixture()
        let key = try SSHKeyStore.shared.generate(name: "Crow test " + UUID().uuidString)
        var host = SSHHost(name: "Managed key", hostname: "example.invalid", username: "test")
        host.authentication = .ed25519
        host.commandArguments = ["-i", "/old/key", "test@example.invalid"]
        host.commandDirectory = "/old/directory"
        defer {
            try? SecureStore.remove(host.id.rawValue.uuidString)
            try? SSHKeyStore.shared.remove(key.id, hosts: [])
        }
        try model.saveHostFromEditor(host, credential: HostCredential(keyID: key.id), connectAfterSaving: false)
        let savedHost = try XCTUnwrap(model.hosts.first(where: { $0.id == host.id }))
        XCTAssertNil(savedHost.commandArguments)
        XCTAssertNil(savedHost.commandDirectory)
        let saved = try SecureStore.credential(savedHost)
        XCTAssertEqual(saved.keyID, key.id)
        XCTAssertTrue(saved.privateKey.isEmpty)
        try saved.resolved(for: .ed25519).validatePrivateKey(for: .ed25519)
        XCTAssertThrowsError(try SSHKeyStore.shared.remove(key.id, hosts: model.hosts))
    }

    @MainActor func testSavingKeyHostRevealsHostsAndRestoresSavedCredentials() throws {
        let model = fixture(), selectedID = model.selectedWorkspaceID
        model.sidebarVisible = false
        var host = SSHHost(name: "  ", hostname: " server.example\n", username: " ubuntu ", remotePath: "")
        host.authentication = .ed25519
        defer { try? SecureStore.remove(host.id.rawValue.uuidString) }
        try model.saveHostFromEditor(host, credential: HostCredential(privateKey: hostEditorKey), connectAfterSaving: false)
        let saved = try XCTUnwrap(model.hosts.first)
        XCTAssertEqual(saved.hostname, "server.example")
        XCTAssertEqual(saved.name, "server.example")
        XCTAssertEqual(saved.username, "ubuntu")
        XCTAssertEqual(saved.remotePath, "~")
        XCTAssertEqual(model.compactSurface, .hosts)
        XCTAssertEqual(model.sidebarPane, .hosts)
        XCTAssertTrue(model.sidebarVisible)
        XCTAssertEqual(model.selectedWorkspaceID, selectedID)
        XCTAssertEqual(model.connectionState(for: saved), .disconnected)
        XCTAssertNil(model.pendingHostConnection)
        model.persist()
        let restored = AppModel(vaultURL: model.vaultURL)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.hosts.first, saved)
        XCTAssertEqual(try SecureStore.credential(saved).privateKey, hostEditorKey)
        XCTAssertFalse(try String(contentsOf: model.sessionURL, encoding: .utf8).contains("PRIVATE KEY"))

        try model.saveHostFromEditor(saved, credential: HostCredential(privateKey: hostEditorKey), connectAfterSaving: true)
        XCTAssertEqual(model.hosts.count, 1)
        XCTAssertEqual(model.pendingHostConnection, saved)
        XCTAssertEqual(model.connectionState(for: saved), .disconnected) // Wait for the sheet to close before presenting trust prompts.
    }

    @MainActor func testHostEditorRejectsMissingPublicAndWrongTypeKeysBeforeSaving() {
        let model = fixture()
        var host = SSHHost(name: "Test", hostname: "server.example", username: "ubuntu")
        host.authentication = .ed25519
        defer { try? SecureStore.remove(host.id.rawValue.uuidString) }
        for key in ["", "ssh-ed25519 AAAA public-key", "-----BEGIN OPENSSH PRIVATE KEY-----\ninvalid"] {
            XCTAssertThrowsError(try model.saveHostFromEditor(host, credential: HostCredential(privateKey: key), connectAfterSaving: true))
        }
        host.authentication = .rsa
        XCTAssertThrowsError(try model.saveHostFromEditor(host, credential: HostCredential(privateKey: hostEditorKey), connectAfterSaving: false))
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertNil(model.pendingHostConnection)
    }

    @MainActor func testKeyEditorWaitsForCommandSheetDismissalAndHostsNavigationStaysConsistent() {
        let model = fixture()
        model.sshCommandVisible = true
        model.editHost()
        XCTAssertFalse(model.sshCommandVisible)
        XCTAssertTrue(model.pendingHostEditor)
        XCTAssertFalse(model.hostEditorVisible)
        model.showHosts()
        XCTAssertEqual(model.sidebarPane, .hosts)
        model.compactSurface = .files
        XCTAssertEqual(model.sidebarPane, .files)
        model.showHosts()
        model.selectWorkspace(model.selectedWorkspaceID)
        XCTAssertEqual(model.compactSurface, .files)
        XCTAssertEqual(model.sidebarPane, .files)
    }

    #if os(iOS)
    @MainActor func testSSHCommandReusesSavedKeyWithoutRequestingPassword() async throws {
        let model = fixture()
        var host = SSHHost(name: "Saved key", hostname: "127.0.0.1", port: 1, username: "fixture")
        host.authentication = .ed25519
        defer { model.disconnect(host); try? SecureStore.remove(host.id.rawValue.uuidString) }
        try model.storeHost(host, credential: HostCredential(privateKey: hostEditorKey))
        model.sshCommandVisible = true
        try await model.connectCommand("ssh fixture@127.0.0.1 -p 1")
        XCTAssertNil(model.credentialRequest)
        XCTAssertNil(model.pendingCredentialRequest)
        XCTAssertEqual(model.selectedWorkspace.kind, .remote(hostID: host.id, path: host.remotePath))
        XCTAssertEqual(model.compactSurface, .terminal)
        XCTAssertEqual(try SecureStore.credential(host).privateKey, hostEditorKey)
    }
    #endif

    @MainActor func testExplorerMovePreservesDirtyBufferAndCanReturnToRoot() async throws {
        let model = fixture(), tree = model.current.explorer
        let root = model.vaultURL
        let folder = root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await tree.refresh()
        let buffer = try XCTUnwrap(model.selectedBuffer)
        model.updateBufferText(buffer.id, "unsaved moved text")
        let drag = ExplorerFileDrag(workspaceID: model.selectedWorkspaceID, path: buffer.path, isDirectory: false)
        XCTAssertTrue(model.canMoveFile(drag, to: folder.path))
        await model.moveFile(drag, to: folder.path).value
        let destination = folder.appendingPathComponent(buffer.title).path
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: buffer.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination))
        XCTAssertEqual(model.selectedBuffer?.path, destination)
        XCTAssertEqual(model.selectedBuffer?.text, "unsaved moved text")
        XCTAssertEqual(model.selectedBuffer?.isDirty, true)
        let saved = await model.saveBuffer(buffer.id)
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "unsaved moved text")
        await model.moveFile(.init(workspaceID: model.selectedWorkspaceID, path: destination, isDirectory: false), to: root.path).value
        XCTAssertEqual(model.selectedBuffer?.path, buffer.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: buffer.path))
    }
    @MainActor func testExplorerFolderMoveRemapsOpenDescendantsAndRejectsUnsafeTargets() async throws {
        let model = fixture(), tree = model.current.explorer, root = model.vaultURL
        let source = root.appendingPathComponent("Source"), child = source.appendingPathComponent("Child")
        let target = root.appendingPathComponent("Target")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        await tree.refresh()
        await tree.toggle(.init(name: "Source", path: source.path, isDirectory: true))
        await model.createEntry(name: "draft.md", directory: false, in: child.path).value
        let id = try XCTUnwrap(model.selectedBufferID)
        model.updateBufferText(id, "draft")
        let drag = ExplorerFileDrag(workspaceID: model.selectedWorkspaceID, path: source.path, isDirectory: true)
        XCTAssertFalse(model.canMoveFile(drag, to: source.path))
        XCTAssertFalse(model.canMoveFile(drag, to: child.path))
        XCTAssertFalse(model.canMoveFile(drag, to: root.path))
        XCTAssertFalse(model.canMoveFile(drag, to: root.deletingLastPathComponent().path))
        XCTAssertFalse(model.canMoveFile(.init(workspaceID: WorkspaceID(), path: source.path, isDirectory: true), to: target.path))
        await model.moveFile(drag, to: target.path).value
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.selectedBuffer?.path, target.path + "/Source/Child/draft.md")
        XCTAssertEqual(model.selectedBuffer?.text, "draft")
        XCTAssertTrue(tree.expanded.contains(target.path + "/Source/Child"))
        XCTAssertFalse(tree.expanded.contains(child.path))
    }
    @MainActor func testExplorerMoveNeverOverwritesExistingFileOrFollowsOutsideFolderAlias() async throws {
        let model = fixture(), tree = model.current.explorer, root = model.vaultURL
        let buffer = try XCTUnwrap(model.selectedBuffer)
        let folder = root.appendingPathComponent("Occupied")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent(buffer.title)
        try Data("keep me".utf8).write(to: existing)
        await tree.refresh()
        let drag = ExplorerFileDrag(workspaceID: model.selectedWorkspaceID, path: buffer.path, isDirectory: false)
        await model.moveFile(drag, to: folder.path).value
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me")
        XCTAssertTrue(FileManager.default.fileExists(atPath: buffer.path))
        model.errorMessage = nil
        let alias = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        await tree.refresh()
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.deletingLastPathComponent())
        // Simulate a directory replaced by a symlink after the explorer cached it.
        await model.moveFile(drag, to: alias.path).value
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: buffer.path))
        XCTAssertEqual(model.selectedBuffer?.path, buffer.path)
    }
    @MainActor func testUnifiedTabsProtectDirtyFileAndKeepTerminalWhenLastFileCloses() throws {
        let model = fixture()
        let file = try XCTUnwrap(model.selectedBufferID)
        let pane = try XCTUnwrap(model.current.snapshot.layout?.panes.first { $0.tabs.contains(.file(file)) })
        model.updateBufferText(file, "draft")
        model.closeTab(.file(file), in: pane.id)
        XCTAssertEqual(model.closeRequest, file)
        XCTAssertEqual(model.current.snapshot.layout?.panes.count, 2)
        model.closeRequest = nil
        model.discardBuffer(file)
        XCTAssertEqual(model.current.snapshot.layout?.panes.count, 1)
        XCTAssertTrue(model.current.snapshot.layout?.allTabs.allSatisfy { if case .terminal = $0 { return true }; return false } == true)
    }
    @MainActor func testMovingAndSplittingTabsPreservesDraftAndRestoresLayout() throws {
        let model = fixture()
        let file = try XCTUnwrap(model.selectedBufferID)
        let source = try XCTUnwrap(model.current.snapshot.layout?.panes.first { $0.tabs.contains(.file(file)) })
        let terminalPane = try XCTUnwrap(model.current.snapshot.layout?.panes.last)
        model.updateBufferText(file, "preserved draft")
        XCTAssertTrue(model.moveTab(.init(workspaceID: model.selectedWorkspaceID, paneID: source.id, tab: .file(file)),
            to: terminalPane.id, placement: .center))
        XCTAssertEqual(model.current.snapshot.layout?.panes.count, 1)
        model.splitTab(.file(file), in: terminalPane.id, placement: .right)
        let duplicate = try XCTUnwrap(model.current.snapshot.layout?.activePaneID)
        model.closeTab(.file(file), in: duplicate)
        XCTAssertNil(model.closeRequest) // Closing one view does not discard the shared draft.
        XCTAssertEqual(model.selectedBuffer?.text, "preserved draft")
        model.persist()
        let restored = AppModel(vaultURL: model.vaultURL)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.current.snapshot.layout, model.current.snapshot.layout)
        XCTAssertEqual(restored.selectedBuffer?.text, "preserved draft")
    }
    @MainActor func testNewTabPageDoesNotCreateTerminalAndRestoresBeforeChoosingContent() throws {
        let model = fixture()
        let paneID = try XCTUnwrap(model.current.snapshot.layout?.activePaneID)
        let terminals = model.current.snapshot.terminalIDs
        let buffers = model.buffers
        let instances = model.current.terminals.mapValues(\.instanceID)
        model.newTab(in: paneID)
        let first = try XCTUnwrap(model.current.snapshot.layout?.activePane?.selected)
        guard case .start = first else { return XCTFail("Plus must open a new tab page") }
        model.newTab(in: paneID)
        let second = try XCTUnwrap(model.current.snapshot.layout?.activePane?.selected)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.current.snapshot.terminalIDs, terminals)
        XCTAssertEqual(model.buffers, buffers)
        XCTAssertEqual(model.current.terminals.mapValues(\.instanceID), instances)
        model.persist()
        let restored = AppModel(vaultURL: model.vaultURL)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.current.snapshot.layout, model.current.snapshot.layout)
        restored.newTerminal()
        let layout = try XCTUnwrap(restored.current.snapshot.layout)
        XCTAssertEqual(layout.activePaneID, paneID)
        XCTAssertTrue(layout.allTabs.contains(first))
        XCTAssertFalse(layout.allTabs.contains(second), "Choosing content replaces only this new tab page")
        XCTAssertEqual(layout.activePane?.selected, restored.current.snapshot.selectedTerminalID.map(WorkspaceTab.terminal))
        XCTAssertEqual(restored.current.snapshot.terminalIDs.count, terminals.count + 1)
        restored.closeTab(first, in: paneID)
        XCTAssertNil(restored.closeRequest)
        XCTAssertNil(restored.terminalCloseRequest)
        XCTAssertFalse(restored.current.snapshot.layout?.allTabs.contains(first) == true)
    }

    @MainActor func testWorkspaceContextTerminalTargetsClickedVault() throws {
        let model = fixture(), original = model.current
        let other = WorkspaceState(.init(workspace: Workspace(name: "Other", kind: .local, connection: .local), rootPath: model.vaultURL.path))
        model.states.append(other)
        let originalIDs = original.snapshot.terminalIDs
        model.newTerminal(inWorkspace: other.id)
        XCTAssertEqual(model.selectedWorkspaceID, other.id)
        XCTAssertEqual(original.snapshot.terminalIDs, originalIDs)
        XCTAssertEqual(other.snapshot.terminalIDs.count, 2)
        XCTAssertEqual(other.snapshot.layout?.activePane?.selected, other.snapshot.selectedTerminalID.map(WorkspaceTab.terminal))
    }
    @MainActor func testTreeCreationAndRenamePreserveExpandedFolder() async throws {
        let model = fixture()
        await model.createEntry(name: "sub", directory: true).value
        let tree = model.current.explorer
        // Wait for the model's scheduled refresh before inspecting the tree.
        for _ in 0..<100 where tree.children[tree.rootPath]?.contains(where: { $0.name == "sub" }) != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        let folder = try XCTUnwrap(tree.children[tree.rootPath]?.first { $0.name == "sub" })
        tree.selectedPath = folder.path
        await model.createEntry(name: "note.md", directory: false, in: tree.creationDirectory).value
        XCTAssertEqual(model.selectedBuffer?.path, folder.path + "/note.md")
        XCTAssertTrue(tree.expanded.contains(folder.path))
        await model.rename(folder, to: "renamed").value
        XCTAssertTrue(tree.expanded.contains(tree.rootPath + "/renamed"))
        XCTAssertEqual(tree.selectedPath, tree.rootPath + "/renamed/note.md")
        XCTAssertEqual(model.selectedBuffer?.path, tree.rootPath + "/renamed/note.md")
    }
    @MainActor func testRemovingLastWorkspacePreservesFilesAndRestoresEmptyList() throws {
        let model = fixture()
        let state = model.current
        let file = try XCTUnwrap(model.selectedBuffer).path
        let original = try String(contentsOfFile: file, encoding: .utf8)
        let terminal = model.terminal(try XCTUnwrap(state.snapshot.selectedTerminalID), in: state)
        model.requestWorkspaceRemoval(state.id)
        XCTAssertEqual(model.workspaceRemovalRequest, state.id)
        model.workspaceRemovalRequest = nil // Cancel is non-destructive.
        XCTAssertEqual(model.states.count, 1)
        XCTAssertTrue(model.removeWorkspace(state.id))
        XCTAssertTrue(state.terminals.isEmpty)
        XCTAssertEqual(terminal.status, "Closed")
        XCTAssertFalse(model.hasWorkspace)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertTrue(model.buffers.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), original)
        let restored = AppModel(vaultURL: model.vaultURL)
        defer { restored.shutdown() }
        XCTAssertNil(restored.errorMessage)
        XCTAssertTrue(restored.workspaces.isEmpty)
        restored.refreshFiles()
        restored.newTerminal()
        XCTAssertTrue(restored.folderImporterVisible)
        XCTAssertTrue(restored.current.terminals.isEmpty)
        restored.openFolder(model.vaultURL)
        XCTAssertEqual(restored.workspaces.count, 1)
        XCTAssertFalse(restored.files.isEmpty)
    }

    @MainActor func testWorkspaceRemovalProtectsDraftsAndDiscardDoesNotDeleteFile() throws {
        let model = fixture()
        let buffer = try XCTUnwrap(model.selectedBuffer)
        let original = try String(contentsOfFile: buffer.path, encoding: .utf8)
        model.updateBufferText(buffer.id, "unsaved draft")
        XCTAssertFalse(model.removeWorkspace(model.selectedWorkspaceID))
        XCTAssertEqual(model.workspaceRemovalRequest, model.selectedWorkspaceID)
        XCTAssertEqual(model.selectedBuffer?.text, "unsaved draft")
        XCTAssertTrue(model.removeWorkspace(model.selectedWorkspaceID, discardChanges: true))
        XCTAssertEqual(try String(contentsOfFile: buffer.path, encoding: .utf8), original)
    }

    @MainActor func testSaveAndRemoveWorkspaceAndConflictProtection() async throws {
        let model = fixture()
        let id = model.selectedWorkspaceID
        let buffer = try XCTUnwrap(model.selectedBuffer)
        model.updateBufferText(buffer.id, "draft to save")
        try Data("external change".utf8).write(to: URL(fileURLWithPath: buffer.path))
        let rejected = await model.saveAndRemoveWorkspace(id)
        XCTAssertFalse(rejected)
        XCTAssertTrue(model.hasWorkspace)
        XCTAssertEqual(model.conflictRequest, buffer.id)
        XCTAssertEqual(model.selectedBuffer?.text, "draft to save")
        try Data(buffer.text.utf8).write(to: URL(fileURLWithPath: buffer.path))
        model.conflictRequest = nil
        let removed = await model.saveAndRemoveWorkspace(id)
        XCTAssertTrue(removed)
        XCTAssertEqual(try String(contentsOfFile: buffer.path, encoding: .utf8), "draft to save")
    }

    @MainActor func testRemovingUnselectedWorkspaceKeepsSelectionAndSelectedRemovalChoosesNeighbor() {
        let model = fixture()
        let first = model.selectedWorkspaceID
        let other = WorkspaceState(.init(workspace: Workspace(name: "Other", kind: .local, connection: .local), rootPath: model.vaultURL.path))
        let last = WorkspaceState(.init(workspace: Workspace(name: "Last", kind: .local, connection: .local), rootPath: model.vaultURL.path))
        model.states.append(contentsOf: [other, last])
        XCTAssertTrue(model.removeWorkspace(other.id))
        XCTAssertEqual(model.selectedWorkspaceID, first)
        XCTAssertTrue(model.removeWorkspace(first))
        XCTAssertEqual(model.selectedWorkspaceID, last.id)
        model.selectWorkspace(first) // A stale UI action cannot select a removed vault.
        XCTAssertEqual(model.selectedWorkspaceID, last.id)
    }

    @MainActor
    func testModelBootstrapsLocalWorkspace() {
        let model = fixture()
        XCTAssertFalse(model.workspaces.isEmpty)
        XCTAssertEqual(model.selectedWorkspace.kind, .local)
        XCTAssertFalse(model.files.isEmpty)
        XCTAssertFalse(model.canChooseRemoteProject)
    }

    @MainActor func testProjectPickerBelongsOnlyToRemoteWorkspaces() {
        let model = fixture(), localID = model.selectedWorkspaceID
        let host = SSHHost(name: "Remote", hostname: "example.invalid", username: "test")
        let state = WorkspaceState(.init(workspace: Workspace(name: "Remote", kind: .remote(hostID: host.id, path: "/project"), connection: .disconnected), rootPath: "/project"))
        model.states.append(state)
        model.selectWorkspace(state.id)
        XCTAssertTrue(model.canChooseRemoteProject)
        model.selectWorkspace(localID)
        XCTAssertFalse(model.canChooseRemoteProject)
        XCTAssertTrue(model.remoteTerminals(in: localID).isEmpty)
    }

    @MainActor private func fixture() -> AppModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crow-tests-" + UUID().uuidString)
        let model = AppModel(vaultURL: url)
        addTeardownBlock {
            await MainActor.run { model.shutdown() }
            try FileManager.default.removeItem(at: url)
        }
        return model
    }

    @MainActor func testWorkspaceTabsAndUnsavedDraftsStaySeparate() {
        let model = fixture()
        let local = model.selectedWorkspaceID
        let id = model.selectedBufferID!
        model.updateBufferText(id, "unsaved 한국어")
        let other = WorkspaceState(.init(workspace: Workspace(name: "Other", kind: .local, connection: .local), rootPath: model.vaultURL.path))
        model.states.append(other)
        model.selectWorkspace(other.id)
        XCTAssertTrue(model.buffers.isEmpty)
        model.selectWorkspace(local)
        XCTAssertEqual(model.selectedBuffer?.text, "unsaved 한국어")
        XCTAssertTrue(model.selectedBuffer!.isDirty)
    }

    @MainActor func testCloseRequiresDecisionAndCancelKeepsText() {
        let model = fixture(), id = model.selectedBufferID!
        model.updateBufferText(id, "draft")
        model.closeBuffer(id)
        XCTAssertEqual(model.closeRequest, id)
        XCTAssertEqual(model.selectedBuffer?.text, "draft")
        model.closeRequest = nil
        XCTAssertEqual(model.buffers.count, 1)
        model.discardBuffer(id)
        XCTAssertTrue(model.buffers.isEmpty)
    }

    @MainActor func testOpenFolderOutsideVaultAndSelectItsFile() throws {
        let model = fixture()
        let directory = model.vaultURL.deletingLastPathComponent().appendingPathComponent("crow-open-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("한글 파일.txt")
        try Data("opened from folder".utf8).write(to: file)
        model.openFolder(directory)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.current.snapshot.rootPath, directory.resolvingSymlinksInPath().path)
        let entry = try XCTUnwrap(model.files.first { $0.name == file.lastPathComponent })
        model.openFile(entry)
        XCTAssertEqual(model.selectedBuffer?.text, "opened from folder")
        let workspaceID = model.selectedWorkspaceID
        model.persist()
        let restored = AppModel(vaultURL: model.vaultURL)
        defer { restored.shutdown() }
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.selectedWorkspaceID, workspaceID)
        XCTAssertEqual(restored.current.snapshot.rootPath, directory.resolvingSymlinksInPath().path)
        XCTAssertEqual(restored.selectedBuffer?.text, "opened from folder")
        XCTAssertTrue(restored.files.contains { $0.name == file.lastPathComponent })
        let count = restored.workspaces.count
        restored.sidebarPane = .hosts
        restored.sidebarVisible = false
        restored.openFolder(directory)
        XCTAssertEqual(restored.workspaces.count, count)
        XCTAssertEqual(restored.selectedWorkspaceID, workspaceID)
        XCTAssertEqual(restored.sidebarPane, .files)
        XCTAssertTrue(restored.sidebarVisible)
    }

    @MainActor func testOpeningMissingFolderDoesNotCreateBrokenWorkspace() {
        let model = fixture(), count = model.workspaces.count
        let selectedID = model.selectedWorkspaceID
        model.openFolder(model.vaultURL.appendingPathComponent("missing-folder"))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.workspaces.count, count)
        XCTAssertEqual(model.selectedWorkspaceID, selectedID)
    }

    @MainActor func testRepickingFolderRenewsBookmarkWithoutDiscardingEdits() throws {
        let model = fixture()
        let directory = model.vaultURL.appendingPathComponent("AutoVault", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("note.md")
        try Data("saved".utf8).write(to: file)
        model.openFolder(directory)
        let workspaceID = model.selectedWorkspaceID, count = model.workspaces.count
        model.openFile(FileEntry(name: "note.md", path: file.path, isDirectory: false))
        let bufferID = try XCTUnwrap(model.selectedBufferID)
        model.updateBufferText(bufferID, "unsaved edit")
        let broken = Data("expired folder access".utf8)
        model.current.snapshot.bookmark = broken
        model.openFolder(directory)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.workspaces.count, count)
        XCTAssertEqual(model.selectedWorkspaceID, workspaceID)
        XCTAssertEqual(model.selectedBufferID, bufferID)
        XCTAssertEqual(model.selectedBuffer?.text, "unsaved edit")
        XCTAssertEqual(model.selectedBuffer?.isDirty, true)
        XCTAssertNotEqual(model.current.snapshot.bookmark, broken)
        model.persist()
        let restored = AppModel(vaultURL: model.vaultURL)
        defer { restored.shutdown() }
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.selectedWorkspaceID, workspaceID)
        XCTAssertEqual(restored.selectedBuffer?.text, "unsaved edit")
        XCTAssertEqual(try TextFiles.read(file), "saved")
    }

    #if os(macOS)
    @MainActor func testRestoreBrokenLegacyBookmarkUsingReadableSavedFolder() throws {
        let model = fixture()
        let directory = model.vaultURL.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        model.openFolder(directory)
        XCTAssertNil(model.errorMessage)
        let selectedID = model.selectedWorkspaceID
        model.current.snapshot.bookmark = Data("obsolete scoped bookmark".utf8)
        model.persist()
        let restored = AppModel(vaultURL: model.vaultURL)
        defer { restored.shutdown() }
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.selectedWorkspaceID, selectedID)
        XCTAssertEqual(restored.current.snapshot.rootPath, directory.path)
        var stale = false
        let bookmark = try XCTUnwrap(restored.current.snapshot.bookmark)
        let resolved = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolved.resolvingSymlinksInPath().path, directory.path)
    }
    #endif

    @MainActor func testSaveDetectsExternalChanges() async throws {
        let model = fixture(), id = model.selectedBufferID!
        let path = URL(fileURLWithPath: model.selectedBuffer!.path)
        model.updateBufferText(id, "edited")
        try Data("external".utf8).write(to: path)
        let saved = await model.saveBuffer(id)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.conflictRequest, id)
        XCTAssertEqual(try TextFiles.read(path), "external")
        XCTAssertTrue(model.selectedBuffer!.isDirty)
        let overwritten = await model.saveBuffer(id, overwrite: true)
        XCTAssertTrue(overwritten)
        XCTAssertEqual(try TextFiles.read(path), "edited")
        XCTAssertFalse(model.selectedBuffer!.isDirty)
    }

    @MainActor func testCreateNavigateRenameAndRecoverableDelete() async throws {
        let model = fixture()
        await model.createEntry(name: "subfolder", directory: true).value
        let folder = try XCTUnwrap(model.files.first { $0.name == "subfolder" })
        model.openFile(folder)
        await model.createEntry(name: "sample.json", directory: false).value
        XCTAssertEqual(model.selectedBuffer?.language, .json)
        let entry = try XCTUnwrap(model.files.first { $0.name == "sample.json" })
        await model.rename(entry, to: "renamed.txt").value
        XCTAssertEqual(model.selectedBuffer?.title, "renamed.txt")
        XCTAssertEqual(model.selectedBuffer?.language, .plain)
        let renamed = try XCTUnwrap(model.files.first { $0.name == "renamed.txt" })
        await model.trash(renamed).value
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        let trash = model.vaultURL.appendingPathComponent(".crow-trash")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)
        model.navigateUp()
        XCTAssertEqual(model.current.snapshot.directoryPath, model.vaultURL.path)
    }

    @MainActor func testInvalidNameAndBinaryFileDoNotOverwriteOrOpen() async throws {
        let model = fixture(), originalCount = model.buffers.count
        await model.createEntry(name: "../escape.txt", directory: false).value
        XCTAssertNotNil(model.errorMessage)
        let binary = model.vaultURL.appendingPathComponent("binary.dat")
        try Data([0, 0xff, 0x80]).write(to: binary)
        model.openFile(.init(name: "binary.dat", path: binary.path, isDirectory: false))
        XCTAssertEqual(model.buffers.count, originalCount)
        XCTAssertEqual(try Data(contentsOf: binary), Data([0, 0xff, 0x80]))
    }

    @MainActor func testRestoreDraftSettingsAndMultipleTerminalDescriptors() throws {
        let model = fixture(), id = model.selectedBufferID!
        model.updateBufferText(id, "restored draft")
        model.settings.fontSize = 21
        model.toggleSplit()
        model.newTerminal()
        model.current.snapshot.terminalSplit = true
        model.persist()
        let restored = AppModel(vaultURL: model.vaultURL)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.selectedBuffer?.text, "restored draft")
        XCTAssertTrue(restored.selectedBuffer!.isDirty)
        XCTAssertEqual(restored.settings.fontSize, 21)
        XCTAssertEqual(restored.current.snapshot.splitBufferID, id)
        XCTAssertEqual(restored.current.snapshot.terminalIDs.count, 2)
        XCTAssertTrue(restored.current.snapshot.terminalSplit)
        XCTAssertFalse(try TextFiles.read(URL(fileURLWithPath: restored.selectedBuffer!.path)).contains("restored draft"))
    }

    @MainActor func testDisconnectHostOnlyStopsItsWorkspaceAndPreservesDrafts() throws {
        let model = fixture()
        let host = SSHHost(name: "Target", hostname: "target.example", username: "fixture")
        let otherHost = SSHHost(name: "Other", hostname: "other.example", username: "fixture")
        XCTAssertEqual(model.connectionState(for: host), .disconnected)
        let target = WorkspaceState(.init(workspace: Workspace(name: host.name,
            kind: .remote(hostID: host.id, path: "/project"), connection: .connected), rootPath: "/project"))
        let other = WorkspaceState(.init(workspace: Workspace(name: otherHost.name,
            kind: .remote(hostID: otherHost.id, path: "/other"), connection: .connected), rootPath: "/other"))
        target.snapshot.buffers = [OpenBuffer(title: "draft.txt", path: "/project/draft.txt",
            text: "unsaved remote draft", language: .plain, isRemote: true, isDirty: true)]
        target.remote = RemoteConnection()
        #if os(macOS)
        target.systemSSH = SystemSSHSpec(host: host, socket: "/tmp/crow-test-unused.socket",
            arguments: [host.userAtHost], directory: model.vaultURL.path)
        #endif
        let terminalID = try XCTUnwrap(target.snapshot.terminalIDs.first)
        _ = model.terminal(terminalID, in: target)
        let pending = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        target.connectionTask = pending
        model.states.append(contentsOf: [target, other])
        model.selectedWorkspaceID = other.id
        XCTAssertEqual(model.connectionState(for: host), .connected)

        model.disconnect(host)

        XCTAssertEqual(model.connectionState(for: host), .disconnected)
        XCTAssertNil(target.remote)
        XCTAssertNil(target.connectionTask)
        XCTAssertTrue(pending.isCancelled)
        XCTAssertTrue(target.terminals.isEmpty)
        XCTAssertEqual(target.snapshot.buffers.first?.text, "unsaved remote draft")
        XCTAssertEqual(target.snapshot.buffers.first?.isDirty, true)
        XCTAssertEqual(model.connectionState(for: otherHost), .connected)
        XCTAssertEqual(model.selectedWorkspaceID, other.id)
        #if os(macOS)
        XCTAssertNil(target.systemSSH)
        XCTAssertNil(model.terminal(terminalID, in: target).systemSSH)
        #endif
    }

    @MainActor func testHostCredentialsUseKeychainNotSessionJSON() throws {
        let model = fixture()
        let host = SSHHost(name: "Saved", hostname: "localhost", username: "fixture", remotePath: "~")
        let secret = "test-only-" + UUID().uuidString
        defer { try? SecureStore.remove(host.id.rawValue.uuidString) }
        try model.storeHost(host, credential: HostCredential(password: secret))
        model.persist()
        XCTAssertEqual(try SecureStore.credential(host).password, secret)
        let session = try String(contentsOf: model.sessionURL, encoding: .utf8)
        XCTAssertFalse(session.contains(secret))
        XCTAssertTrue(session.contains("localhost"))
    }

    @MainActor func testUnreadableSessionIsPreservedBeforeStartingFresh() throws {
        let model = fixture()
        model.shutdown()
        let original = Data("{ unfinished draft snapshot".utf8)
        try original.write(to: model.sessionURL)
        let restored = AppModel(vaultURL: model.vaultURL)
        defer { restored.shutdown() }
        XCTAssertNotNil(restored.errorMessage)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: model.vaultURL,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("unreadable-") })
        restored.persist()
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertNoThrow(try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: restored.sessionURL)))
    }

    @MainActor func testVaultPathsFollowMovedAppContainerWithoutLosingDrafts() throws {
        let source = fixture(), destination = fixture()
        source.updateBufferText(source.selectedBufferID!, "draft survives container move")
        source.persist()
        try Data(contentsOf: source.sessionURL).write(to: destination.sessionURL)
        let restored = AppModel(vaultURL: destination.vaultURL)
        defer { restored.shutdown() }
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.current.snapshot.rootPath, destination.vaultURL.path)
        XCTAssertEqual(restored.selectedBuffer?.path, destination.vaultURL.appendingPathComponent("README.md").path)
        XCTAssertEqual(restored.selectedBuffer?.text, "draft survives container move")
        XCTAssertTrue(restored.selectedBuffer!.isDirty)
        XCTAssertFalse(restored.files.isEmpty)
    }

    @MainActor func testLegacyLabIsRemovedAndDraftsArePreservedInVault() throws {
        let model = fixture()
        XCTAssertFalse(model.workspaces.contains { $0.kind == .imeLab })
        var legacy = WorkspaceSnapshot(workspace: Workspace(name: "IME Lab", kind: .imeLab, connection: .local), rootPath: model.vaultURL.path)
        legacy.buffers = [OpenBuffer(title: "draft.txt", path: model.vaultURL.appendingPathComponent("draft.txt").path,
            text: "keep this draft", language: .plain, isRemote: false, isDirty: true)]
        model.states.append(WorkspaceState(legacy)); model.selectedWorkspaceID = legacy.workspace.id
        model.persist()
        let restored = AppModel(vaultURL: model.vaultURL)
        defer { restored.shutdown() }
        XCTAssertFalse(restored.workspaces.contains { $0.kind == .imeLab })
        XCTAssertTrue(restored.buffers.contains { $0.text == "keep this draft" && $0.isDirty })
    }
}
