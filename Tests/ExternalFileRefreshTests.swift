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
}
