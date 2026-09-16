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

    func testBasePropertyWritesKeepOpenNotesInSyncAndRejectConflicts() async throws {
        let file = root.appendingPathComponent("Properties.md")
        let original = "---\nstatus: reading\n---\n# Keep this body\n"
        let edited = original.replacingOccurrences(of: "reading", with: "done")
        try Data(original.utf8).write(to: file)
        model.openFile(.init(name: file.lastPathComponent, path: file.path, isDirectory: false))
        let id = try XCTUnwrap(model.selectedBufferID), state = model.current
        try await ObsidianFiles.writeNote("Properties.md", expected: original, replacement: edited, in: state, model: model)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited)
        XCTAssertEqual(model.locate(id)?.0.snapshot.buffers[model.locate(id)!.1].text, edited)
        XCTAssertFalse(try XCTUnwrap(model.selectedBuffer).isDirty)
        model.updateBufferText(id, edited + "Unsaved draft")
        do {
            try await ObsidianFiles.writeNote("Properties.md", expected: edited, replacement: original, in: state, model: model)
            XCTFail("Property edits must not overwrite an unsaved note")
        } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited)
        model.updateBufferText(id, edited)
        try Data((edited + "External edit").utf8).write(to: file)
        do {
            try await ObsidianFiles.writeNote("Properties.md", expected: edited, replacement: original, in: state, model: model)
            XCTFail("Property edits must detect external changes")
        } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited + "External edit")
    }

    #if os(macOS)
    func testFolderSearchMatchesPartialNamesAndListsAllChildren() throws {
        for name in ["Project One", "Project Two", "Team Notes", "Archive", "Build", "한글 자료", ".hidden"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        XCTAssertEqual(try FolderPathCompletion.suggestions(for: "one", relativeTo: root.path), [root.path + "/Project One/"])
        XCTAssertEqual(try FolderPathCompletion.suggestions(for: "~/자료", home: root.path), ["~/한글 자료/"])
        XCTAssertEqual(try FolderPathCompletion.suggestions(for: "", relativeTo: root.path).count, 6)
        XCTAssertEqual(try FolderPathCompletion.suggestions(for: root.path + "/").count, 6)
        let query = FolderPathQuery("notes", relativeTo: "/srv/projects")
        XCTAssertEqual(query.directory, "/srv/projects")
        XCTAssertTrue(query.matches("Team Notes")); XCTAssertFalse(query.matches(".notes"))
        XCTAssertEqual(FolderPathQuery("~/", relativeTo: "/srv").directory, "~/")
        XCTAssertEqual(FolderPathQuery("~/proj", relativeTo: "/srv").directory, "~")
        XCTAssertTrue(FolderPathQuery("/srv/", relativeTo: "~").fragment.isEmpty)
    }

    func testFolderArrowSelectionAndTabUpdateTheActiveEditor() async throws {
        for name in ["Project One", "Project Two"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let panel = NSOpenPanel(), field = NSTextField(), editor = NSTextView()
        let value = FolderPathCompletion(panel: panel, initialDirectory: root.path)
        value.path = root.path + "/ject"; await value.refresh()
        let delegate = FolderPathInput.Coordinator(completion: value)
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(editor.string, root.path + "/Project Two/")
        XCTAssertEqual(field.stringValue, editor.string)
        var remotePath = "notes"
        let remote = FolderCompletionTextField(path: Binding(get: { remotePath }, set: { remotePath = $0 }),
            onComplete: { "/srv/Team Notes/" }, onMove: { _ in }, onSubmit: {})
        XCTAssertTrue(remote.makeCoordinator().control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(remotePath, "/srv/Team Notes/")
        XCTAssertEqual(editor.string, remotePath)
    }

    func testFolderPathNativeTabCompletesAndMovesPicker() async throws {
        let folder = root.appendingPathComponent("Project One")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        let value = FolderPathCompletion(panel: panel, initialDirectory: root.path)
        value.path = root.path + "/Pro"
        await value.refresh()
        let delegate = FolderPathInput.Coordinator(completion: value)
        XCTAssertTrue(delegate.control(NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(value.path, root.path + "/Project One/")
        XCTAssertEqual(panel.directoryURL?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
    }
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

    func testObsidianRenderedEditingSavesCanvasAndBaseProperties() async throws {
        let note = root.appendingPathComponent("Project.md")
        try Data("---\n# Preserve comment\nstatus: reading\n---\n# Project\nBody stays intact.\n".utf8).write(to: note)
        let canvas = """
        {"custom":{"preserved":true},"nodes":[
          {"id":"group","type":"group","x":-200,"y":-150,"width":840,"height":460,"label":"Project plan","color":"5"},
          {"id":"note","type":"text","x":-160,"y":-90,"width":300,"height":220,"text":"# Research\\n\\nCollect ideas and references."},
          {"id":"next","type":"text","x":280,"y":-90,"width":300,"height":220,"text":"# Build\\n\\n- Design\\n- Implement\\n- Review"}],
         "edges":[{"id":"edge","fromNode":"note","toNode":"next","label":"Next","fromSide":"right","toSide":"left"}]}
        """
        let base = "# Preserve view comment\nfilters: 'file.ext == \"md\"'\ncustom: kept\nviews:\n  - type: table\n    name: Notes\n    order: [file.name, status]\n"
        for (name, source, selector) in [("Editable.canvas", canvas, ".node.text"), ("Editable.base", base, "td[data-column='status'][data-path='Project.md']")] {
            let file = root.appendingPathComponent(name)
            try Data(source.utf8).write(to: file)
            model.openFile(.init(name: name, path: file.path, isDirectory: false))
            let buffer = try XCTUnwrap(model.selectedBuffer)
            let hosting = NSHostingView(rootView: ObsidianDocumentView(buffer: buffer).environment(model))
            let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 940, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderBack(nil)
            defer { window.close() }
            func web(_ view: NSView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap { web($0) }.first }
            var loaded: WKWebView?
            for _ in 0..<100 {
                if let view = web(hosting), let count = try? await view.callAsyncJavaScript("return document.querySelectorAll(selector).length", arguments: ["selector": selector], in: nil, contentWorld: .defaultClient) as? Int, count > 0 {
                    loaded = view; break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let view = try XCTUnwrap(loaded)
            func js(_ script: String) async throws { _ = try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) }
            if name.hasSuffix("canvas") {
                try await js("document.querySelector('[data-node-id=note]').dispatchEvent(new MouseEvent('dblclick', {bubbles:true})); const input=document.querySelector('.node-editor'); input.value='# Research complete\\n\\n한글 편집 저장'; input.dispatchEvent(new Event('input')); input.blur();")
                for _ in 0..<40 where model.locate(buffer.id)?.0.snapshot.buffers[model.locate(buffer.id)!.1].isDirty != true { try await Task.sleep(for: .milliseconds(25)) }
                try await js("document.querySelector('button[aria-label=\"Save (⌘S)\"]').click()")
                for _ in 0..<60 where !(try String(contentsOf: file, encoding: .utf8)).contains("Research complete") { try await Task.sleep(for: .milliseconds(25)) }
                let saved = try String(contentsOf: file, encoding: .utf8)
                XCTAssertTrue(saved.contains("한글 편집 저장")); XCTAssertTrue(saved.contains("preserved"))
                try await js("document.querySelector('[data-history=undo]').click()")
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertFalse(try XCTUnwrap(model.selectedBuffer).text.contains("Research complete"))
                try await js("document.querySelector('[data-history=redo]').click()")
                // The initial fit must survive SwiftUI layout and rapid document updates.
                try await Task.sleep(for: .milliseconds(100))
                let fitted = try await view.callAsyncJavaScript("const v=document.querySelector('.canvas-viewport').getBoundingClientRect(); return [...document.querySelectorAll('.node')].every(n=>{const r=n.getBoundingClientRect(); return r.left>=v.left && r.right<=v.right && r.top>=v.top && r.bottom<=v.bottom})", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
                XCTAssertEqual(fitted, true)
                // Synthetic pointer events exercise the same move/resize/connect handlers;
                // pointer capture itself requires hardware input, so stub only that method.
                try await js("""
                function drag(selector, dx, dy) {
                  const viewport=document.querySelector('.canvas-viewport'); viewport.setPointerCapture=()=>{};
                  const target=document.querySelector(selector), r=target.getBoundingClientRect(), x=r.left+r.width/2, y=r.top+r.height/2;
                  target.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,pointerId:1,clientX:x,clientY:y}));
                  viewport.dispatchEvent(new PointerEvent('pointermove',{pointerId:1,clientX:x+dx,clientY:y+dy}));
                  viewport.dispatchEvent(new PointerEvent('pointerup',{pointerId:1,clientX:x+dx,clientY:y+dy}));
                }
                drag('[data-node-id=note] .node-bar',24,12);
                drag('[data-node-id=note] .node-resize',20,10);
                const viewport=document.querySelector('.canvas-viewport'); viewport.setPointerCapture=()=>{};
                const port=document.querySelector('[data-node-id=note] .node-port.right'), a=port.getBoundingClientRect(), b=document.querySelector('[data-node-id=next] .node-bar').getBoundingClientRect();
                if (document.elementFromPoint(b.left+20,b.top+10)?.closest('[data-node-id]')?.dataset.nodeId !== 'next') throw Error('Connection target is not hit-testable');
                port.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,pointerId:1,clientX:a.left,clientY:a.top}));
                viewport.dispatchEvent(new PointerEvent('pointerup',{pointerId:1,clientX:b.left+20,clientY:b.top+10}));
                """)
                try await Task.sleep(for: .milliseconds(100))
                let moved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(model.selectedBuffer).text.utf8)) as? [String: Any])
                let nodes = try XCTUnwrap(moved["nodes"] as? [[String: Any]])
                let edited = try XCTUnwrap(nodes.first { $0["id"] as? String == "note" })
                XCTAssertGreaterThan(try XCTUnwrap(edited["x"] as? Int), -160)
                XCTAssertGreaterThan(try XCTUnwrap(edited["width"] as? Int), 300)
                XCTAssertEqual((moved["edges"] as? [Any])?.count, 2)
                try await js("document.querySelector('[data-action=add-note]').click()")
                let added = try await view.callAsyncJavaScript("return document.querySelectorAll('.node').length", arguments: [:], in: nil, contentWorld: .defaultClient) as? Int
                XCTAssertEqual(added, 4)
                try await js("document.activeElement.blur(); document.querySelector('[data-history=undo]').click()")
            } else {
                // Wait for the inventory's final payload before editing properties.
                for _ in 0..<100 {
                    if (try? await view.callAsyncJavaScript("return document.querySelector('.base-subhead').textContent.includes('Loading')", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool) == false { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try await js("document.querySelector(\"td[data-column=status][data-path='Project.md']\").dispatchEvent(new MouseEvent('dblclick')); const input=document.querySelector('[data-property-editor=status]'); input.value='done'; input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));")
                for _ in 0..<80 where !(try String(contentsOf: note, encoding: .utf8)).contains("status: done") { try await Task.sleep(for: .milliseconds(50)) }
                let saved = try String(contentsOf: note, encoding: .utf8)
                XCTAssertTrue(saved.contains("status: done")); XCTAssertTrue(saved.contains("# Preserve comment")); XCTAssertTrue(saved.hasSuffix("# Project\nBody stays intact.\n"))
                try await js("document.querySelector('button[aria-label=\"View options\"]').click(); document.querySelector('dialog input').value='Project notes'; Array.from(document.querySelectorAll('dialog button')).find(b=>b.textContent==='Apply').click();")
                try await js("document.querySelector('button[aria-label=\"Save (⌘S)\"]').click()")
                for _ in 0..<60 where !(try String(contentsOf: file, encoding: .utf8)).contains("Project notes") { try await Task.sleep(for: .milliseconds(25)) }
                let definition = try String(contentsOf: file, encoding: .utf8)
                XCTAssertTrue(definition.contains("Project notes")); XCTAssertTrue(definition.contains("custom: kept")); XCTAssertTrue(definition.contains("# Preserve view comment"))
                try await js("document.querySelector('button[aria-label=\"Add view\"]').click(); document.querySelector('dialog input').value='Cards'; document.querySelector('dialog select').value='cards'; Array.from(document.querySelectorAll('dialog button')).find(b=>b.textContent==='Create view').click();")
                try await Task.sleep(for: .milliseconds(100))
                let count = try await view.callAsyncJavaScript("return document.querySelectorAll('.view-select option').length", arguments: [:], in: nil, contentWorld: .defaultClient) as? Int
                XCTAssertEqual(count, 2)
                XCTAssertTrue(try XCTUnwrap(model.selectedBuffer).text.contains("type: cards"))
                try await js("document.querySelector('[data-history=undo]').click()")
            }
            try await Task.sleep(for: .milliseconds(250))
            let image = try await view.takeSnapshot(configuration: nil)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: name.hasSuffix("canvas") ? "/tmp/crow-canvas-editor.png" : "/tmp/crow-base-editor.png"))
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
