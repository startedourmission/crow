import XCTest
import CrowCore
@testable import Crow

final class CrowAppTests: XCTestCase {
    @MainActor
    func testModelBootstrapsLocalWorkspace() {
        let model = fixture()
        XCTAssertFalse(model.workspaces.isEmpty)
        XCTAssertEqual(model.selectedWorkspace.kind, .local)
        XCTAssertFalse(model.files.isEmpty)
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
