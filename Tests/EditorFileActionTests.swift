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
    func testRenderedFilenameRenamesFileWithoutChangingMarkdownOrLosingDraft() async throws {
        let file = root.appendingPathComponent("Original.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = "---\ntags: [test]\n---\n\n# Body heading\n\nOriginal body\n"
        try Data(saved.utf8).write(to: file)
        model.openFolder(root); model.openFile(.init(name: file.lastPathComponent, path: file.path, isDirectory: false))
        let id = try XCTUnwrap(model.selectedBufferID)
        let draft = saved + "Unsaved body edit\n"
        model.updateBufferText(id, draft)
        let hosting = NSHostingView(rootView: MarkdownTitleFixture(id: id).environment(model))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 800, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func web(_ view: NSView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap { web($0) }.first }
        var loaded: WKWebView?
        for _ in 0..<150 {
            if let view = web(hosting), (try? await view.callAsyncJavaScript("return document.querySelector('.note-file-title')?.value === 'Original' && !!document.querySelector('.frontmatter-heading')", arguments: [:], in: nil, contentWorld: .defaultClient)) as? Bool == true { loaded = view; break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let view = try XCTUnwrap(loaded)
        let wraps = try await view.callAsyncJavaScript("const t=document.querySelector('.note-file-title');t.focus();t.value='긴 제목이 오른쪽에서 잘리지 않고 여러 줄로 모두 보여야 합니다 '.repeat(10);t.dispatchEvent(new Event('input'));await new Promise(r=>setTimeout(r,50));const good=t.clientHeight>parseFloat(getComputedStyle(t).lineHeight)*2&&t.scrollWidth<=t.clientWidth+1;t.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return good", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(wraps, true)
        _ = try await view.callAsyncJavaScript("const title=document.querySelector('.note-file-title');title.focus();title.value='새 제목';title.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));", arguments: [:], in: nil, contentWorld: .defaultClient)
        for _ in 0..<100 where model.selectedBuffer?.title != "새 제목.md" { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(model.selectedBuffer?.title, "새 제목.md")
        XCTAssertEqual(model.selectedBufferID, id)
        XCTAssertEqual(model.selectedBuffer?.text, draft)
        XCTAssertEqual(model.selectedBuffer?.isDirty, true)
        XCTAssertEqual(try TextFiles.read(root.appendingPathComponent("새 제목.md")), saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let size = try await view.callAsyncJavaScript("return parseFloat(getComputedStyle(document.querySelector('.frontmatter-heading')).fontSize)", arguments: [:], in: nil, contentWorld: .defaultClient) as? Double
        XCTAssertEqual(size, 11)
        try Data("Keep existing".utf8).write(to: root.appendingPathComponent("Taken.md"))
        _ = try await view.callAsyncJavaScript("const title=document.querySelector('.note-file-title');title.focus();title.value='Taken';title.blur();", arguments: [:], in: nil, contentWorld: .defaultClient)
        for _ in 0..<100 {
            if (try? await view.callAsyncJavaScript("return !!document.querySelector('.note-title-error')?.textContent", arguments: [:], in: nil, contentWorld: .defaultClient)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(model.selectedBuffer?.title, "새 제목.md")
        XCTAssertEqual(try TextFiles.read(root.appendingPathComponent("Taken.md")), "Keep existing")
    }

    func testCrowmapRenameKeepsNodeIDsAndRewritesProjectAndBodyLinks() throws {
        let store = CrowmapStore(root: root.appendingPathComponent("Crowmap"))
        try store.create("Map")
        let old = "Project-Research.md", renamed = "Project-Discovery.md"
        let body = "---\ntitle: Research\ndate: 2026-09-18\n---\n\nKeep body\n"
        try Data(body.utf8).write(to: store.noteURL(old))
        let links = "---\nmilestones: ['[[Project-Research]]']\n---\n[[Project-Research#Heading|alias]] ![[Project-Research.md]] [[Unrelated]]"
        let start = try store.noteURL("Project.md"); try Data(links.utf8).write(to: start)
        var doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(store.source.utf8)) as? [String: Any])
        doc["anchors"] = [["id": "same-node", "note": old]]
        try JSONSerialization.data(withJSONObject: doc).write(to: try XCTUnwrap(store.selected))
        let replacement = body.replacingOccurrences(of: "title: Research", with: "title: Discovery")
        let changes = try store.renameNote(old, to: renamed, source: replacement)
        XCTAssertEqual(try TextFiles.read(store.noteURL(renamed)), replacement)
        XCTAssertTrue(try TextFiles.read(start).contains("[[Project-Discovery#Heading|alias]]"))
        XCTAssertTrue(try TextFiles.read(start).contains("![[Project-Discovery.md]] [[Unrelated]]"))
        XCTAssertTrue(changes[start.path]?.contains("milestones: ['[[Project-Discovery]]']") == true)
        try store.load(try XCTUnwrap(store.selected))
        let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(store.source.utf8)) as? [String: Any])
        XCTAssertEqual((updated["anchors"] as? [[String: String]])?.first, ["id": "same-node", "note": renamed])
        XCTAssertThrowsError(try store.renameNote(renamed, to: "Project.md"))
        XCTAssertEqual(try TextFiles.read(store.noteURL(renamed)), replacement)
    }

    func testCrowmapDockKeepsWebViewsAcrossWorkspaceAndVisibilityChanges() async throws {
        model.crowmap = CrowmapStore(root: root.appendingPathComponent("Crowmap"))
        let workspace = model.current, layout = workspace.snapshot.layout
        let hosting = NSHostingView(rootView: CrowmapClickFixture().environment(model).windowDragBackground())
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1148, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        model.showCrowmap(); model.createCrowmap()
        let first = try XCTUnwrap(model.crowmapTabs.first)
        XCTAssertEqual(workspace.snapshot.layout, layout)
        XCTAssertEqual(model.crowmapPanel.selectedPath, first.id)
        func webs(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webs($0) } }
        var loaded: WKWebView?
        for _ in 0..<150 {
            if let view = webs(hosting).first, (try? await view.callAsyncJavaScript("return !!document.querySelector('.map-toolbar')", arguments: [:], in: nil, contentWorld: .defaultClient)) as? Bool == true { loaded = view; break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let view = try XCTUnwrap(loaded)
        for count in 1...2 {
            _ = try await view.callAsyncJavaScript("document.querySelector('[aria-label=\"Add timeline\"]').click()", arguments: [:], in: nil, contentWorld: .defaultClient)
            var projects = 0
            for _ in 0..<100 {
                let doc = try JSONSerialization.jsonObject(with: Data(first.store.source.utf8)) as? [String: Any]
                projects = (doc?["projects"] as? [Any])?.count ?? 0
                if projects == count { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertEqual(projects, count)
        }
        let color = try await view.callAsyncJavaScript("return getComputedStyle(document.querySelector('.map-viewport')).backgroundColor", arguments: [:], in: nil, contentWorld: .defaultClient) as? String
        XCTAssertEqual(color, "rgb(255, 255, 255)")
        _ = try await view.callAsyncJavaScript("window.dockIdentity = 'first'; document.querySelector('.anchor').dispatchEvent(new MouseEvent('click',{bubbles:true}));", arguments: [:], in: nil, contentWorld: .defaultClient)
        try await Task.sleep(for: .milliseconds(100))
        model.createCrowmap()
        let second = try XCTUnwrap(model.crowmapTabs.last)
        XCTAssertNotEqual(first.id, second.id)
        model.hideCrowmapPanel()
        let other = root.appendingPathComponent("other-workspace")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        model.openFolder(other)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(webs(hosting).contains { $0 === view }, "Hiding and workspace switching retain the map WebView")
        model.openCrowmap(first.url)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(webs(hosting).contains { $0 === view })
        let retained = try await view.callAsyncJavaScript("return window.dockIdentity === 'first' && !!document.querySelector('.map-popup .note-markdown')", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(retained, true, "The embedded note stays open across map switches")
        XCTAssertEqual(model.current.snapshot.rootPath, other.path)
        XCTAssertEqual(model.crowmapTabs.count, 2)
        model.closeCrowmapTab(second.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.crowmapTabs.map(\.id), [first.id])
    }

    func testCrowmapFoldersIsolateNotesAndRecognizeMovedLegacyMapPaths() throws {
        let store = CrowmapStore(root: root.appendingPathComponent("Maps"))
        try store.create("First")
        let first = try XCTUnwrap(store.selected)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "First")
        try Data("First note".utf8).write(to: store.noteURL("Same.md"))
        try store.create("Second")
        try Data("Second note".utf8).write(to: store.noteURL("Same.md"))
        try store.load(first)
        XCTAssertEqual(store.library["Same.md"], "First note")
        XCTAssertEqual(store.maps.count, 2)
        try store.load(store.root.appendingPathComponent("First.crowmap"))
        XCTAssertEqual(store.selected, first)
        XCTAssertEqual(store.library.count, 1)
    }

    func testCrowmapStorageIsFlatAndRejectsStaleOrEscapingWrites() throws {
        let directory = root.appendingPathComponent("Crowmap")
        let store = CrowmapStore(root: directory)
        try store.create("Plans")
        let original = store.source
        let note = "work.md"
        var doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        doc["notes"] = [["id": "note", "note": note]]
        let source = String(decoding: try JSONSerialization.data(withJSONObject: doc), as: UTF8.self)
        try store.save(source, expected: original, writes: [["name": note, "text": "---\ndate: 2026-09-17\n---\nWork"]])
        XCTAssertEqual(store.texts[note], "---\ndate: 2026-09-17\n---\nWork")
        XCTAssertThrowsError(try store.noteURL("../outside.md"))
        XCTAssertThrowsError(try store.noteURL("folder/note.md"))
        XCTAssertThrowsError(try store.save(original, expected: original, writes: []))
        let before = store.source
        try Data("External edit".utf8).write(to: directory.appendingPathComponent(note))
        XCTAssertThrowsError(try store.save(source, expected: before, writes: [["name": note, "expected": "Old note", "text": "overwrite"]]))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(note), encoding: .utf8), "External edit")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(store.selected), encoding: .utf8), before)
    }

    func testCrowmapTimelineDeletionRequiresCompleteScopeAndPreservesStaleFiles() throws {
        let store = CrowmapStore(root: root.appendingPathComponent("Crowmap")); try store.create("Delete")
        var doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(store.source.utf8)) as? [String: Any])
        doc["projects"] = [["id": "project", "route": ["start", "end"]]]
        doc["anchors"] = [["id": "start", "project": "project", "note": "Start.md"], ["id": "end", "project": "project", "note": "End.md"]]
        doc["notes"] = [["id": "work", "note": "Work.md"]]
        let source = String(decoding: try JSONSerialization.data(withJSONObject: doc), as: UTF8.self)
        let names = ["Start.md", "End.md", "Work.md"]
        try store.save(source, expected: store.source, writes: names.map { ["name": $0, "text": $0 + " body"] })
        for key in ["projects", "anchors", "notes"] { doc[key] = [] as [String] }
        let empty = String(decoding: try JSONSerialization.data(withJSONObject: doc), as: UTF8.self)
        let deletes = names.map { ["name": $0, "expected": $0 + " body"] }
        XCTAssertThrowsError(try store.save(empty, expected: source, writes: [], deletes: deletes))
        XCTAssertThrowsError(try store.save(empty, expected: source, writes: [], deletes: [deletes[0]], deletingProject: "project"))
        try Data("Changed externally".utf8).write(to: store.noteURL("End.md"))
        XCTAssertThrowsError(try store.save(empty, expected: source, writes: [], deletes: deletes, deletingProject: "project"))
        XCTAssertEqual(store.source, source)
        XCTAssertTrue(names.allSatisfy { FileManager.default.fileExists(atPath: store.noteRoot.appendingPathComponent($0).path) })
        try Data("End.md body".utf8).write(to: store.noteURL("End.md"))
        try store.save(empty, expected: source, writes: [], deletes: deletes, deletingProject: "project")
        XCTAssertTrue(store.library.isEmpty)
        let trash = store.root.deletingLastPathComponent().appendingPathComponent("crowmap-deleted")
        let retained = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(try retained.map { try TextFiles.read($0) }), Set(names.map { $0 + " body" }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.selected).path))
    }

    func testCrowmapCopiesMarkdownFilesWithoutFollowingLinks() throws {
        let store = CrowmapStore(root: root.appendingPathComponent("Crowmap")); try store.create("Copy")
        let first = try store.noteURL("First.md"), second = try store.noteURL("Second.md")
        try Data("[[Second]]".utf8).write(to: first); try Data("Body".utf8).write(to: second)
        XCTAssertEqual(try store.copyFileURLs([["name": "First.md", "expected": "[[Second]]"]]), [first])
        XCTAssertEqual(try store.copyFileURLs([["name": "First.md", "expected": "[[Second]]"], ["name": "Second.md", "expected": "Body"]]), [first, second])
        XCTAssertThrowsError(try store.copyFileURLs([["name": "First.md", "expected": "Stale"]]))
        XCTAssertThrowsError(try store.copyFileURLs([["name": "../outside.md", "expected": ""]]))
        let remote = try XCTUnwrap(store.copyFileURLs([["name": "Remote.md", "text": "Remote body"]]).first)
        defer { try? FileManager.default.removeItem(at: remote.deletingLastPathComponent()) }
        XCTAssertEqual(try TextFiles.read(remote), "Remote body")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.noteRoot.appendingPathComponent("Remote.md").path))
    }

    func testCrowmapAgentSessionsLinkOnlySelectedOriginalNotes() throws {
        let store = CrowmapStore(root: root.appendingPathComponent("Crowmap"))
        try store.create("Agents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.noteRoot.appendingPathComponent("AGENTS.md").path))
        XCTAssertNil(store.library["AGENTS.md"])
        var doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(store.source.utf8)) as? [String: Any])
        doc["notes"] = [["id": "first", "note": "First.md"], ["id": "second", "note": "Second.md"]]
        let replacement = String(decoding: try JSONSerialization.data(withJSONObject: doc), as: UTF8.self)
        try store.save(replacement, expected: store.source, writes: [["name": "First.md", "text": "First"], ["name": "Second.md", "text": "Second"]])
        let session = try store.prepareAgentSession(nodeIDs: ["first"])
        XCTAssertEqual(session.deletingLastPathComponent(), store.noteRoot.appendingPathComponent(".sessions", isDirectory: true))
        let link = session.appendingPathComponent("notes/First.md")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), try store.noteURL("First.md").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("notes/Second.md").path))
        let target = link.resolvingSymlinksInPath()
        try Data("Agent edit".utf8).write(to: target)
        XCTAssertEqual(try TextFiles.read(store.noteURL("First.md")), "Agent edit")
        XCTAssertTrue(try TextFiles.read(session.appendingPathComponent("AGENTS.md")).contains("notes/First.md"))
        XCTAssertThrowsError(try store.prepareAgentSession(nodeIDs: ["missing"]))
        XCTAssertThrowsError(try store.noteURL("AGENTS.md"))
        let custom = store.noteRoot.appendingPathComponent("AGENTS.md")
        try Data("Custom instructions".utf8).write(to: custom)
        try store.load(try XCTUnwrap(store.selected))
        XCTAssertEqual(try TextFiles.read(custom), "Custom instructions")
        XCTAssertEqual(store.library.count, 2)
        let legacy = """
        - inactive_next lists outgoing next links retained as faded history. Each project
          has one active route from its start. A new branch preserves old notes and marks
          the former outgoing path inactive; a later shared milestone can rejoin both paths.
          Legacy revision notes may also have replaces links describing the historical path.
        """
        try Data(("Custom preface\n" + legacy + "\nCustom ending").utf8).write(to: custom)
        try store.load(try XCTUnwrap(store.selected))
        let migrated = try TextFiles.read(custom)
        XCTAssertTrue(migrated.hasPrefix("Custom preface\n")); XCTAssertTrue(migrated.hasSuffix("\nCustom ending"))
        XCTAssertTrue(migrated.contains("Every milestone with an incoming or outgoing timeline edge is a main milestone"))
        XCTAssertFalse(migrated.contains("one active route"))
    }

    func testCrowmapImportsMarkdownFromEmptyCacheAndPreparesAgentWithoutRewritingNotes() async throws {
        model.crowmap = CrowmapStore(root: root.appendingPathComponent("Maps")); try model.crowmap.create("Imported")
        let store = model.crowmap
        let texts = [
            "Project.md": "---\nkind: start\ntitle: Project\ndate: 2026-09-01\npriority: 1\nmilestones: ['[[Done]]']\nnext: ['[[Done]]']\nprevious: []\ncustom: Keep me # comment\n---\nStart body\n",
            "Done.md": "---\nkind: milestone\ntitle: Done\ndate: 2026-09-20\npriority: 1\nproject: '[[Project]]'\nprevious: ['[[Project]]']\nnext: []\n---\nDone body\n",
            "Work.md": "---\ntitle: Work\ndate: 2026-09-10\nbetween: ['[[Project]]', '[[Done]]']\n---\nWork body\n"
        ]
        for (name, text) in texts { try Data(text.utf8).write(to: store.noteRoot.appendingPathComponent(name)) }
        try store.load(try XCTUnwrap(store.selected))
        let hosting = NSHostingView(rootView: CrowmapSurface(store: store).environment(model))
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 1100, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderBack(nil); defer { window.close() }
        func web(_ view: NSView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap { web($0) }.first }
        var loaded: WKWebView?
        for _ in 0..<150 {
            if let view = web(hosting), (try? await view.callAsyncJavaScript("return document.querySelectorAll('.anchor').length===2 && document.querySelectorAll('.work-note').length===1", arguments: [:], in: nil, contentWorld: .defaultClient)) as? Bool == true { loaded = view; break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let view = try XCTUnwrap(loaded)
        for _ in 0..<100 where store.texts.count != 3 { try await Task.sleep(for: .milliseconds(20)) }
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(store.source.utf8)) as? [String: Any])
        XCTAssertEqual((document["projects"] as? [Any])?.count, 1)
        let notes = try XCTUnwrap(document["notes"] as? [[String: Any]])
        let noteID = try XCTUnwrap(notes.first?["id"] as? String)
        let session = try store.prepareAgentSession(nodeIDs: [noteID])
        XCTAssertEqual(try TextFiles.read(session.appendingPathComponent("notes/Work.md")), texts["Work.md"])
        for (name, text) in texts { XCTAssertEqual(try TextFiles.read(store.noteRoot.appendingPathComponent(name)), text) }
        let saved = store.source
        _ = try await view.callAsyncJavaScript("document.querySelector('[aria-label=\"Refresh map\"]').click()", arguments: [:], in: nil, contentWorld: .defaultClient)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.source, saved, "Refreshing a discovered map does not change identities or keep resaving")
    }

    func testCrowmapZoomKeepsViewportCenterAndPointerAnchored() async throws {
        let store = CrowmapStore(root: root.appendingPathComponent("Zoom maps"))
        try store.create("Zoom")
        for index in 1...10 {
            let texts = [
                "Project \(index).md": "---\nkind: start\ndate: 2026-01-01\npriority: \(index)\nmilestones: ['[[Done \(index)]]']\nnext: ['[[Done \(index)]]']\n---\n",
                "Done \(index).md": "---\nkind: milestone\ndate: 2026-12-01\npriority: \(index)\nproject: '[[Project \(index)]]'\nprevious: ['[[Project \(index)]]']\nnext: []\n---\n"
            ]
            for (name, text) in texts { try Data(text.utf8).write(to: store.noteRoot.appendingPathComponent(name)) }
        }
        try store.load(try XCTUnwrap(store.selected))
        let hosting = NSHostingView(rootView: CrowmapSurface(store: store).environment(model))
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 1000, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderBack(nil); defer { window.close() }
        func web(_ view: NSView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap { web($0) }.first }
        var loaded: WKWebView?
        for _ in 0..<150 {
            if let view = web(hosting), (try? await view.callAsyncJavaScript("return document.querySelectorAll('.anchor').length===20", arguments: [:], in: nil, contentWorld: .defaultClient)) as? Bool == true { loaded = view; break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let view = try XCTUnwrap(loaded)
        let failures = try await view.callAsyncJavaScript(#"""
        const viewport=document.querySelector('.map-viewport'),canvas=viewport.querySelector(':scope > svg'),failures=[];
        const button=label=>document.querySelector(`[aria-label="${label}"]`).click();
        const scale=()=>canvas.getBoundingClientRect().width/canvas.viewBox.baseVal.width;
        while(scale()<2)button('Zoom in');
        viewport.scrollLeft=(viewport.scrollWidth-viewport.clientWidth)*.5;
        viewport.scrollTop=(viewport.scrollHeight-viewport.clientHeight)*.5;
        const rect=viewport.getBoundingClientRect();
        function check(label,x,y,action){
            const screen=new DOMPoint(rect.left+x,rect.top+y),world=screen.matrixTransform(canvas.getScreenCTM().inverse()),before=scale();
            action();
            const after=world.matrixTransform(canvas.getScreenCTM()),drift=Math.hypot(after.x-screen.x,after.y-screen.y);
            if(drift>1.5||scale()===before)failures.push(`${label}: drift=${drift}, scale=${before} -> ${scale()}`);
        }
        check('Button in',viewport.clientWidth/2,viewport.clientHeight/2,()=>button('Zoom in'));
        check('Button out',viewport.clientWidth/2,viewport.clientHeight/2,()=>button('Zoom out'));
        for(const selector of ['.anchor circle','.anchor-title','.date-label','.edge-hit']){
            for(const deltaY of [-12,12]){
                const x=viewport.clientWidth*.38,y=viewport.clientHeight*.42;
                check(selector+' '+deltaY,x,y,()=>document.querySelector(selector).dispatchEvent(new WheelEvent('wheel',{
                    bubbles:true,cancelable:true,clientX:rect.left+x,clientY:rect.top+y,deltaY,
                    ctrlKey:deltaY<0,metaKey:deltaY>0
                })));
            }
        }
        // The old scroll offset exceeds the new maximum during a shrink, but the
        // anchored final offset is valid. Capture it before the browser clamps it.
        viewport.scrollLeft=canvas.getBoundingClientRect().width*.8-viewport.clientWidth+10;
        viewport.scrollTop=canvas.getBoundingClientRect().height*.8-viewport.clientHeight+10;
        check('Shrink near boundary',viewport.clientWidth/2,viewport.clientHeight/2,()=>button('Zoom out'));
        button('Fit timeline');
        if(viewport.scrollLeft!==0||viewport.scrollTop!==0||canvas.getBoundingClientRect().width>viewport.clientWidth)failures.push('Fit did not reset the view');
        return failures;
        """#, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String]
        XCTAssertEqual(try XCTUnwrap(failures), [])
    }

    func testCrowmapCreatesProjectSegmentWorkAndRejoiningPlanOnDisk() async throws {
        model.crowmap = CrowmapStore(root: root.appendingPathComponent("Crowmap"))
        try model.crowmap.create("Project map")
        let hosting = NSHostingView(rootView: CrowmapSurface(store: model.crowmap).environment(model))
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 1200, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderBack(nil); defer { window.close() }
        func web(_ view: NSView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap { web($0) }.first }
        var loaded: WKWebView?
        for _ in 0..<100 {
            if let view = web(hosting), (try? await view.callAsyncJavaScript("return !!document.querySelector('.map-toolbar')", arguments: [:], in: nil, contentWorld: .defaultClient)) as? Bool == true { loaded = view; break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let view = try XCTUnwrap(loaded)
        func js(_ code: String) async throws { _ = try await view.callAsyncJavaScript(code, arguments: [:], in: nil, contentWorld: .defaultClient) }
        func waitFor(_ expression: String) async throws {
            for _ in 0..<150 {
                if (try? await view.callAsyncJavaScript("return " + expression, arguments: [:], in: nil, contentWorld: .defaultClient)) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            let body = try await view.callAsyncJavaScript("return document.body.textContent", arguments: [:], in: nil, contentWorld: .defaultClient)
            throw CommandError("Crowmap did not settle: " + expression + ": " + String(describing: body))
        }
        try await js("[...document.querySelectorAll('button')].find(b=>b.textContent==='Create first project').click()")
        try await waitFor("document.querySelectorAll('.anchor').length === 5")
        XCTAssertEqual(model.crowmap.texts.count, 5)
        XCTAssertTrue(try XCTUnwrap(model.crowmap.texts["Sample project.md"]).contains("[[Sample project-Research]]"))
        XCTAssertTrue(try XCTUnwrap(model.crowmap.texts["Sample project-Prototype.md"]).contains("[[Sample project-Build]]"))
        try await js("document.querySelectorAll('.edge-hit')[1].dispatchEvent(new MouseEvent('click',{clientX:250,clientY:220}))")
        try await waitFor("!!document.querySelector('.map-popup') && !document.querySelector('.map-detail')")
        try await js("[...document.querySelectorAll('button')].find(b=>b.textContent==='Add work note').click()")
        try await waitFor("!!document.querySelector('.map-popup .tiptap') && !document.querySelector('dialog')")
        XCTAssertEqual(model.crowmap.texts.count, 6)
        let arrowGap = try await view.callAsyncJavaScript("await new Promise(r=>setTimeout(r,50));const a=document.querySelector('.frontmatter .property-link:not([hidden])'),f=a.previousElementSibling,s=getComputedStyle(f),c=document.createElement('canvas').getContext('2d');c.font=s.font;return a.getBoundingClientRect().left-f.getBoundingClientRect().left-parseFloat(s.paddingLeft)-c.measureText(f.value).width", arguments: [:], in: nil, contentWorld: .defaultClient) as? Double
        XCTAssertLessThan(try XCTUnwrap(arrowGap), 20, "The link action belongs next to its text")
        let lineStyle = try await view.callAsyncJavaScript("return getComputedStyle(document.querySelector('.weak-line')).strokeDasharray", arguments: [:], in: nil, contentWorld: .defaultClient) as? String
        XCTAssertEqual(lineStyle, "none")
        try await js(#"""
        const title=document.querySelector('[data-property=title] .frontmatter-value');title.value='Implementation';title.dispatchEvent(new Event('change',{bubbles:true}));
        const paragraph=document.querySelector('.tiptap > p:last-child');paragraph.textContent='Work notes https://example.com https://example.com';paragraph.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText'}));
        """#)
        try await waitFor("document.querySelector('.note-save-status')?.textContent === 'Saved'")
        let work = try XCTUnwrap(model.crowmap.texts["New note.md"])
        XCTAssertTrue(work.contains("Implementation")); XCTAssertTrue(work.contains("Work notes"))
        XCTAssertTrue(work.contains("[[Sample project-Research]]")); XCTAssertTrue(work.contains("[[Sample project-Prototype]]"))
        try await js("const title=document.querySelector('.note-file-title');title.value='Implementation';title.dispatchEvent(new Event('blur'))")
        for _ in 0..<100 where model.crowmap.texts["Implementation.md"] == nil { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertNotNil(model.crowmap.texts["Implementation.md"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.crowmap.noteRoot.appendingPathComponent("New note.md").path))

        try await js("document.querySelector('[aria-label=Close]').click()")
        try await waitFor("!document.querySelector('.map-popup')")
        try await js("document.querySelectorAll('.edge-hit')[1].dispatchEvent(new MouseEvent('click',{clientX:250,clientY:220}))")
        try await waitFor("!!document.querySelector('.map-popup')")
        try await js("[...document.querySelectorAll('button')].find(b=>b.textContent==='Add work note').click()")
        try await waitFor("!!document.querySelector('.map-popup .tiptap')")
        try await js(#"""
        const title=document.querySelector('[data-property=title] .frontmatter-value');title.value='Linked note';title.dispatchEvent(new Event('change',{bubbles:true}));
        const paragraph=document.querySelector('.tiptap > p:last-child');paragraph.textContent='[[Implementation]]';paragraph.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText'}));
        """#)
        try await waitFor("document.querySelector('.note-save-status')?.textContent === 'Saved'")
        try await waitFor("document.querySelectorAll('.work-note').length === 2 && document.querySelectorAll('.note-connection').length === 1 && !document.querySelector('.segment-count') && !document.querySelector('.link-leaf')")
        XCTAssertEqual(model.crowmap.texts.count, 7, "Linking A from B must not create another Markdown node")
        try await js("document.querySelector('[aria-label=Close]').click()")
        try await waitFor("!document.querySelector('.map-popup')")
        try await js("document.querySelectorAll('.edge-hit')[1].dispatchEvent(new MouseEvent('click',{clientX:250,clientY:220}))")
        try await waitFor("!!document.querySelector('.map-popup')")
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.crowmap.source.utf8)) as? [String: Any])
        let oldNotes = try XCTUnwrap(before["notes"] as? [[String: Any]])
        let oldProject = try XCTUnwrap((before["projects"] as? [[String: Any]])?.first)
        let rejoin = try XCTUnwrap((oldProject["route"] as? [String])?[3])
        try await js("[...document.querySelectorAll('button')].find(b=>b.textContent==='Add milestone').click()")
        try await waitFor("document.querySelectorAll('.anchor').length === 6 && !!document.querySelector('.map-popup .tiptap') && !document.querySelector('dialog')")
        XCTAssertEqual(model.crowmap.texts.count, 8)
        try await js("document.querySelector('[aria-label=Close]').click()")
        try await waitFor("!document.querySelector('.map-popup')")
        try await js("""
        const source=[...document.querySelectorAll('.anchor')].find(n=>n.getAttribute('aria-label')==='New milestone').querySelector('.connection-handle');
        const target=document.querySelector('[data-node-id="\(rejoin)"] circle');const a=source.getBoundingClientRect(),b=target.getBoundingClientRect();
        source.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,clientX:a.x+a.width/2,clientY:a.y+a.height/2}));
        window.dispatchEvent(new PointerEvent('pointermove',{clientX:b.x+b.width/2,clientY:b.y+b.height/2}));
        window.dispatchEvent(new PointerEvent('pointerup',{clientX:b.x+b.width/2,clientY:b.y+b.height/2}));
        """)
        try await waitFor("document.querySelectorAll('.timeline-edge.active').length === 6 && !document.querySelector('.anchor.ghost')")
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.crowmap.source.utf8)) as? [String: Any])
        XCTAssertEqual((after["anchors"] as? [[String: Any]])?.filter { $0["id"] as? String == rejoin }.count, 1)
        let newNotes = try XCTUnwrap(after["notes"] as? [[String: Any]])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: newNotes.map { ($0["id"] as! String, $0 as NSDictionary) }), Dictionary(uniqueKeysWithValues: oldNotes.map { ($0["id"] as! String, $0 as NSDictionary) }))
        XCTAssertEqual((after["edges"] as? [[String: Any]])?.filter { $0["state"] as? String == "superseded" }.count, 0)
        let restored = CrowmapStore(root: model.crowmap.root); try restored.load(try XCTUnwrap(model.crowmap.selected))
        XCTAssertEqual(restored.source, model.crowmap.source); XCTAssertEqual(restored.texts.count, 8)
        try await js("[...document.querySelectorAll('.work-note')].find(n=>n.textContent==='Implementation').dispatchEvent(new MouseEvent('click',{clientX:420,clientY:320}))")
        try await waitFor("!!document.querySelector('.map-popup .tiptap')")
        let leaves = try await view.callAsyncJavaScript("return [...document.querySelectorAll('.link-leaf')].map(n=>n.dataset.linkId)", arguments: [:], in: nil, contentWorld: .defaultClient) as? [String]
        XCTAssertEqual(Set(leaves ?? []).count, 2)
        let image = try await view.takeSnapshot(configuration: nil)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/crowmap-review.png"))
        try await js("document.querySelector('[aria-label=Close]').click()")
        try await waitFor("!document.querySelector('.map-popup')")
        try await js("document.querySelector('[aria-label=\"Add timeline\"]').click()")
        try await waitFor("document.querySelectorAll('.anchor').length === 11 && !document.querySelector('dialog')")
        let added = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.crowmap.source.utf8)) as? [String: Any])
        XCTAssertEqual((added["projects"] as? [[String: Any]])?.count, 2)
        let starts = (added["anchors"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "start" }
        XCTAssertEqual(starts.last?["priority"] as? Int, 2)
        let ui = try await view.callAsyncJavaScript(#"""
        const viewport=document.querySelector('.map-viewport'),ruler=document.querySelector('.map-date-axis');
        viewport.style.height='160px';const oldTop=ruler.getBoundingClientRect().top;viewport.scrollTop=100;
        await new Promise(r=>setTimeout(r,50));const sticky=viewport.scrollTop>0&&Math.abs(ruler.getBoundingClientRect().top-oldTop)<1;viewport.scrollTop=0;viewport.style.height='';
        const gaps=()=>{const xs=[...document.querySelectorAll('.date-boundary')].map(n=>Number(n.getAttribute('x1')));return xs.slice(1).map((x,i)=>x-xs[i]);};
        const dayGaps=gaps(),equalDays=dayGaps.length>1&&dayGaps.every(g=>Math.abs(g-dayGaps[0])<0.01);
        const unit=document.querySelector('[aria-label="Date scale"]');unit.value='month';unit.dispatchEvent(new Event('change',{bubbles:true}));
        await new Promise(r=>setTimeout(r,50));
        const monthGaps=gaps(),equalMonths=monthGaps.length>=1&&monthGaps.every(g=>Math.abs(g-monthGaps[0])<0.01);
        unit.value='day';unit.dispatchEvent(new Event('change',{bubbles:true}));
        document.querySelector('.map-viewport').scrollLeft=0;
        return {sticky,equalDays,equalMonths,hasScale:unit?.options.length===4,noDates:!document.querySelector('.anchor-date'),curved:document.querySelector('.timeline-edge').tagName==='path'};
        """#, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Bool]
        XCTAssertEqual(ui, ["sticky": true, "equalDays": true, "equalMonths": true, "hasScale": true, "noDates": true, "curved": true])
        try await js(#"""
        const nodes=[...document.querySelectorAll('.work-note')];for(const n of nodes)n.dispatchEvent(new MouseEvent('click',{bubbles:true,metaKey:true}));
        """#)
        try await waitFor("document.querySelectorAll('.work-note.multi-selected').length===2")
        try await js("document.querySelector('.work-note').dispatchEvent(new MouseEvent('click',{bubbles:true,metaKey:true}))")
        try await waitFor("document.querySelectorAll('.work-note.multi-selected').length===1")
        try await js(#"""
        const canvas=document.querySelector('svg[aria-label="Project timeline"]'),rects=[...document.querySelectorAll('.work-note>circle')].map(n=>n.getBoundingClientRect());
        const x=Math.min(...rects.map(r=>r.x))-10,y=Math.min(...rects.map(r=>r.y))-10,right=Math.max(...rects.map(r=>r.right))+10,bottom=Math.max(...rects.map(r=>r.bottom))+10;
        canvas.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,clientX:x,clientY:y}));
        window.dispatchEvent(new PointerEvent('pointermove',{clientX:right,clientY:bottom}));window.dispatchEvent(new PointerEvent('pointerup'));
        """#)
        try await waitFor("document.querySelectorAll('.work-note.multi-selected').length===2 && !document.querySelector('.anchor.multi-selected')")
        try await js("document.querySelector('.work-note').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:400,clientY:300}))")
        try await waitFor("[...document.querySelectorAll('.node-menu button')].some(b=>b.textContent==='Delete 2 notes') && [...document.querySelectorAll('.node-menu button')].some(b=>b.textContent==='Run Codex with 2 notes')")
        try await js("document.querySelector('.node-menu').remove();document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'}))")
        let beforeMove = model.crowmap.source
        let currentNotes = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(beforeMove.utf8)) as? [String: Any])?["notes"] as? [[String: Any]])
        let movingID = try XCTUnwrap(currentNotes.first?["id"] as? String), oldDate = try XCTUnwrap(currentNotes.first?["date"] as? String)
        let dropHighlighted = try await view.callAsyncJavaScript("""
        const circle=document.querySelector('[data-node-id="\(movingID)"]>circle'),r=circle.getBoundingClientRect();
        circle.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,clientX:r.x+r.width/2,clientY:r.y+r.height/2}));
        window.dispatchEvent(new PointerEvent('pointermove',{clientX:r.x+r.width/2+60,clientY:r.y+r.height/2}));
        const highlighted=Number(document.querySelector('.date-drop-column').getAttribute('width'))>0;
        window.dispatchEvent(new PointerEvent('pointerup'));return highlighted;
        """, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(dropHighlighted, true)
        for _ in 0..<100 where model.crowmap.source == beforeMove { try await Task.sleep(for: .milliseconds(30)) }
        let movedDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.crowmap.source.utf8)) as? [String: Any])
        XCTAssertNotEqual((movedDoc["notes"] as? [[String: Any]])?.first(where: { $0["id"] as? String == movingID })?["date"] as? String, oldDate)
        let projects = try XCTUnwrap(movedDoc["projects"] as? [[String: Any]])
        let milestoneID = try XCTUnwrap((projects[1]["route"] as? [String])?[1])
        let beforePriority = model.crowmap.source
        try await js("""
        const circle=document.querySelector('[data-node-id="\(milestoneID)"]>circle'),r=circle.getBoundingClientRect(),canvas=document.querySelector('svg[aria-label="Project timeline"]'),bounds=canvas.getBoundingClientRect(),scale=bounds.width/canvas.viewBox.baseVal.width;
        circle.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,clientX:r.x+r.width/2,clientY:r.y+r.height/2}));
        window.dispatchEvent(new PointerEvent('pointermove',{clientX:r.x+r.width/2,clientY:bounds.top+100*scale}));window.dispatchEvent(new PointerEvent('pointerup'));
        """)
        for _ in 0..<100 where model.crowmap.source == beforePriority { try await Task.sleep(for: .milliseconds(30)) }
        let priorityDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.crowmap.source.utf8)) as? [String: Any])
        XCTAssertEqual((priorityDoc["anchors"] as? [[String: Any]])?.first(where: { $0["id"] as? String == milestoneID })?["priority"] as? Int, 1)
        try await js("document.querySelector('.anchor').dispatchEvent(new MouseEvent('click',{clientX:180,clientY:200}))")
        try await waitFor("!!document.querySelector('[aria-label=\"Open note in editor\"]')")
        try await js("document.querySelector('[aria-label=\"Open note in editor\"]').click()")
        let path = model.crowmap.noteRoot.appendingPathComponent("Sample project.md").path
        for _ in 0..<100 where !model.current.snapshot.buffers.contains(where: { $0.path == path }) { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(model.current.snapshot.buffers.contains { $0.path == path })
        try await js("[...document.querySelectorAll('.work-note')].find(n=>n.textContent==='Implementation').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:400,clientY:300}))")
        try await waitFor("!!document.querySelector('.node-menu')")
        try await js("[...document.querySelectorAll('.node-menu button')].find(b=>b.textContent==='Create linked note').click()")
        try await waitFor("document.querySelectorAll('.work-note').length===3 && !!document.querySelector('.note-file-title')")
        let linkedName = try await view.callAsyncJavaScript("return document.querySelector('.note-file-title').value+'.md'", arguments: [:], in: nil, contentWorld: .defaultClient) as? String
        let linked = try XCTUnwrap(linkedName)
        XCTAssertTrue(try XCTUnwrap(model.crowmap.library[linked]).contains("[[Implementation]]"))
        try await js("[...document.querySelectorAll('.work-note')].find(n=>n.textContent==='New note').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:400,clientY:300}))")
        try await waitFor("!!document.querySelector('.node-menu')")
        try await js("[...document.querySelectorAll('.node-menu button')].find(b=>b.textContent==='Delete note').click()")
        try await waitFor("document.querySelectorAll('.work-note').length===2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.crowmap.noteRoot.appendingPathComponent(linked).path))
        XCTAssertEqual(model.crowmap.library.count, 13)
        try await js("document.querySelectorAll('.work-note').forEach(n=>n.dispatchEvent(new MouseEvent('click',{bubbles:true,metaKey:true})))")
        try await waitFor("document.querySelectorAll('.work-note.multi-selected').length===2")
        try await js("document.querySelector('.work-note').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:400,clientY:300}))")
        try await waitFor("!!document.querySelector('.node-menu')")
        try await js("[...document.querySelectorAll('.node-menu button')].find(b=>b.textContent==='Delete 2 notes').click()")
        try await waitFor("document.querySelectorAll('.work-note').length===0")
        XCTAssertEqual(model.crowmap.library.count, 11)
        let beforeStack = model.crowmap.source
        try await js(#"""
        const a=[...document.querySelectorAll('.anchor')].find(n=>n.getAttribute('aria-label')==='New milestone').querySelector('circle');
        const b=[...document.querySelectorAll('.anchor')].find(n=>n.getAttribute('aria-label')==='Build').querySelector('circle');
        const from=a.getBoundingClientRect(),to=b.getBoundingClientRect();
        a.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,clientX:from.x+from.width/2,clientY:from.y+from.height/2}));
        window.dispatchEvent(new PointerEvent('pointermove',{clientX:to.x+to.width/2,clientY:from.y+from.height/2}));window.dispatchEvent(new PointerEvent('pointerup'));
        """#)
        for _ in 0..<100 where model.crowmap.source == beforeStack { try await Task.sleep(for: .milliseconds(30)) }
        let separated = try await view.callAsyncJavaScript(#"""
        const circle=title=>[...document.querySelectorAll('.anchor')].find(n=>n.getAttribute('aria-label')===title).querySelector('circle');
        const a=circle('New milestone'),b=circle('Build');return Math.abs(Number(a.getAttribute('cx'))-Number(b.getAttribute('cx')))<1 && Math.abs(Number(a.getAttribute('cy'))-Number(b.getAttribute('cy')))>=48;
        """#, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(separated, true, "Same-date main-route milestones must be separate visible nodes")
        let stackedImage = try await view.takeSnapshot(configuration: nil)
        let stackedBitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(stackedImage.tiffRepresentation)))
        try XCTUnwrap(stackedBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/crowmap-stacked-milestones.png"))

        let notesBeforeReorder = model.crowmap.library
        let sourceBeforeReorder = model.crowmap.source
        try await js(#"""
        const get=title=>[...document.querySelectorAll('.anchor')].find(n=>n.getAttribute('aria-label')===title).querySelector('circle');
        const a=get('New milestone'),b=get('Build'),from=a.getBoundingClientRect(),to=b.getBoundingClientRect();
        window.beforeMilestoneSwap=[Number(a.getAttribute('cy')),Number(b.getAttribute('cy'))];
        a.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,clientX:from.x+from.width/2,clientY:from.y+from.height/2}));
        window.dispatchEvent(new PointerEvent('pointermove',{clientX:to.x+to.width/2,clientY:to.y+to.height/2}));window.dispatchEvent(new PointerEvent('pointerup'));
        """#)
        for _ in 0..<100 where model.crowmap.source == sourceBeforeReorder { try await Task.sleep(for: .milliseconds(30)) }
        let swapped = try await view.callAsyncJavaScript(#"""
        const y=title=>Number([...document.querySelectorAll('.anchor')].find(n=>n.getAttribute('aria-label')===title).querySelector('circle').getAttribute('cy'));
        return y('New milestone')===window.beforeMilestoneSwap[1]&&y('Build')===window.beforeMilestoneSwap[0];
        """#, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(swapped, true); XCTAssertEqual(model.crowmap.library, notesBeforeReorder, "Visual ordering must not write Markdown")
        let sourceBeforePriority = model.crowmap.source
        try await js(#"""
        const nodes=[...document.querySelectorAll('.anchor')],builds=nodes.filter(n=>n.getAttribute('aria-label')==='Build');
        const candidates=[builds[0],nodes.find(n=>n.getAttribute('aria-label')==='New milestone')].sort((a,b)=>Number(a.querySelector('circle').getAttribute('cy'))-Number(b.querySelector('circle').getAttribute('cy')));
        const a=candidates[0].querySelector('circle'),b=builds[1].querySelector('circle'),from=a.getBoundingClientRect(),to=b.getBoundingClientRect();
        a.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,metaKey:true,clientX:from.x+from.width/2,clientY:from.y+from.height/2}));
        window.dispatchEvent(new PointerEvent('pointermove',{metaKey:true,clientX:from.x+from.width/2,clientY:to.y+to.height/2}));window.dispatchEvent(new PointerEvent('pointerup',{metaKey:true}));
        """#)
        for _ in 0..<100 where model.crowmap.source == sourceBeforePriority { try await Task.sleep(for: .milliseconds(30)) }
        let reordered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.crowmap.source.utf8)) as? [String: Any])
        let reorderedAnchors = try XCTUnwrap(reordered["anchors"] as? [[String: Any]])
        let firstProjectID = try XCTUnwrap((reordered["projects"] as? [[String: Any]])?.first?["id"] as? String)
        let changedMilestones = reorderedAnchors.filter { $0["project"] as? String == firstProjectID && ["Build", "New milestone", "Release"].contains($0["title"] as? String ?? "") }
        XCTAssertEqual(changedMilestones.count, 3); XCTAssertTrue(changedMilestones.allSatisfy { $0["priority"] as? Int == 2 }, "Cmd drag must change this date and following milestone priorities")

        let connected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.crowmap.source.utf8)) as? [String: Any])
        let branch = try XCTUnwrap((connected["anchors"] as? [[String: Any]])?.first { $0["title"] as? String == "New milestone" })
        let branchID = try XCTUnwrap(branch["id"] as? String)
        let incident = try XCTUnwrap(connected["edges"] as? [[String: Any]]).filter { $0["from"] as? String == branchID || $0["to"] as? String == branchID }
        XCTAssertEqual(incident.count, 2)
        for edge in incident {
            let edgeID = try XCTUnwrap(edge["id"] as? String)
            try await js("document.querySelector('[data-edge-id=\"\(edgeID)\"]').dispatchEvent(new MouseEvent('click',{clientX:300,clientY:260}))")
            try await waitFor("!![...document.querySelectorAll('.map-popup button')].find(b=>b.textContent==='Disconnect milestones')")
            try await js("[...document.querySelectorAll('.map-popup button')].find(b=>b.textContent==='Disconnect milestones').click()")
            try await waitFor("!document.querySelector('[data-edge-id=\"\(edgeID)\"]') && !document.querySelector('.map-popup')")
        }
        try await waitFor("document.querySelector('[data-node-id=\"\(branchID)\"]').classList.contains('ghost')")
        XCTAssertEqual(model.crowmap.library.count, 11, "Disconnecting keeps the original Markdown file")
        let branchText = try TextFiles.read(model.crowmap.noteURL(try XCTUnwrap(branch["note"] as? String)))
        XCTAssertTrue(branchText.contains("previous: []")); XCTAssertTrue(branchText.contains("next: []"))
        try await js("document.querySelector('button[aria-label=\"Map controls\"]').click();document.querySelector('[aria-label=\"Refresh map\"]').click()")
        try await waitFor("document.querySelector('[data-node-id=\"\(branchID)\"]').classList.contains('ghost') && document.querySelectorAll('.anchor').length===11")
        let finalImage = try await view.takeSnapshot(configuration: nil)
        let finalBitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(finalImage.tiffRepresentation)))
        try XCTUnwrap(finalBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/crowmap-disconnected-milestone.png"))
        try await js("document.querySelector('button[aria-label=\"Map controls\"]').click()")
        try await js("document.querySelector('.anchor').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:200,clientY:180}))")
        try await waitFor("!![...document.querySelectorAll('.node-menu button')].find(b=>b.textContent==='Copy')")
        try await js("[...document.querySelectorAll('.node-menu button')].find(b=>b.textContent==='Duplicate').click()")
        try await waitFor("document.querySelectorAll('.anchor').length===17 && !!document.querySelector('.map-popup .tiptap')")
        XCTAssertEqual(model.crowmap.library.count, 17)
        let duplicated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.crowmap.source.utf8)) as? [String: Any])
        XCTAssertEqual((duplicated["projects"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((duplicated["notes"] as? [[String: Any]])?.count, 0)
        try await js("document.querySelector('[aria-label=Close]').click()")
        try await waitFor("!document.querySelector('.map-popup')")
        try await js("[...document.querySelectorAll('.anchor')].find(n=>n.getAttribute('aria-label')==='Research').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:300,clientY:220}))")
        try await waitFor("!!document.querySelector('.node-menu')")
        try await js("[...document.querySelectorAll('.node-menu button')].find(b=>b.textContent==='Duplicate').click()")
        try await waitFor("document.querySelectorAll('.anchor').length===18 && !!document.querySelector('.map-popup .tiptap')")
        XCTAssertEqual(model.crowmap.library.count, 18)
        try await js("document.querySelector('[aria-label=Close]').click()")
        try await waitFor("!document.querySelector('.map-popup')")
        try await js("document.querySelector('.edge-hit').dispatchEvent(new MouseEvent('click',{clientX:250,clientY:220}))")
        try await waitFor("!!document.querySelector('.map-popup')")
        try await js("[...document.querySelectorAll('button')].find(b=>b.textContent==='Add work note').click()")
        try await waitFor("document.querySelectorAll('.work-note').length===1 && !!document.querySelector('.map-popup .tiptap')")
        try await js("document.querySelector('[aria-label=Close]').click()")
        try await waitFor("!document.querySelector('.map-popup')")
        let beforeDelete = model.crowmap.source
        let filesBeforeDelete = model.crowmap.library
        try await js("document.querySelector('.anchor').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:200,clientY:180}))")
        try await waitFor("!!document.querySelector('.node-menu')")
        try await js("[...document.querySelectorAll('.node-menu button')].find(b=>b.textContent==='Delete timeline').click()")
        try await waitFor("!!document.querySelector('dialog[open] [data-confirm]') && document.activeElement?.dataset.confirm==='true'")
        XCTAssertEqual(model.crowmap.source, beforeDelete)
        try await js("[...document.querySelectorAll('dialog button')].find(b=>b.textContent==='Cancel').click()")
        try await waitFor("!document.querySelector('dialog')")
        XCTAssertEqual(model.crowmap.source, beforeDelete); XCTAssertEqual(model.crowmap.library, filesBeforeDelete)
        try await js("document.querySelector('.anchor').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:200,clientY:180}))")
        try await waitFor("!!document.querySelector('.node-menu')")
        try await js("[...document.querySelectorAll('.node-menu button')].find(b=>b.textContent==='Delete timeline').click()")
        try await waitFor("!!document.querySelector('dialog[open] [data-confirm]')")
        try await js("document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',repeat:true,bubbles:true,cancelable:true}))")
        try await waitFor("!document.querySelector('dialog') && document.querySelectorAll('.anchor').length===11 && !document.querySelector('.work-note')")
        XCTAssertEqual(model.crowmap.library.count, 11)
        let afterDelete = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.crowmap.source.utf8)) as? [String: Any])
        XCTAssertEqual((afterDelete["projects"] as? [[String: Any]])?.count, 2)
        try await js("document.head.append(Object.assign(document.createElement('style'),{textContent:'.map-viewport{max-height:250px}'}));document.querySelector('.map-viewport').scrollTop=0;document.querySelector('[aria-label=\"Add timeline\"]').click()")
        try await waitFor("document.querySelectorAll('.anchor').length===16 && document.activeElement?.classList.contains('anchor')")
        try await waitFor("document.querySelector('.map-viewport').scrollTop>0 && (()=>{const n=document.activeElement.getBoundingClientRect(),v=document.querySelector('.map-viewport').getBoundingClientRect();return n.top>=v.top&&n.bottom<=v.bottom;})()")
        let focusedID = try await view.callAsyncJavaScript("return document.activeElement.dataset.nodeId", arguments: [:], in: nil, contentWorld: .defaultClient) as? String
        let focusedMap = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.crowmap.source.utf8)) as? [String: Any])
        XCTAssertEqual(focusedID, ((focusedMap["projects"] as? [[String: Any]])?.last?["route"] as? [String])?.first)
    }

    func testCrowmapPanelPersistenceAndLegacyMigrationPreserveDirtySource() throws {
        model.crowmap = CrowmapStore(root: root.appendingPathComponent("Crowmap"))
        try model.crowmap.create("First"); let first = try XCTUnwrap(model.crowmap.selected)
        let clean = OpenBuffer(title: first.lastPathComponent, path: first.path, text: model.crowmap.source, language: .markdown, isRemote: false)
        try model.crowmap.create("Second"); let second = try XCTUnwrap(model.crowmap.selected)
        var dirty = OpenBuffer(title: second.lastPathComponent, path: second.path, text: model.crowmap.source, language: .markdown, isRemote: false)
        dirty.text += " "; dirty.isDirty = true
        model.current.snapshot.buffers += [clean, dirty]
        model.current.snapshot.layout?.open(.file(clean.id)); model.current.snapshot.layout?.open(.file(dirty.id))
        model.restoreCrowmapPanel()
        XCTAssertEqual(model.crowmapTabs.map(\.id), [first.path])
        XCTAssertFalse(model.current.snapshot.buffers.contains { $0.id == clean.id })
        XCTAssertTrue(model.current.snapshot.buffers.contains { $0.id == dirty.id && $0.isDirty })
        XCTAssertTrue(model.current.snapshot.layout?.allTabs.contains(.file(dirty.id)) == true)
        model.openCrowmap(second)
        let tab = try XCTUnwrap(model.crowmapTabs.last)
        tab.store.drafts["Note.md"] = "Unsaved draft"; tab.store.draftBases["Note.md"] = "Original"
        model.crowmapPanel.height = 420; model.crowmapPanel.maximized = true
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(model.sessionSnapshot))
        XCTAssertEqual(snapshot.crowmapPanel?.paths, [first.path, second.path])
        XCTAssertEqual(snapshot.crowmapPanel?.drafts[second.path]?["Note.md"], "Unsaved draft")
        model.crowmapTabs = []; model.crowmapPanel = try XCTUnwrap(snapshot.crowmapPanel)
        model.restoreCrowmapPanel()
        XCTAssertEqual(model.crowmapTabs.count, 2)
        XCTAssertEqual(model.crowmapPanel.selectedPath, second.path)
        XCTAssertEqual(model.crowmapPanel.height, 420)
        XCTAssertEqual(model.crowmapTabs.last?.store.draftBases["Note.md"], "Original")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        old.removeValue(forKey: "crowmapPanel")
        XCTAssertNil(try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: old)).crowmapPanel)
    }

    func testCrowmapImportFolderCreatesCacheAndLinksOutsideNotes() async throws {
        model.crowmap = CrowmapStore(root: root.appendingPathComponent("Maps"))
        let outside = root.appendingPathComponent("Outside/ProjectNotes")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let note = "---\nkind: start\ntitle: Project\ndate: 2026-09-18\npriority: 1\nmilestones: []\n---\nBody\n"
        try Data(note.utf8).write(to: outside.appendingPathComponent("Project.md"))
        let imported = try model.crowmap.importFolder(outside)
        XCTAssertEqual(imported.lastPathComponent, "ProjectNotes.crowmap")
        XCTAssertTrue(model.crowmap.maps.contains { $0.resolvingSymlinksInPath() == imported.resolvingSymlinksInPath() })
        XCTAssertEqual(try TextFiles.read(outside.appendingPathComponent("Project.md")), note)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("ProjectNotes.crowmap").path))
        XCTAssertEqual(imported.deletingLastPathComponent().resolvingSymlinksInPath(), outside.resolvingSymlinksInPath())
        XCTAssertEqual(try imported.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertTrue(model.crowmapIsLinkedFolder(imported))
        XCTAssertFalse(model.crowmapOwnsFolder(imported))
        model.importCrowmap(from: outside)
        XCTAssertEqual(model.crowmapTabs.map { $0.url.resolvingSymlinksInPath() }, [imported.resolvingSymlinksInPath()])
        XCTAssertEqual(try model.crowmap.importFolder(outside).resolvingSymlinksInPath(), imported.resolvingSymlinksInPath(), "Re-importing the same folder reopens the existing map")
        XCTAssertEqual(model.crowmap.maps.count, 1)
        let original = try await model.deleteCrowmap(imported)
        XCTAssertEqual(original.resolvingSymlinksInPath(), outside.resolvingSymlinksInPath())
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.deletingLastPathComponent().path))
        XCTAssertEqual(try TextFiles.read(outside.appendingPathComponent("Project.md")), note)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("ProjectNotes.crowmap").path))
        XCTAssertTrue(model.crowmap.maps.isEmpty)
        let inside = model.crowmap.root.appendingPathComponent("LocalNotes")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try Data(note.utf8).write(to: inside.appendingPathComponent("Project.md"))
        let local = try model.crowmap.importFolder(inside)
        XCTAssertEqual(local.deletingLastPathComponent().resolvingSymlinksInPath(), inside.resolvingSymlinksInPath())
        XCTAssertNotEqual(try local.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
        do { _ = try model.crowmap.importFolder(model.crowmap.root); XCTFail("The library itself is not a map") } catch {}
    }

    func testCrowmapRenameDuplicateAndDeleteKeepMapsIndependent() async throws {
        model.crowmap = CrowmapStore(root: root.appendingPathComponent("Maps")); model.createCrowmap()
        let original = try XCTUnwrap(model.crowmapTabs.first), folder = original.store.noteRoot
        let note = folder.appendingPathComponent("Note.md"), noteText = "---\ndate: 2026-09-18\n---\nBody [[Another note]]\n"
        try Data(noteText.utf8).write(to: note)
        let sessions = folder.appendingPathComponent(".sessions/session/notes")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("Note.md"), withDestinationURL: note)
        let instructions = sessions.deletingLastPathComponent().appendingPathComponent("AGENTS.md")
        try Data(("# Session\nMap file: " + original.url.lastPathComponent + "\nKeep this guidance\n").utf8).write(to: instructions)
        let agentID = try XCTUnwrap(model.newAgentTerminal(.codex, directory: folder.path, crowmapPath: original.id))
        let renamed = try await model.renameCrowmap(original.url, to: "Renamed")
        XCTAssertEqual(renamed.deletingLastPathComponent(), folder, "Agent cwd and conversation history remain stable")
        XCTAssertEqual(model.current.snapshot.agentTerminals.first { $0.id == agentID }?.crowmapPath, renamed.path)
        XCTAssertEqual(model.crowmapPanel.selectedPath, renamed.path)
        XCTAssertEqual(try TextFiles.read(instructions), "# Session\nMap file: Renamed.crowmap\nKeep this guidance\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.id))
        XCTAssertEqual(try TextFiles.read(sessions.appendingPathComponent("Note.md")), noteText)
        let duplicate = try await model.duplicateCrowmap(renamed)
        let secondDuplicate = try await model.duplicateCrowmap(renamed)
        XCTAssertEqual(duplicate.lastPathComponent, "Renamed 2.crowmap")
        XCTAssertEqual(secondDuplicate.lastPathComponent, "Renamed 3.crowmap")
        let copy = CrowmapStore(root: model.crowmap.root); try copy.load(duplicate)
        XCTAssertEqual(copy.library["Note.md"], noteText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.noteRoot.appendingPathComponent(".sessions").path))
        let sourceDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try TextFiles.read(renamed).utf8)) as? [String: Any])
        let copyDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(copy.source.utf8)) as? [String: Any])
        XCTAssertNotEqual(sourceDoc["id"] as? String, copyDoc["id"] as? String)
        try Data("Independent edit".utf8).write(to: copy.noteRoot.appendingPathComponent("Note.md"))
        XCTAssertEqual(try TextFiles.read(note), noteText)
        model.openCrowmap(duplicate)
        let archive = try await model.deleteCrowmap(duplicate)
        XCTAssertEqual(try TextFiles.read(archive.appendingPathComponent("Note.md")), "Independent edit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.path))
        XCTAssertFalse(model.crowmapTabs.contains { $0.url == duplicate })
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondDuplicate.path))
    }

    func testCrowmapFileActionsProtectDraftsCollisionsAndRunningAgents() async throws {
        model.crowmap = CrowmapStore(root: root.appendingPathComponent("Maps")); model.createCrowmap()
        let tab = try XCTUnwrap(model.crowmapTabs.first), folder = tab.store.noteRoot
        let collision = folder.appendingPathComponent("Taken.crowmap")
        try Data(tab.store.source.utf8).write(to: collision)
        do { _ = try await model.renameCrowmap(tab.url, to: "Taken"); XCTFail("Must preserve an existing map") } catch {}
        XCTAssertEqual(try TextFiles.read(collision), tab.store.source)
        tab.store.drafts["Note.md"] = "Unsaved"
        do { _ = try await model.duplicateCrowmap(tab.url); XCTFail("Must not drop a draft") } catch {}
        do { _ = try await model.deleteCrowmap(tab.url); XCTFail("Must not delete a draft") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: tab.id))
        tab.store.drafts.removeAll()
        let id = try XCTUnwrap(model.newAgentTerminal(.codex, directory: folder.path, crowmapPath: tab.id))
        let session = model.terminal(id, in: model.current); session.running = true
        do { _ = try await model.deleteCrowmap(tab.url); XCTFail("Must keep a running agent's working directory") } catch {}
        session.running = false
        let note = folder.appendingPathComponent("Shared.md"); try Data("Keep me".utf8).write(to: note)
        XCTAssertFalse(model.crowmapOwnsFolder(tab.url))
        let archive = try await model.deleteCrowmap(tab.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(try TextFiles.read(note), "Keep me", "A shared map folder must never be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: collision.path))
    }

    func testPinnedCrowmapTabsRetainOrderAndPinAfterRenameAndRestore() async throws {
        model.crowmap = CrowmapStore(root: root.appendingPathComponent("Maps")); model.createCrowmap(); model.createCrowmap()
        let first = model.crowmapTabs[0], pinned = model.crowmapTabs[1]
        model.toggleCrowmapPin(pinned.id)
        XCTAssertEqual(model.crowmapTabs.map(\.id), [pinned.id, first.id])
        XCTAssertTrue(model.crowmapTabs.first === pinned, "Pinning retains the existing WebView store identity")
        let renamed = try await model.renameCrowmap(pinned.url, to: "Pinned")
        XCTAssertTrue(model.isCrowmapPinned(renamed.path))
        XCTAssertFalse(model.isCrowmapPinned(pinned.id))
        let saved = try JSONDecoder().decode(CrowmapPanelSnapshot.self, from: JSONEncoder().encode(model.savedCrowmapPanel))
        model.crowmapTabs = []; model.crowmapPanel = saved; model.restoreCrowmapPanel()
        XCTAssertEqual(model.crowmapTabs.map(\.id), [renamed.path, first.id])
        XCTAssertTrue(model.isCrowmapPinned(renamed.path))
        _ = try await model.deleteCrowmap(renamed)
        XCTAssertNil(model.crowmapPanel.pinnedPaths)
        XCTAssertEqual(model.crowmapTabs.map(\.id), [first.id])
    }

    func testCloseOtherTabsPreservesPinnedTabs() throws {
        let pinned = try XCTUnwrap(model.selectedBuffer), pane = try XCTUnwrap(model.current.snapshot.layout?.activePaneID)
        model.toggleTabPin(.file(pinned.id)); model.newTerminal()
        let kept = WorkspaceTab.terminal(try XCTUnwrap(model.current.snapshot.selectedTerminalID))
        model.newTab()
        model.closeOtherTabs(except: kept, in: pane)
        XCTAssertEqual(model.current.snapshot.layout?.activePane?.tabs, [.file(pinned.id), kept])
        XCTAssertTrue(model.current.snapshot.layout?.isPinned(.file(pinned.id)) == true)
        XCTAssertEqual(model.current.snapshot.layout?.activePane?.selected, kept)
    }

    func testCrowmapTabCloseRetainsUnflushedDrafts() async throws {
        model.crowmap = CrowmapStore(root: root.appendingPathComponent("Crowmap")); model.createCrowmap()
        let tab = try XCTUnwrap(model.crowmapTabs.first)
        tab.store.drafts["Note.md"] = "Unsaved"
        tab.store.flushDrafts = { true } // Another restored draft may not be open in the embedded editor.
        model.closeCrowmapTab(tab.id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.crowmapTabs.count, 1)
        XCTAssertEqual(model.savedCrowmapPanel.drafts[tab.id]?["Note.md"], "Unsaved")
        tab.store.flushDrafts = { tab.store.drafts.removeAll(); return true }
        model.closeCrowmapTab(tab.id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.crowmapTabs.isEmpty)
        XCTAssertNil(model.crowmapPanel.selectedPath)
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
        XCTAssertTrue(files.contains { $0["path"] as? String == "Notes/Note.md" && ($0["text"] as? String)?.contains("status: reading") == true }, String(describing: files))
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
        assert(window.messages.some(m=>m.action==='selectView' && m.index==='1'),'Selected view must reach native state');
        window.crowObsidian.receive({source,kind:'base',path:'Other.base',files});
        receive({files});
        assert(document.querySelector('.view-select').value==='1','Switching documents lost the selected view');
        assert(!window.crowObsidian.validateBase({source:'views: [broken',path:'Notes.base'}),'Invalid definitions must report an error');
        receive({files});
        assert(document.querySelector('.view-select')?.isConnected && document.querySelectorAll('tbody tr').length===100,'Fixing a definition must remount its controls');
        source='custom: preserved\nviews:\n - type: table\n   name: Inline\n   order: [file.name, status, cover, tags]\n';
        const inlineFiles=[{path:'Inline.md',text:'---\nstatus: reading\ncover: "![[Attachments/image.png|200]]"\ntags: [one, two]\n---\nBody'}];
        receive({files:inlineFiles,warning:'288 iCloud notes are not downloaded. Their properties and tags will be available after downloading and refreshing the index.'});
        assert(!document.querySelector('.base-cloud-hint').hidden && document.querySelector('.base-cloud-hint').parentElement.contains(document.querySelector('.base-count')),'Cloud warning belongs beside results');
        assert(document.querySelector('.warning').hidden,'Cloud hint must not occupy a banner');
        const cell=document.querySelector('[data-column=status] .cell-input');
        assert(cell && !document.querySelector('.property-editor,.cell-edit-trigger'),'Cells must be directly editable');
        document.querySelector('[data-column=cover] .property-link').click();
        assert(window.messages.at(-1).action==='openWiki' && window.messages.at(-1).path==='Attachments/image.png','Embed property must open its target, excluding size alias');
        cell.focus();cell.value='한글 변경';cell.dispatchEvent(new Event('input'));
        receive({files:[],incremental:true});
        assert(document.activeElement===cell && cell.value==='한글 변경','Background updates must retain a cell draft');
        cell.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,isComposing:true}));
        assert(document.activeElement===cell,'IME Enter must not commit');
        cell.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
        await new Promise(resolve=>setTimeout(resolve,0));
        const write=window.messages.filter(m=>m.action==='property').at(-1);
        assert(write.source.includes('status: 한글 변경') && write.source.endsWith('Body'),'Inline Enter must preserve the rest of the note');
        window.crowObsidian.propertyResult(write.id,{ok:true});await new Promise(resolve=>setTimeout(resolve,0));
        const edited=document.querySelector('[data-column=status] .cell-input');edited.focus();edited.value='discard';edited.dispatchEvent(new Event('input'));edited.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
        assert(edited.value==='한글 변경','Escape must discard only the draft');
        const resize=document.querySelector('[aria-label="Resize status"]');resize.setPointerCapture=()=>{};resize.hasPointerCapture=()=>false;
        resize.dispatchEvent(new PointerEvent('pointerdown',{button:0,pointerId:1,clientX:200,bubbles:true}));
        resize.dispatchEvent(new PointerEvent('pointermove',{pointerId:1,clientX:287,bubbles:true}));
        assert(document.querySelector('col[data-column=status]').style.width==='267px','Dragging must resize immediately');
        resize.dispatchEvent(new PointerEvent('pointerup',{pointerId:1,clientX:287,bubbles:true}));
        source=window.messages.filter(m=>m.action==='change').at(-1).source;
        assert(source.includes('status: 267') && source.includes('custom: preserved'),'Column size must persist without dropping other settings');
        receive({files:inlineFiles});
        assert(document.querySelector('col[data-column=status]').style.width==='267px','Column size must survive remount');
        const status=document.querySelector('[data-column=status] .cell-input'),cover=document.querySelector('[data-column=cover] .cell-input');
        status.focus();status.value='queued';status.dispatchEvent(new Event('input'));cover.focus();
        cover.value='![[Attachments/next.png]]';cover.dispatchEvent(new Event('input'));cover.blur();
        await new Promise(resolve=>setTimeout(resolve,0));
        const first=window.messages.filter(m=>m.action==='property').at(-1);
        assert(first.source.includes('status: queued'),'First cell write must go first');
        window.crowObsidian.propertyResult(first.id,{ok:true});await new Promise(resolve=>setTimeout(resolve,0));
        const second=window.messages.filter(m=>m.action==='property').at(-1);
        assert(second.id!==first.id && second.source.includes('status: queued') && second.source.includes('Attachments/next.png'),'Queued edit must use the newly saved note');
        assert(cover.isConnected,'Pending cell edits must not be replaced by another save');
        window.crowObsidian.propertyResult(second.id,{ok:true});await new Promise(resolve=>setTimeout(resolve,0));
        const failing=document.querySelector('[data-column=status] .cell-input');failing.focus();failing.value='keep my draft';failing.dispatchEvent(new Event('input'));failing.blur();
        await new Promise(resolve=>setTimeout(resolve,0));
        window.crowObsidian.propertyResult(window.messages.filter(m=>m.action==='property').at(-1).id,{ok:false,error:'Save conflict'});await new Promise(resolve=>setTimeout(resolve,0));
        receive({files:[],incremental:true});
        assert(failing.isConnected && failing.value==='keep my draft','A failed save must retain the draft across refreshes');
        failing.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
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
        XCTAssertTrue((changed.first { $0["path"] as? String == "Cached.md" }?["text"] as? String)?.contains("status: done") == true, String(describing: changed))
        try FileManager.default.removeItem(at: note)
        let (deleted, _) = try await ObsidianFiles.inventory(in: model.current)
        XCTAssertFalse(deleted.contains { $0["path"] as? String == "Cached.md" })
    }

    func testProfileLocalVaultReadOnlyWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["CROW_PROFILE_VAULT"] else { throw XCTSkip("Set CROW_PROFILE_VAULT to profile a real vault without editing it.") }
        let state = WorkspaceState(.init(workspace: Workspace(name: "Profile", kind: .local, connection: .local), rootPath: path))
        let start = Date(), (files, warning) = try await ObsidianFiles.inventory(in: state)
        print("REAL_VAULT_READ_SECONDS", Date().timeIntervalSince(start), "FILES", files.count, "LOADED_NOTES", files.filter { $0["text"] is String }.count, "WARNING", warning ?? "none")
        let config = WKWebViewConfiguration()
        let scriptURL = try XCTUnwrap(Bundle.main.url(forResource: "obsidian-preview", withExtension: "js"))
        let script = "window.webkit={messageHandlers:{obsidian:{postMessage:()=>{}}}};\n" + (try String(contentsOf: scriptURL, encoding: .utf8))
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 600), configuration: config)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.setFrameOrigin(.init(x: -20000, y: -20000)); window.contentView = view; window.orderBack(nil); defer { window.close() }
        let styleURL = try XCTUnwrap(Bundle.main.url(forResource: "obsidian-preview", withExtension: "css"))
        view.loadHTMLString("<html><head><style>\(try String(contentsOf: styleURL, encoding: .utf8))</style></head><body><main></main></body></html>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await view.callAsyncJavaScript("return !!window.crowObsidian", arguments: [:], in: nil, contentWorld: .defaultClient)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        for item in files {
            guard let relative = item["path"] as? String, relative.hasSuffix(".base"), !relative.contains("/") else { continue }
            let source = try String(contentsOfFile: (path as NSString).appendingPathComponent(relative), encoding: .utf8)
            let start = Date()
            let result = try await view.callAsyncJavaScript("""
            window.crowObsidian.receive(payload);
            void document.body.offsetHeight;
            return {rows:document.querySelectorAll('tbody tr,.base-item').length, error:document.querySelector('.error')?.textContent??''};
            """, arguments: ["payload": ["path": relative, "kind": "base", "source": source, "files": files]], in: nil, contentWorld: .defaultClient)
            _ = try await view.takeSnapshot(configuration: nil)
            print("REAL_BASE_BRIDGE_AND_PAINT_SECONDS", Date().timeIntervalSince(start), String(describing: result))
        }
    }

    func testImagePropertyTargetResolvesByNameAndThumbnailCacheInvalidates() async throws {
        let directory = root.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("한글 image.png")
        try InputToolsTests.png.write(to: image)
        let sourceID = try XCTUnwrap(model.selectedBufferID)
        model.openMarkdownLink("한글 image.png", from: sourceID, allowWorkspaceLink: true)
        for _ in 0..<100 where model.selectedBuffer?.path != image.path { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.selectedBuffer?.path, image.path)
        XCTAssertEqual(model.selectedBuffer?.isImage, true)
        let first = try await ObsidianFiles.asset("Attachments/한글 image.png", in: model.current)
        let cached = try await ObsidianFiles.asset("Attachments/한글 image.png", in: model.current)
        XCTAssertNotNil(first["image"]); XCTAssertEqual(first, cached)
        try Data("invalid image".utf8).write(to: image)
        do { _ = try await ObsidianFiles.asset("Attachments/한글 image.png", in: model.current); XCTFail("Modified image must not return a stale cached thumbnail") }
        catch {}
    }

    func testProfileCanvasReadOnlyWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["CROW_PROFILE_CANVAS"],
              let vault = ProcessInfo.processInfo.environment["CROW_PROFILE_CANVAS_ROOT"] else { throw XCTSkip("Opt-in real Canvas profile") }
        let source = try Data(contentsOf: URL(fileURLWithPath: path))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        let nodes = try XCTUnwrap(document["nodes"] as? [[String: Any]])
        let imageCount = nodes.filter { $0["file"] is String }.count
        let state = WorkspaceState(.init(workspace: Workspace(name: "Canvas profile", kind: .local, connection: .local), rootPath: vault))
        model.states.append(state); model.activateWorkspace(state.id, reconnect: false)
        let started = Date()
        model.openFile(.init(name: (path as NSString).lastPathComponent, path: path, isDirectory: false))
        for _ in 0..<100 where model.selectedBuffer?.path != path { try await Task.sleep(for: .milliseconds(20)) }
        let buffer = try XCTUnwrap(model.selectedBuffer)
        XCTAssertEqual(buffer.path, path)
        let hosting = NSHostingView(rootView: ObsidianDocumentView(buffer: buffer).environment(model))
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderBack(nil); defer { window.close() }
        func web(_ view: NSView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap { web($0) }.first }
        var firstPaint: TimeInterval?, localReady: TimeInterval?, imageLoaded = 0, errors = 0
        for _ in 0..<600 {
            if let view = web(hosting), let counts = try? await view.callAsyncJavaScript("return [document.querySelectorAll('.node').length,[...document.querySelectorAll('.node img')].filter(i=>i.complete&&i.naturalWidth>0).length,[...document.querySelectorAll('.node.file .node-content')].filter(n=>n.textContent.includes('iCloud')).length]", arguments: [:], in: nil, contentWorld: .defaultClient) as? [Int], counts.count == 3 {
                if firstPaint == nil, counts[0] == nodes.count { firstPaint = Date().timeIntervalSince(started) }
                imageLoaded = counts[1]; errors = counts[2]
                if localReady == nil, imageLoaded + errors == imageCount { localReady = Date().timeIntervalSince(started) }
                if imageLoaded == imageCount { break }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        print("REAL_CANVAS_SECONDS", "first paint", firstPaint ?? -1, "local ready", localReady ?? -1, "waited", Date().timeIntervalSince(started), "loaded", imageLoaded, "cloud unavailable", errors, "expected", imageCount)
        XCTAssertNotNil(firstPaint); XCTAssertEqual(imageLoaded + errors, imageCount)
        if let view = web(hosting) {
            let image = try await view.takeSnapshot(configuration: nil)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/crow-real-canvas.png"))
        }
        let reopenStart = Date()
        let reopened = NSHostingView(rootView: ObsidianDocumentView(buffer: buffer).environment(model))
        window.contentView = reopened
        var reopenedImages = 0
        for _ in 0..<200 {
            if let view = web(reopened), let count = try? await view.callAsyncJavaScript("return [...document.querySelectorAll('.node img')].filter(i=>i.complete&&i.naturalWidth>0).length", arguments: [:], in: nil, contentWorld: .defaultClient) as? Int { reopenedImages = count }
            if reopenedImages == imageCount { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        print("REAL_CANVAS_REOPEN_SECONDS", Date().timeIntervalSince(reopenStart), "images", reopenedImages)
        XCTAssertEqual(reopenedImages, imageCount)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), source, "Profiling must not alter the Canvas")
    }

    func testNoteVaultIndexesWorkspaceAndDisablesWithoutChangingDocuments() async throws {
        let note = root.appendingPathComponent("VaultNote.md")
        let original = "---\ntags: [work, reading]\n---\nBody\n"
        try Data(original.utf8).write(to: note)
        let state = model.current
        model.setNoteVault(state.id, enabled: true)
        await state.noteIndexTask?.value
        XCTAssertTrue(state.snapshot.isNoteVault)
        XCTAssertTrue(state.noteCatalog.paths.contains("VaultNote.md"))
        XCTAssertTrue(state.noteCatalog.tags.contains("reading"))
        let (files, _) = try await ObsidianFiles.inventory(in: state, preferCached: true)
        XCTAssertTrue(files.contains { $0["path"] as? String == "VaultNote.md" })
        model.setNoteVault(state.id, enabled: false)
        XCTAssertFalse(state.snapshot.isNoteVault)
        XCTAssertTrue(state.noteCatalog.paths.isEmpty)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".obsidian").path))
    }

    func testLargeLocalBaseInventoryStaysResponsive() async throws {
        let folder = root.appendingPathComponent("Large")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<1500 {
            try Data("---\nstatus: reading\nnumber: \(index)\n---\nBody\n".utf8).write(to: folder.appendingPathComponent("Note-\(index).md"))
        }
        let start = Date()
        var publications = 0
        let (files, _) = try await ObsidianFiles.inventory(in: model.current) { _, _ in publications += 1 }
        print("BASE_LOCAL_1500_SECONDS", Date().timeIntervalSince(start))
        XCTAssertEqual(files.filter { ($0["path"] as? String)?.hasPrefix("Large/") == true }.count, 1500)
        XCTAssertGreaterThan(publications, 1)
        XCTAssertTrue(files.filter { ($0["path"] as? String)?.hasPrefix("Large/") == true }.allSatisfy { $0["text"] != nil })
    }

    func testBaseViewSurvivesWebViewRecreation() async throws {
        let file = root.appendingPathComponent("Views.base")
        let source = "views:\n - {type: table, name: Table, order: [file.name]}\n - {type: cards, name: Cards, order: [file.name]}\n"
        try Data(source.utf8).write(to: file)
        model.openFile(.init(name: "Views.base", path: file.path, isDirectory: false))
        let buffer = try XCTUnwrap(model.selectedBuffer)
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.orderBack(nil); defer { window.close() }
        func web(_ view: NSView) -> WKWebView? { if let value = view as? WKWebView { return value }; return view.subviews.lazy.compactMap { web($0) }.first }
        for pass in 0..<2 {
            let hosting = NSHostingView(rootView: ObsidianDocumentView(buffer: buffer).environment(model))
            window.contentView = hosting
            var preview: WKWebView?
            for _ in 0..<100 {
                if let view = web(hosting), (try? await view.callAsyncJavaScript("return !!document.querySelector('.view-select')", arguments: [:], in: nil, contentWorld: .defaultClient)) as? Bool == true { preview = view; break }
                try await Task.sleep(for: .milliseconds(40))
            }
            let view = try XCTUnwrap(preview)
            if pass == 0 {
                _ = try await view.callAsyncJavaScript("const picker=document.querySelector('.view-select'); picker.value='1'; picker.dispatchEvent(new Event('change'));", arguments: [:], in: nil, contentWorld: .defaultClient)
                for _ in 0..<40 where model.current.baseViews[buffer.id] != 1 { try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertEqual(model.current.baseViews[buffer.id], 1)
            } else {
                let selected = try await view.callAsyncJavaScript("return document.querySelector('.view-select').value", arguments: [:], in: nil, contentWorld: .defaultClient) as? String
                XCTAssertEqual(selected,"1")
            }
            window.contentView = NSView()
            try await Task.sleep(for: .milliseconds(80))
        }
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
                try await js("document.querySelector(\"td[data-column=status][data-path='Project.md']\").dispatchEvent(new MouseEvent('dblclick')); const input=document.querySelector('[data-property-editor=status]'); input.focus(); input.value='done'; input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));")
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

private struct CrowmapClickFixture: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 0) {
            ActivityBar()
            SidebarView().frame(width: 300)
            CrowmapDockArea { Color.white }.frame(width: 800).windowDragExcluded()
        }
    }
}

private struct MarkdownTitleFixture: View {
    @Environment(AppModel.self) private var model
    let id: BufferID
    var body: some View {
        if let (state, index) = model.locate(id) {
            WorkspaceMarkdownView(buffer: state.snapshot.buffers[index], text: Binding(get: { state.snapshot.buffers[index].text }, set: { model.updateBufferText(id, $0) }))
        }
    }
}
