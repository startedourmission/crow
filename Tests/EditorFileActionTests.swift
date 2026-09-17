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
    func testCloseOtherTabsKeepsClickedTabAndOtherPane() throws {
        let kept = try XCTUnwrap(model.selectedBuffer)
        let pane = try XCTUnwrap(model.current.snapshot.layout?.activePaneID)
        model.newTerminal()
        let terminal = try XCTUnwrap(model.current.snapshot.selectedTerminalID)
        model.splitTab(.terminal(terminal), in: pane, placement: .right)
        let otherPane = try XCTUnwrap(model.current.snapshot.layout?.panes.first { $0.id != pane })
        model.closeOtherTabs(except: .file(kept.id), in: pane)
        XCTAssertNil(model.closeOtherTabsRequest)
        XCTAssertEqual(model.current.snapshot.layout?.panes.first { $0.id == pane }?.tabs, [.file(kept.id)])
        XCTAssertEqual(model.current.snapshot.layout?.panes.first { $0.id == otherPane.id }, otherPane)
        XCTAssertFalse(model.current.snapshot.terminalIDs.contains(terminal))
        XCTAssertEqual(model.current.snapshot.layout?.activePane?.selected, .file(kept.id))
    }

    func testCloseOtherTabsWaitsForDirtyFilesAndCancelKeepsEverything() throws {
        let original = try XCTUnwrap(model.selectedBuffer)
        model.updateBufferText(original.id, "Do not lose this draft")
        let pane = try XCTUnwrap(model.current.snapshot.layout?.activePaneID)
        model.newTerminal()
        let kept = WorkspaceTab.terminal(try XCTUnwrap(model.current.snapshot.selectedTerminalID))
        let before = model.current.snapshot.layout
        model.closeOtherTabs(except: kept, in: pane)
        XCTAssertTrue(try XCTUnwrap(model.closeOtherTabsRequest).hasUnsavedFiles)
        XCTAssertEqual(model.current.snapshot.layout, before)
        model.closeOtherTabsRequest = nil
        XCTAssertEqual(model.current.snapshot.layout, before)
        XCTAssertEqual(model.buffers.first { $0.id == original.id }?.text, "Do not lose this draft")
    }

    func testSaveAndCloseOtherTabsKeepsNewTabsAndUsesOriginalWorkspace() async throws {
        let original = try XCTUnwrap(model.selectedBuffer)
        let source = model.current
        model.updateBufferText(original.id, "Saved before closing")
        let pane = try XCTUnwrap(source.snapshot.layout?.activePaneID)
        model.newTerminal()
        let kept = WorkspaceTab.terminal(try XCTUnwrap(source.snapshot.selectedTerminalID))
        model.closeOtherTabs(except: kept, in: pane)
        let request = try XCTUnwrap(model.closeOtherTabsRequest)
        model.newTerminal()
        let addedAfterRequest = try XCTUnwrap(source.snapshot.selectedTerminalID)
        let other = root.appendingPathComponent("another-workspace")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        model.openFolder(other)
        let destination = model.current
        let otherLayout = destination.snapshot.layout
        await model.confirmClosingOtherTabs(request, saveChanges: true)
        XCTAssertEqual(try String(contentsOfFile: original.path, encoding: .utf8), "Saved before closing")
        XCTAssertFalse(source.snapshot.buffers.contains { $0.id == original.id })
        XCTAssertTrue(source.snapshot.terminalIDs.contains(addedAfterRequest))
        XCTAssertTrue(model.current === destination)
        XCTAssertEqual(destination.snapshot.layout, otherLayout)
        XCTAssertEqual(source.snapshot.layout?.panes.first { $0.id == pane }?.selected, kept)
        XCTAssertEqual(source.snapshot.selectedTerminalID.map(WorkspaceTab.terminal), kept)
    }

    func testCloseOtherTabsKeepsDirtyFileOpenInAnotherSplit() throws {
        let file = try XCTUnwrap(model.selectedBuffer)
        let pane = try XCTUnwrap(model.current.snapshot.layout?.activePaneID)
        model.splitTab(.file(file.id), in: pane, placement: .right)
        model.activatePane(pane)
        model.newTerminal()
        let kept = WorkspaceTab.terminal(try XCTUnwrap(model.current.snapshot.selectedTerminalID))
        model.updateBufferText(file.id, "Shared draft")
        model.closeOtherTabs(except: kept, in: pane)
        XCTAssertNil(model.closeOtherTabsRequest)
        XCTAssertEqual(model.buffers.first { $0.id == file.id }?.text, "Shared draft")
        XCTAssertEqual(model.current.snapshot.layout?.allTabs.filter { $0 == .file(file.id) }.count, 1)
    }

    func testFailedSaveDoesNotCloseOtherTabs() async throws {
        let file = try XCTUnwrap(model.selectedBuffer)
        model.updateBufferText(file.id, "Unsaved draft")
        let pane = try XCTUnwrap(model.current.snapshot.layout?.activePaneID)
        model.newTerminal()
        let kept = WorkspaceTab.terminal(try XCTUnwrap(model.current.snapshot.selectedTerminalID))
        model.closeOtherTabs(except: kept, in: pane)
        let request = try XCTUnwrap(model.closeOtherTabsRequest)
        let before = model.current.snapshot.layout
        try FileManager.default.removeItem(atPath: file.path)
        try FileManager.default.createDirectory(atPath: file.path, withIntermediateDirectories: true)
        await model.confirmClosingOtherTabs(request, saveChanges: true)
        XCTAssertEqual(model.current.snapshot.layout, before)
        XCTAssertEqual(model.buffers.first { $0.id == file.id }?.text, "Unsaved draft")
    }

    func testCloseOtherTabsConfirmsWorkingAgentAndDiscardClosesTargets() async throws {
        let kept = try XCTUnwrap(model.selectedBuffer)
        let pane = try XCTUnwrap(model.current.snapshot.layout?.activePaneID)
        let id = try XCTUnwrap(model.newAgentTerminal(.claude))
        let session = model.terminal(id, in: model.current)
        session.running = true
        session.view.feed(text: "Working (esc to interrupt)\r\n")
        model.closeOtherTabs(except: .file(kept.id), in: pane)
        let request = try XCTUnwrap(model.closeOtherTabsRequest)
        XCTAssertTrue(request.hasWorkingTerminals)
        XCTAssertTrue(model.current.snapshot.terminalIDs.contains(id))
        await model.confirmClosingOtherTabs(request, saveChanges: false)
        XCTAssertFalse(model.current.snapshot.terminalIDs.contains(id))
        XCTAssertEqual(model.current.snapshot.layout?.panes.first { $0.id == pane }?.tabs, [.file(kept.id)])
    }

    #if os(macOS)
    func testCustomMenuFitsRowsAndDismissesBeforeInvokingAction() async throws {
        var actions: [String] = []
        let view = CrowActionMenuContent(dismiss: { actions.append("dismiss") }) {
            Button("Close Tab") { actions.append("close") }
            Button("Close Other Tabs", systemImage: "xmark.square") { actions.append("others") }
            Divider()
            Toggle("Show Hidden Files", isOn: .constant(true))
        }
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        XCTAssertEqual(size.width, 240, accuracy: 1)
        XCTAssertLessThan(size.height, 180, "A short menu should not reserve the maximum scrolling height")
        XCTAssertGreaterThan(size.height, 70)
        let longMenu = NSHostingView(rootView: CrowActionMenuContent(dismiss: {}) {
            ForEach(0..<80) { index in Button("Item \(index)") {} }
        })
        XCTAssertLessThanOrEqual(longMenu.fittingSize.height, 440)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        // Click the first row through AppKit, as a pointer user would.
        let point = hosting.convert(NSPoint(x: 60, y: 18), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(actions, ["dismiss", "close"])
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/crow-custom-menu.png"))
    }

    func testCustomContextMenuRoutesSecondaryClicksToRowWithoutStealingDrags() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = CrowContextMenuAnchorView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        list.regionSize = list.bounds.size
        window.contentView = list
        let row = CrowContextMenuAnchorView(frame: NSRect(x: 0, y: 0, width: 250, height: 30))
        row.regionSize = row.bounds.size
        list.addSubview(row)
        var rows = 0, backgrounds = 0
        row.present = { _ in rows += 1 }; list.present = { _ in backgrounds += 1 }
        func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = [], point: NSPoint? = nil) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point ?? row.convert(NSPoint(x: 12, y: 12), to: nil), modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        XCTAssertFalse(CrowContextMenuRouter.shared.route(try event(.leftMouseDown)))
        XCTAssertFalse(CrowContextMenuRouter.shared.route(try event(.leftMouseDragged)))
        XCTAssertTrue(CrowContextMenuRouter.shared.route(try event(.rightMouseDown)))
        XCTAssertEqual(rows, 1); XCTAssertEqual(backgrounds, 0)
        XCTAssertTrue(CrowContextMenuRouter.shared.route(try event(.leftMouseDown, modifiers: .control)))
        XCTAssertEqual(rows, 2)
        XCTAssertTrue(CrowContextMenuRouter.shared.route(try event(.rightMouseDown, point: list.convert(NSPoint(x: 280, y: 280), to: nil))))
        XCTAssertEqual(backgrounds, 1)
        row.isHidden = true
        XCTAssertTrue(CrowContextMenuRouter.shared.route(try event(.rightMouseDown)))
        XCTAssertEqual(rows, 2); XCTAssertEqual(backgrounds, 2)
        list.menuEnabled = false
        XCTAssertFalse(CrowContextMenuRouter.shared.route(try event(.rightMouseDown)))
    }
    #endif

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

    func testMarkdownWebLinksOpenBrowserInTheOwningWorkspace() throws {
        let id = try XCTUnwrap(model.selectedBufferID), state = model.current
        model.openMarkdownLink("https://example.com/docs", from: id)
        XCTAssertEqual(state.snapshot.browserAddresses.values.filter { $0 == "https://example.com/docs" }.count, 1)
        let count = state.snapshot.browserAddresses.count
        model.openMarkdownLink("javascript:alert(1)", from: id)
        model.openMarkdownLink("Other.md", from: id)
        XCTAssertEqual(state.snapshot.browserAddresses.count, count, "Unsafe schemes and disabled note links must not open tabs")
    }

    func testBaseInventoryUpdatesOnlySendChangedAndRemovedNotes() {
        var updates = ObsidianFiles.InventoryUpdates()
        let first: [[String: Any]] = [["path": "A.md", "text": "body", "modified": 1], ["path": "B.md", "text": "other"]]
        let initial = updates.payload(first)
        XCTAssertEqual(initial["incremental"] as? Bool, false)
        XCTAssertEqual((initial["files"] as? [[String: Any]])?.count, 2)
        let unchanged = updates.payload(first)
        XCTAssertEqual(unchanged["incremental"] as? Bool, true)
        XCTAssertEqual((unchanged["files"] as? [[String: Any]])?.count, 0)
        let changed = updates.payload([["path": "A.md", "text": "updated", "modified": 2]])
        XCTAssertEqual((changed["files"] as? [[String: Any]])?.first?["text"] as? String, "updated")
        XCTAssertEqual(changed["removed"] as? [String], ["B.md"])
    }

    func testBaseControlsSurviveLoadingAndEditFiltersSortAndProperties() async throws {
        let config = WKWebViewConfiguration()
        let scriptURL = try XCTUnwrap(Bundle.main.url(forResource: "obsidian-preview", withExtension: "js"))
        let styleURL = try XCTUnwrap(Bundle.main.url(forResource: "obsidian-preview", withExtension: "css"))
        let script = "window.messages=[]; window.webkit={messageHandlers:{obsidian:{postMessage:m=>window.messages.push(m)}}};\n" + (try String(contentsOf: scriptURL, encoding: .utf8))
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 940, height: 620), configuration: config)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(.init(x: -20000, y: -20000)); window.isReleasedWhenClosed = false
        window.contentView = view; window.orderBack(nil); defer { window.close() }
        view.loadHTMLString("<html><head><style>\(try String(contentsOf: styleURL, encoding: .utf8))</style></head><body><main></main></body></html>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await view.callAsyncJavaScript("return !!window.crowObsidian", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let result = try await view.callAsyncJavaScript(#"""
        const assert=(value,message)=>{if(!value)throw Error(message)};
        const click=label=>document.querySelector('button[aria-label="'+label+'"]').click();
        const apply=()=>[...document.querySelectorAll('.popover button')].find(b=>b.textContent==='Apply').click();
        let source='filters: \'file.ext == "md"\'\ncustom: preserved\nviews:\n - type: table\n   name: Reading\n   order: [file.name, status]\n - type: table\n   name: All\n   order: [file.name, status]\n';
        const files=Array.from({length:400},(_,i)=>({path:'Note '+i+'.md',text:'---\nstatus: reading\n---\nBody'}));
        const receive=(extra)=>window.crowObsidian.receive({source,kind:'base',path:'Notes.base',...extra});
        receive({files:files.slice(0,1),loading:true});
        const viewSelect=document.querySelector('.view-select'); viewSelect.focus();
        receive({files:files.slice(1,20),incremental:true,loading:true});
        assert(document.querySelector('.view-select')===viewSelect && document.activeElement===viewSelect,'Loading replaced the focused view picker');
        click('Filter');
        [...document.querySelectorAll('.popover button')].find(b=>b.textContent==='+ Condition').click();
        document.querySelector('[aria-label="Filter property"]').value='status';
        const value=document.querySelector('[aria-label="Filter value"]'); value.value='done'; value.focus();
        receive({files:files.slice(20),incremental:true});
        assert(document.querySelector('[aria-label="Filter value"]')===value && value.value==='done' && document.activeElement===value,'Loading discarded a filter draft');
        assert(document.querySelectorAll('tbody tr').length===100,'Large tables must render in bounded batches');
        assert(document.querySelector('.base-count').textContent==='400 results','All files must be counted');
        apply(); source=window.messages.filter(m=>m.action==='change').at(-1).source;
        assert(source.includes('custom: preserved') && source.includes('file.ext'),'Filters discarded existing settings');
        assert(!document.querySelector('tbody tr'),'Filter did not apply');
        receive({files:[{path:'Note 0.md',text:'---\nstatus: done\n---\nBody'}],incremental:true});
        assert(document.querySelectorAll('tbody tr').length===1,'An updated file must re-evaluate the filter');
        click('Properties');
        const panel=document.querySelector('.popover'), check=[...panel.querySelectorAll('label')].find(n=>n.textContent==='status').querySelector('input');
        check.click(); source=window.messages.filter(m=>m.action==='change').at(-1).source;
        assert(document.querySelector('.popover')===panel && document.querySelectorAll('thead th').length===1,'Toggling properties must keep its menu open');
        panel.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
        document.querySelector('[data-history=undo]').click(); source=window.messages.filter(m=>m.action==='change').at(-1).source;
        assert(document.querySelectorAll('thead th').length===2,'Undo must restore columns');
        assert(!document.querySelector('[data-history=redo]').disabled,'Redo must become available');
        viewSelect.value='1'; viewSelect.dispatchEvent(new Event('change'));
        assert(document.querySelectorAll('tbody tr').length===100,'Switching views must keep batching');
        const body=document.querySelector('.base-body'); body.scrollTop=body.scrollHeight; body.dispatchEvent(new Event('scroll'));
        assert(document.querySelectorAll('tbody tr').length===200,'Scrolling must reveal additional rows');
        const query=document.querySelector('.base-search'); query.value='Note 234'; query.dispatchEvent(new Event('input'));
        assert(document.querySelectorAll('tbody tr').length===1,'Search must cover rows beyond the rendered batch');
        query.value=''; query.dispatchEvent(new Event('input'));
        click('Sort'); [...document.querySelectorAll('.popover button')].find(b=>b.textContent==='+ Add sort').click();
        document.querySelector('[aria-label="Sort direction"]').value='DESC'; apply(); source=window.messages.filter(m=>m.action==='change').at(-1).source;
        assert(document.querySelector('tbody tr').dataset.path==='Note 399.md','Numeric descending sort failed');
        receive({files:[{path:'Broken.md',text:'---\nbad: [\n---'}],removed:['Note 399.md'],incremental:true});
        assert(document.querySelector('.warning').textContent.includes('Broken.md'),'Unreadable properties need a visible warning');
        assert(document.querySelector('.view-select')===viewSelect,'An unreadable note must not remove the view picker');
        assert(document.querySelector('tbody tr').dataset.path==='Note 398.md','Removed files must disappear');
        receive({files:[],incremental:true,loading:true}); window.crowObsidian.stopLoading(source,'Stopped');
        assert(!document.querySelector('.base-count').textContent.includes('Loading'),'Stopping must release the loading state');
        window.crowObsidian.failed('Connection interrupted');
        assert(document.querySelector('.view-select')===viewSelect && document.querySelector('.warning').textContent.includes('Connection interrupted'),'A load failure must retain usable controls');
        assert(!window.crowObsidian.validateBase({source:'views: [broken',path:'Notes.base'}),'Invalid definitions must report an error');
        receive({files});
        assert(document.querySelector('.view-select')?.isConnected && document.querySelectorAll('tbody tr').length===100,'Fixing a definition must remount its controls');
        return true;
        """#, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(result, true)
        _ = try await view.callAsyncJavaScript("document.querySelector('button[aria-label=Properties]').click()", arguments: [:], in: nil, contentWorld: .defaultClient)
        let image = try await view.takeSnapshot(configuration: nil)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/crow-base-properties.png"))
    }

    func testBaseInventoryReusesSnapshotAndReconcilesChangedAndDeletedFiles() async throws {
        let note = root.appendingPathComponent("Cached.md")
        try Data("---\nstatus: reading\n---\nBody".utf8).write(to: note)
        _ = try await ObsidianFiles.inventory(in: model.current)
        var initial: [[String: Any]]?
        let (unchanged, _) = try await ObsidianFiles.inventory(in: model.current) { files, _ in if initial == nil { initial = files } }
        XCTAssertEqual(initial?.count, unchanged.count, "Reopening must publish cached results before any IO")
        try Data("---\nstatus: done\n---\nChanged body".utf8).write(to: note)
        let (changed, _) = try await ObsidianFiles.inventory(in: model.current)
        XCTAssertTrue((changed.first { $0["path"] as? String == "Cached.md" }?["text"] as? String)?.contains("status: done") == true)
        try FileManager.default.removeItem(at: note)
        let (deleted, _) = try await ObsidianFiles.inventory(in: model.current)
        XCTAssertFalse(deleted.contains { $0["path"] as? String == "Cached.md" })
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
                const target=document.querySelector('[data-node-id=next] .node-port.left'), t=target.getBoundingClientRect(), tx=t.left+t.width/2, ty=t.top+t.height/2;
                viewport.dispatchEvent(new PointerEvent('pointermove',{pointerId:1,clientX:tx,clientY:ty}));
                if (getComputedStyle(target).opacity !== '1' || !target.classList.contains('connection-port')) throw Error('The target handle must appear and highlight during a captured drag');
                viewport.dispatchEvent(new PointerEvent('pointerup',{pointerId:1,clientX:tx,clientY:ty}));
                if (document.querySelector('.connecting,.connection-port')) throw Error('Connection highlights must be cleared after dropping');
                const cancelViewport=document.querySelector('.canvas-viewport'); cancelViewport.setPointerCapture=()=>{};
                const cancelPort=document.querySelector('[data-node-id=note] .node-port.right');
                cancelPort.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,pointerId:2,clientX:a.left,clientY:a.top}));
                cancelViewport.dispatchEvent(new PointerEvent('pointermove',{pointerId:2,clientX:tx,clientY:ty}));
                cancelViewport.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
                if (document.querySelector('.connecting,.connection-port,.pending-edge')) throw Error('Escape must cancel the pending connection');
                """)
                try await Task.sleep(for: .milliseconds(100))
                let moved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(model.selectedBuffer).text.utf8)) as? [String: Any])
                let nodes = try XCTUnwrap(moved["nodes"] as? [[String: Any]])
                let edited = try XCTUnwrap(nodes.first { $0["id"] as? String == "note" })
                XCTAssertGreaterThan(try XCTUnwrap(edited["x"] as? Int), -160)
                XCTAssertGreaterThan(try XCTUnwrap(edited["width"] as? Int), 300)
                XCTAssertEqual((moved["edges"] as? [Any])?.count, 2)
                XCTAssertEqual((moved["edges"] as? [[String: Any]])?.last?["toSide"] as? String, "left")
                try await js("document.querySelector('[data-action=add-note]').click()")
                let added = try await view.callAsyncJavaScript("return document.querySelectorAll('.node').length", arguments: [:], in: nil, contentWorld: .defaultClient) as? Int
                XCTAssertEqual(added, 4)
                try await js("document.activeElement.blur(); document.querySelector('[data-history=undo]').click()")
            } else {
                // Wait for the inventory's final payload before editing properties.
                for _ in 0..<100 {
                    if (try? await view.callAsyncJavaScript("return document.querySelector('.base-count').textContent.includes('Loading')", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool) == false { break }
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
            if name.hasSuffix("base") {
                try await js("document.querySelector('button[aria-label=\"New note\"]').click(); document.querySelector('dialog input').value='Created from Base'; document.querySelector('dialog form').dispatchEvent(new Event('submit',{cancelable:true}));")
                let created = root.appendingPathComponent("Created from Base.md")
                for _ in 0..<60 where !FileManager.default.fileExists(atPath: created.path) { try await Task.sleep(for: .milliseconds(25)) }
                XCTAssertTrue(FileManager.default.fileExists(atPath: created.path), "New must create a note beside the Base")
            }
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
