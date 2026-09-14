import XCTest
import CrowCore
import SwiftUI
import WebKit
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

    func testObsidianInventoryAndLinksStayInOwningWorkspace() async throws {
        let folder = root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\nstatus: reading\n---\n# Note".utf8).write(to: folder.appendingPathComponent("Note.md"))
        let alias = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.deletingLastPathComponent())
        let (files, _) = try await ObsidianFiles.inventory(in: model.current)
        XCTAssertTrue(files.contains { $0["path"] as? String == "Notes/Note.md" && ($0["text"] as? String)?.contains("status: reading") == true })
        XCTAssertFalse(files.contains { ($0["path"] as? String)?.hasPrefix("escape/") == true })
        for path in ["../outside.txt", "escape/outside.txt", "/etc/passwd"] {
            do { _ = try await ObsidianFiles.resolve(path, in: model.current); XCTFail("Escaping links must fail") } catch {}
        }
        XCTAssertEqual(LanguageMode.infer(filename: "board.canvas"), .json)
        XCTAssertEqual(LanguageMode.infer(filename: "list.base"), .yaml)
    }

    #if os(macOS)
    func testFolderPathSuggestionsSupportTildeSpacesAndFoldersOnly() throws {
        for name in ["Project One", "Project Two", ".private"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("Project.txt"))
        XCTAssertEqual(try FolderPathCompletion.suggestions(for: "~/Pro", home: root.path), ["~/Project One/", "~/Project Two/"])
        XCTAssertEqual(try FolderPathCompletion.suggestions(for: "~/.", home: root.path), ["~/.private/"])
        XCTAssertFalse(try FolderPathCompletion.suggestions(for: root.path + "/").contains { $0.hasSuffix("Project.txt/") })
    }

    func testLocalFolderPickerIsVisibleAndCancelResetsPresentation() async throws {
        model.folderImporterVisible = true
        model.presentFolderPicker()
        let panel = try XCTUnwrap(model.folderSelectionPanel)
        defer { panel.cancel(nil) }
        for _ in 0..<30 where !panel.isVisible { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.canChooseDirectories); XCTAssertFalse(panel.canChooseFiles)
        XCTAssertNotNil(panel.accessoryView)
        model.presentFolderPicker()
        XCTAssertTrue(model.folderSelectionPanel === panel, "Repeated clicks must focus the existing picker")
        panel.cancel(nil)
        for _ in 0..<30 where model.folderSelectionPanel != nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(model.folderSelectionPanel); XCTAssertFalse(model.folderImporterVisible)
    }

    func testBaseInventoryPublishesBeforeCompletionAndHonorsCancellation() async throws {
        for index in 0..<50 { try Data("---\nstatus: reading\n---".utf8).write(to: root.appendingPathComponent("Note-\(index).md")) }
        let state = model.current
        var counts: [Int] = []
        let (files, _) = try await ObsidianFiles.inventory(in: state) { files, _ in counts.append(files.count) }
        XCTAssertEqual(counts.first, 0)
        XCTAssertTrue(counts.contains(1), "The first result must be published before scanning the whole workspace")
        XCTAssertGreaterThan(files.count, 49)
        let task = Task { _ = try await ObsidianFiles.inventory(in: state) { _, _ in try? await Task.sleep(for: .seconds(10)) } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled scans must stop, not swallow cancellation as a file error") }
        catch is CancellationError {}
    }

    func testObsidianWebViewsRenderCanvasAndBaseFromBundledResources() async throws {
        let node: [String: Any] = ["id": "note", "type": "text", "x": -100, "y": -50, "width": 250, "height": 150, "text": "# Canvas title"]
        let canvas = String(decoding: try JSONSerialization.data(withJSONObject: ["nodes": [node], "edges": []]), as: UTF8.self)
        for (name, source, selector) in [("Board.canvas", canvas, ".node.text"), ("Index.base", "views:\n  - type: table\n    name: Notes\n    order: [file.name]", "tbody tr")] {
            let file = root.appendingPathComponent(name)
            try Data(source.utf8).write(to: file)
            model.openFile(.init(name: name, path: file.path, isDirectory: false))
            let buffer = try XCTUnwrap(model.selectedBuffer)
            let hosting = NSHostingView(rootView: ObsidianDocumentView(buffer: buffer).environment(model))
            let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderBack(nil)
            defer { window.close() }
            func web(_ view: NSView) -> WKWebView? { if let value = view as? WKWebView { return value }; return view.subviews.lazy.compactMap { web($0) }.first }
            var rendered = false
            for _ in 0..<100 {
                if let view = web(hosting), let count = try? await view.callAsyncJavaScript("return document.querySelectorAll(selector).length", arguments: ["selector": selector], in: nil, contentWorld: .defaultClient) as? Int, count > 0 {
                    rendered = true; break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            if !rendered, let view = web(hosting) { print("PREVIEW", try await view.callAsyncJavaScript("return document.querySelector('main').textContent", arguments: [:], in: nil, contentWorld: .defaultClient) as Any) }
            XCTAssertTrue(rendered, "Expected rendered content for " + name)
        }
    }
    #endif

    func testExplorerPickerMovesUnopenedFolderIntoUnloadedDestination() async throws {
        let source = root.appendingPathComponent("Source"), destination = root.appendingPathComponent("Other/Nested")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("preserved".utf8).write(to: source.appendingPathComponent("note.txt"))
        let id = model.selectedWorkspaceID
        let folders = try await model.fileMoveFolders(workspaceID: id, at: destination.deletingLastPathComponent().path)
        XCTAssertTrue(folders.folders.contains { $0.name == "Nested" })
        try await model.moveExplorerFile(.init(workspaceID: id, path: source.path, isDirectory: true), to: destination.path)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Source/note.txt"), encoding: .utf8), "preserved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        do {
            try await model.moveExplorerFile(.init(workspaceID: WorkspaceID(), path: destination.path, isDirectory: true), to: root.path)
            XCTFail("Removed workspace must fail")
        } catch {}
    }

    func testDeleteProtectsDirtyFilesAndOutsideFolderAliases() async throws {
        let buffer = try XCTUnwrap(model.selectedBuffer)
        model.updateBufferText(buffer.id, "draft")
        for destination in FileDeletionDestination.allCases {
            model.settings.fileDeletionDestination = destination
            await model.trash(.init(name: buffer.title, path: buffer.path, isDirectory: false)).value
            XCTAssertTrue(FileManager.default.fileExists(atPath: buffer.path))
            XCTAssertEqual(model.selectedBuffer?.text, "draft")
            XCTAssertNotNil(model.errorMessage)
            model.errorMessage = nil
        }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("crow-delete-outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let file = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        await model.trash(.init(name: "keep.txt", path: alias.appendingPathComponent("keep.txt").path, isDirectory: false)).value
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
    }

    func testMarkdownDefaultsToRenderedAndSourcePreferencePersists() throws {
        XCTAssertTrue(model.markdownPreviewEnabled)
        let old = try JSONEncoder().encode(EditorSettings())
        XCTAssertTrue(try JSONDecoder().decode(EditorSettings.self, from: old).effectiveMarkdownPreviewEnabled)
        model.markdownPreviewEnabled = false
        let saved = try JSONEncoder().encode(model.settings)
        let restored = try JSONDecoder().decode(EditorSettings.self, from: saved)
        XCTAssertFalse(restored.effectiveMarkdownPreviewEnabled)
        model.settings = restored
        XCTAssertFalse(model.markdownPreviewEnabled)
    }

    func testDeletionPreferenceRoundTripsAndOldSettingsUseRecovery() throws {
        var settings = EditorSettings()
        let old = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(EditorSettings.self, from: old).effectiveFileDeletionDestination, .recovery)
        settings.fileDeletionDestination = .trash
        let saved = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(EditorSettings.self, from: saved).effectiveFileDeletionDestination, .trash)
    }

    #if os(macOS)
    func testDeleteUsesSystemTrashAndRemoteMacTrashCommandPreservesBytes() async throws {
        for remoteCommand in [false, true] {
            let name = "crow-trash-test-" + UUID().uuidString + " ' $.txt"
            let file = root.appendingPathComponent(name)
            try Data("recover me".utf8).write(to: file)
            let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: file, create: false)
            let recovered = trash.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: recovered) }
            if remoteCommand {
                _ = try await ReverseSSHCommand.run("/bin/sh", ["-c", RemoteConnection.trashCommand(path: file.path)], operation: "Trash test")
            } else {
                model.settings.fileDeletionDestination = .trash
                await model.trash(.init(name: name, path: file.path, isDirectory: false)).value
                XCTAssertNil(model.errorMessage)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(try String(contentsOf: recovered, encoding: .utf8), "recover me")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".crow/recovery").path))
        }
    }
    #endif

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
