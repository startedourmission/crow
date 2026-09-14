import XCTest
import CrowCore
@testable import Crow

@MainActor final class EditorFileActionTests: XCTestCase {
    private var model: AppModel!
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-file-actions-" + UUID().uuidString)
        model = AppModel(vaultURL: root)
    }
    override func tearDown() async throws {
        model.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func testDownloadPreservesOriginalImageAndTextEncodingAndExportsDraft() async throws {
        let image = root.appendingPathComponent("image.png")
        let bytes = InputToolsTests.png + Data([0, 255, 128])
        try bytes.write(to: image)
        model.openFile(.init(name: image.lastPathComponent, path: image.path, isDirectory: false))
        let imageID = try XCTUnwrap(model.selectedBufferID)
        let downloaded = try await model.downloadOpenFile(imageID)
        XCTAssertEqual(downloaded, bytes)
        let text = root.appendingPathComponent("note.txt")
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("line one\r\nline two\r\n".utf8)
        try original.write(to: text)
        model.openFile(.init(name: text.lastPathComponent, path: text.path, isDirectory: false))
        let textID = try XCTUnwrap(model.selectedBufferID)
        let clean = try await model.downloadOpenFile(textID)
        XCTAssertEqual(clean, original)
        model.updateBufferText(textID, "unsaved 한글")
        let draft = try await model.downloadOpenFile(textID)
        XCTAssertEqual(String(decoding: draft, as: UTF8.self), "unsaved 한글")
        XCTAssertEqual(try Data(contentsOf: text), original)
        model.discardBuffer(textID)
        do { _ = try await model.downloadOpenFile(textID); XCTFail("Closed file must fail") } catch {}
    }

    func testMoveOpenFilePreservesDraftAndNeverOverwritesDestination() async throws {
        let buffer = try XCTUnwrap(model.selectedBuffer)
        let folder = root.appendingPathComponent("Other folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let folders = try await model.fileMoveFolders(buffer.id, at: root.path)
        XCTAssertTrue(folders.folders.contains { $0.name == folder.lastPathComponent })
        model.updateBufferText(buffer.id, "my draft")
        try await model.moveOpenFile(buffer.id, to: folder.path)
        let moved = folder.appendingPathComponent(buffer.title)
        XCTAssertFalse(FileManager.default.fileExists(atPath: buffer.path))
        XCTAssertEqual(model.selectedBuffer?.path, moved.resolvingSymlinksInPath().path)
        XCTAssertEqual(model.selectedBuffer?.text, "my draft")
        XCTAssertTrue(model.selectedBuffer!.isDirty)
        try Data("do not overwrite".utf8).write(to: URL(fileURLWithPath: buffer.path))
        do { try await model.moveOpenFile(buffer.id, to: root.path); XCTFail("Must not overwrite") } catch {}
        XCTAssertEqual(try String(contentsOfFile: buffer.path, encoding: .utf8), "do not overwrite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        do { try await model.moveOpenFile(buffer.id, to: root.deletingLastPathComponent().path); XCTFail("Must stay in workspace") } catch {}
    }

    func testDownloadsRejectOversizedFileBeforeAllocatingContents() throws {
        let file = root.appendingPathComponent("large.png")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(FileDownload.sizeLimit + 1))
        try handle.close()
        XCTAssertThrowsError(try FileDownload.read(file.path))
    }
}
