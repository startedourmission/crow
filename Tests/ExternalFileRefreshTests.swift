import XCTest
import CrowCore
@testable import Crow

@MainActor final class ExternalFileRefreshTests: XCTestCase {
    private var model: AppModel!
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-refresh-test-" + UUID().uuidString)
        model = AppModel(vaultURL: root)
    }
    override func tearDown() async throws {
        model.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<80 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("External file change was not reflected")
    }
    func testObservedBufferReloadsAtomicAndInPlaceWritesWithoutReopening() async throws {
        let buffer = try XCTUnwrap(model.selectedBuffer)
        let task = Task { await model.observeBuffer(buffer.id) }
        defer { task.cancel() }
        let url = URL(fileURLWithPath: buffer.path)
        try Data("# Updated outside Crow\n".utf8).write(to: url, options: .atomic)
        try await wait { self.model.selectedBuffer?.text == "# Updated outside Crow\n" }
        XCTAssertEqual(model.selectedBuffer?.id, buffer.id)
        XCTAssertEqual(model.selectedBuffer?.savedText, "# Updated outside Crow\n")
        XCTAssertFalse(model.selectedBuffer!.isDirty)
        try Data("# Updated in place\n".utf8).write(to: url)
        try await wait { self.model.selectedBuffer?.text == "# Updated in place\n" }
    }
    func testDirtyDraftIsPreservedUntilExplicitReloadAndSaveStillDetectsConflict() async throws {
        let buffer = try XCTUnwrap(model.selectedBuffer)
        model.updateBufferText(buffer.id, "my unsaved draft")
        try Data("external change".utf8).write(to: URL(fileURLWithPath: buffer.path), options: .atomic)
        await model.refreshBufferFromSource(buffer.id)
        XCTAssertEqual(model.selectedBuffer?.text, "my unsaved draft")
        XCTAssertEqual(model.selectedBuffer?.savedText, buffer.savedText)
        XCTAssertTrue(model.externallyChangedBuffers.contains(buffer.id))
        let saved = await model.saveBuffer(buffer.id)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.conflictRequest, buffer.id)
        await model.refreshBufferFromSource(buffer.id, discardChanges: true)
        XCTAssertEqual(model.selectedBuffer?.text, "external change")
        XCTAssertFalse(model.selectedBuffer!.isDirty)
        XCTAssertFalse(model.externallyChangedBuffers.contains(buffer.id))
    }
    func testDeletedOrBinaryFileKeepsTextAndRecoversWhenFileReturns() async throws {
        let buffer = try XCTUnwrap(model.selectedBuffer), url = URL(fileURLWithPath: buffer.path)
        try FileManager.default.removeItem(at: url)
        await model.refreshBufferFromSource(buffer.id)
        XCTAssertEqual(model.selectedBuffer?.text, buffer.text)
        XCTAssertNotNil(model.externalFileErrors[buffer.id])
        try Data([0, 255, 0]).write(to: url)
        await model.refreshBufferFromSource(buffer.id)
        XCTAssertEqual(model.selectedBuffer?.text, buffer.text)
        try Data("restored".utf8).write(to: url)
        await model.refreshBufferFromSource(buffer.id)
        XCTAssertEqual(model.selectedBuffer?.text, "restored")
        XCTAssertNil(model.externalFileErrors[buffer.id])
    }
    func testResumeRechecksAndClosedBufferIsNotRecreated() async throws {
        let buffer = try XCTUnwrap(model.selectedBuffer), url = URL(fileURLWithPath: buffer.path)
        model.suspend()
        try Data("while backgrounded".utf8).write(to: url, options: .atomic)
        await model.refreshBufferFromSource(buffer.id)
        XCTAssertEqual(model.selectedBuffer?.text, buffer.text)
        model.resume()
        await model.refreshBufferFromSource(buffer.id)
        XCTAssertEqual(model.selectedBuffer?.text, "while backgrounded")
        model.discardBuffer(buffer.id)
        await model.refreshBufferFromSource(buffer.id)
        XCTAssertNil(model.locate(buffer.id))
    }
    func testImagePreviewRefreshPersistenceAndSaveProtection() async throws {
        let url = root.appendingPathComponent("사진 ' sample.PNG")
        let original = InputToolsTests.png
        try original.write(to: url)
        XCTAssertTrue(ImagePreview.supports(url.path))
        XCTAssertTrue(ImagePreview.supports("photo.jpg"))
        XCTAssertFalse(ImagePreview.supports("document.txt"))
        model.openFile(FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: false))
        let buffer = try XCTUnwrap(model.selectedBuffer)
        XCTAssertTrue(buffer.isImage)
        XCTAssertEqual(buffer.text, "")
        await model.refreshBufferFromSource(buffer.id)
        let first = try XCTUnwrap(model.imagePreviews[buffer.id])
        XCTAssertEqual(first.width, 1)
        XCTAssertEqual(first.height, 1)
        XCTAssertEqual(first.byteCount, original.count)
        model.updateBufferText(buffer.id, "must never overwrite binary content")
        let saved = await model.saveBuffer(buffer.id, overwrite: true)
        XCTAssertFalse(saved)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(model.selectedBuffer!.isDirty)
        model.openFile(FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: false))
        XCTAssertEqual(model.selectedBufferID, buffer.id)
        XCTAssertEqual(model.buffers.filter { $0.path == url.path }.count, 1)
        let restored = try JSONDecoder().decode(OpenBuffer.self, from: JSONEncoder().encode(buffer))
        XCTAssertTrue(restored.isImage)
        XCTAssertEqual(restored.path, url.path)
        let textBuffer = OpenBuffer(title: "legacy", path: "/legacy.txt", text: "old session", language: .plain, isRemote: false)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(textBuffer)) as? [String: Any])
        legacy.removeValue(forKey: "contentKind")
        XCTAssertFalse(try JSONDecoder().decode(OpenBuffer.self, from: JSONSerialization.data(withJSONObject: legacy)).isImage)
        try Data("broken image".utf8).write(to: url, options: .atomic)
        await model.refreshBufferFromSource(buffer.id, force: true)
        XCTAssertNotNil(model.externalFileErrors[buffer.id])
        XCTAssertEqual(model.imagePreviews[buffer.id]?.byteCount, first.byteCount, "Keep the previous preview during a failed update")
        let updated = original + Data(repeating: 0, count: 64)
        try updated.write(to: url, options: .atomic)
        await model.refreshBufferFromSource(buffer.id, force: true)
        XCTAssertNil(model.externalFileErrors[buffer.id])
        XCTAssertEqual(model.imagePreviews[buffer.id]?.byteCount, updated.count)
        model.discardBuffer(buffer.id)
        XCTAssertNil(model.imagePreviews[buffer.id])
        await model.refreshBufferFromSource(buffer.id)
        XCTAssertNil(model.imagePreviews[buffer.id])
    }

    func testOversizedAndInvalidImagesFailWithoutDecodingAsText() throws {
        let url = root.appendingPathComponent("large.png")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(ImagePreview.sizeLimit + 1))
        try file.close()
        XCTAssertThrowsError(try ImagePreview.read(url.path))
        XCTAssertThrowsError(try ImagePreview.decode(Data("not an image".utf8)))
    }

}


@MainActor enum ImagePreviewChecks {
    static func verifyRemote(_ connection: RemoteConnection, root: URL) async throws {
        let path = root.appendingPathComponent("원격 image ' preview.png")
        try InputToolsTests.png.write(to: path)
        let bytes = try await connection.readData(path.path, maximumSize: ImagePreview.sizeLimit)
        XCTAssertEqual(bytes, InputToolsTests.png)
        do {
            _ = try await connection.readData(path.path, maximumSize: 8)
            XCTFail("Binary reads must enforce their size limit")
        } catch FileFailure.tooLarge { }
        let packetPath = root.appendingPathComponent("binary-packets.bin")
        let packets = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
        try packets.write(to: packetPath)
        let packetRead = try await connection.readData(packetPath.path, maximumSize: packets.count)
        XCTAssertEqual(packetRead, packets, "Read binary bytes intact across SFTP packet boundaries")
        let model = AppModel(vaultURL: root.appendingPathComponent("image-test-" + UUID().uuidString))
        let state = WorkspaceState(.init(workspace: Workspace(name: "Preview", kind: .remote(hostID: HostID(), path: root.path),
            connection: .connected), rootPath: root.path))
        state.remote = connection; model.states.append(state); model.selectedWorkspaceID = state.id
        defer { state.remote = nil; model.shutdown() }
        model.openFile(FileEntry(name: path.lastPathComponent, path: path.path, isDirectory: false))
        let buffer = try XCTUnwrap(model.selectedBuffer)
        XCTAssertTrue(buffer.isImage)
        XCTAssertTrue(buffer.isRemote)
        await model.refreshBufferFromSource(buffer.id)
        XCTAssertNotNil(model.imagePreviews[buffer.id], model.externalFileErrors[buffer.id] ?? "Missing remote preview")
        let updated = InputToolsTests.png + Data(repeating: 0, count: 64)
        try updated.write(to: path, options: .atomic)
        await model.refreshBufferFromSource(buffer.id, force: true)
        XCTAssertEqual(model.imagePreviews[buffer.id]?.byteCount, updated.count)
        let saved = await model.saveBuffer(buffer.id, overwrite: true)
        XCTAssertFalse(saved)
        XCTAssertEqual(try Data(contentsOf: path), updated)
        var phase = "download original image"
        do {
            let download = try await model.downloadOpenFile(buffer.id)
            XCTAssertEqual(download, updated, "Download the original remote image bytes")
            let target = root.appendingPathComponent("image move destination " + UUID().uuidString)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            phase = "browse move destinations"
            let folders = try await model.fileMoveFolders(buffer.id, at: root.path)
            XCTAssertTrue(folders.folders.contains { $0.name == target.lastPathComponent })
            phase = "move image"
            try await model.moveOpenFile(buffer.id, to: target.path)
            XCTAssertEqual(URL(fileURLWithPath: model.selectedBuffer!.path).resolvingSymlinksInPath(), target.appendingPathComponent(path.lastPathComponent).resolvingSymlinksInPath())
            phase = "download moved image"
            let movedDownload = try await model.downloadOpenFile(buffer.id)
            XCTAssertEqual(movedDownload, updated)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        } catch {
            throw CommandError("Remote file action failed during \(phase): \(error)")
        }
    }
}
