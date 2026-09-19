import CrowCore
import SwiftUI
import WebKit

/// Each map owns a flat note directory beneath the account-wide map library. Merely constructing the store does not touch disk.
@MainActor @Observable final class CrowmapStore {
    let root: URL
    var noteRoot: URL { selected?.deletingLastPathComponent() ?? root }
    var maps: [URL] = []
    var selected: URL?
    var source = ""
    var texts: [String: String] = [:]
    var library: [String: String] = [:]
    var error: String?
    var drafts: [String: String] = [:]
    var draftBases: [String: String] = [:]
    @ObservationIgnored var flushDrafts: (() async -> Bool)?
    static let agentInstructions = """
    # Crowmap

    This folder is one Crowmap. It contains a .crowmap display cache and flat Markdown notes.
    Markdown frontmatter and wiki links are the source of truth. Edit the Markdown files;
    preserve unknown properties, bodies, comments and existing filenames. Do not invent IDs
    or rewrite the .crowmap cache to change links. Crow rebuilds it when the map is refreshed.

    ## Timeline structure
    - Each project starts with a Markdown note: kind: start, date: YYYY-MM-DD, priority: 1.
      Its filename is the project name. milestones is a list of [[Milestone note]] links.
    - Milestone notes have kind: milestone (legacy plan changes may use kind: revision),
      date, priority, project: [[Start note]], previous: [...] and next: [...].
    - Update BOTH previous and next when connecting milestones. Dates run forward; do not
      introduce cycles or links between different projects' milestone chains.
    - Every milestone with an incoming or outgoing timeline edge is a main milestone.
      Multiple main milestones may share a date, and branches may rejoin a shared note.
      Adding or connecting a milestone preserves all other connections. To abandon one,
      remove ALL incident links from BOTH endpoints' previous/next properties. Keep its
      file and its entry in the start note's milestones list; only isolated notes fade.
      inactive_next, replaces and cached edge states do not deactivate linked milestones.
      If a removed edge had work notes, change their between to milestone: "[[From]]".
    - Priority is an integer, 1 at the top. Changing priority at a milestone changes the
      project order from that point until another milestone changes it.

    ## Work notes and resources
    - Ordinary work notes have a date and either between: ["[[From]]", "[[To]]"] for a
      segment or milestone: "[[Milestone]]" for a memo. Segment dates must be within the
      two endpoints. A body [[Note]] link connects the same Markdown node, never a copy.
    - External URLs in a body become terminal resource nodes owned by that occurrence.
    - Names are readable: Project.md, Project-Research.md, Work note.md. Add a numeric
      suffix on collision. Keep all project notes directly in this folder, not subfolders.
    - Device notes may be cached read-only references in the map; do not treat them as
      locally editable Markdown files. Do not change or delete them through local copies.

    ## Agent sessions
    .sessions/<session>/ contains agent working directories, not project notes. Its notes/
    directory contains symlinks to the explicitly selected original Markdown files.
    Resolve those symlinks and edit their target files; do not replace symlinks with copies.
    AGENTS.md in each session names the selected notes and this map. Read their context,
    then follow the user's task; selection alone is not an instruction to modify notes.
    New project notes belong in the map folder. Never delete the map or unrelated notes.
    """
    private static let legacyTimelineInstructions = """
    - inactive_next lists outgoing next links retained as faded history. Each project
      has one active route from its start. A new branch preserves old notes and marks
      the former outgoing path inactive; a later shared milestone can rejoin both paths.
      Legacy revision notes may also have replaces links describing the historical path.
    """
    private static let timelineInstructions = """
    - Every milestone with an incoming or outgoing timeline edge is a main milestone.
      Multiple main milestones may share a date, and branches may rejoin a shared note.
      Adding or connecting a milestone preserves all other connections. To abandon one,
      remove ALL incident links from BOTH endpoints' previous/next properties. Keep its
      file and its entry in the start note's milestones list; only isolated notes fade.
      inactive_next, replaces and cached edge states do not deactivate linked milestones.
      If a removed edge had work notes, change their between to milestone: "[[From]]".
    """
    init(root: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".crow/crowmap")) { self.root = root.standardizedFileURL }
    func list() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var found: [URL] = []
            for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                let file = root.appendingPathComponent(entry.lastPathComponent)
                if file.pathExtension == "crowmap" { found.append(file) }
                else {
                    let folder = file.resolvingSymlinksInPath()
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                    for child in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) where child.pathExtension == "crowmap" {
                        found.append(file.appendingPathComponent(child.lastPathComponent))
                    }
                }
            }
            maps = found.filter { FileManager.default.fileExists(atPath: $0.resolvingSymlinksInPath().path) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func create(_ name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try TextFiles.validateName(title)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = title.hasSuffix(".crowmap") ? String(title.dropLast(8)) : title
        let folder = root.appendingPathComponent(base, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let url = folder.appendingPathComponent(base + ".crowmap")
        try writeEmptyMap(to: url, title: title)
        try load(url); list()
    }
    /// Open a folder of Markdown notes as a Crowmap. Folders already in the library get a display cache if needed; other folders are linked in (copied on iOS).
    @discardableResult func importFolder(_ folder: URL) throws -> URL {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let source = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CommandError("Choose a folder to open as a Crowmap.")
        }
        let rootPath = root.resolvingSymlinksInPath().path
        guard source.path != rootPath else { throw CommandError("Choose a map folder, not the Crowmap library.") }
        let deleted = root.deletingLastPathComponent().appendingPathComponent("crowmap-deleted").resolvingSymlinksInPath().path
        if source.path == deleted || source.path.hasPrefix(deleted + "/") {
            throw CommandError("Open a map folder, not crowmap-deleted.")
        }
        let title = source.lastPathComponent
        try TextFiles.validateName(title)
        guard !title.hasPrefix(".") else { throw CommandError("Choose a visible folder.") }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        list()
        if let existing = maps.first(where: { $0.deletingLastPathComponent().resolvingSymlinksInPath() == source }) {
            try load(existing); return selected ?? existing
        }
        let caches = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "crowmap" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let cacheName: String
        if caches.isEmpty {
            cacheName = title + ".crowmap"
            try writeEmptyMap(to: source.appendingPathComponent(cacheName), title: title)
        } else if let named = caches.first(where: { $0.deletingPathExtension().lastPathComponent == title }) {
            cacheName = named.lastPathComponent
        } else {
            cacheName = caches[0].lastPathComponent
        }
        if source.deletingLastPathComponent().resolvingSymlinksInPath() == root.resolvingSymlinksInPath() {
            let url = source.appendingPathComponent(cacheName)
            try load(url); list(); return selected ?? url
        }
        #if os(iOS)
        return try importFolderByCopying(source, title: title, cacheName: cacheName)
        #else
        return try importFolderByLinking(source, cacheName: cacheName)
        #endif
    }
    func noteURL(_ name: String, in folder: URL? = nil) throws -> URL {
        let directory = folder ?? noteRoot
        guard name.lowercased() != "agents.md" else { throw CommandError("AGENTS.md is reserved for Crowmap instructions.") }
        guard name.hasSuffix(".md"), !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw CommandError("Crowmap notes must be Markdown files directly inside their map folder.") }
        let url = directory.appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path else { throw CommandError("The note points outside the Crowmap folder.") }
        return url
    }
    func load(_ requested: URL) throws {
        var url = requested
        if !FileManager.default.fileExists(atPath: url.path), url.deletingLastPathComponent().path == root.path {
            let moved = root.appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true).appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: moved.path) { url = moved }
        }
        guard url.pathExtension == "crowmap" else { throw CommandError("Choose a .crowmap file.") }
        let value = try TextFiles.read(url)
        guard let doc = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any], doc["version"] as? Int == 1 else { throw CommandError("Unsupported Crowmap document.") }
        var available: [String: String] = [:]
        let directory = url.deletingLastPathComponent()
        let listing = directory.resolvingSymlinksInPath()
        try ensureAgentInstructions(in: listing)
        for file in try FileManager.default.contentsOfDirectory(at: listing, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) where file.pathExtension == "md" && file.lastPathComponent.lowercased() != "agents.md" {
            let safe = try noteURL(file.lastPathComponent, in: directory)
            if (try? safe.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { available[file.lastPathComponent] = try TextFiles.read(safe) }
        }
        var nextTexts: [String: String] = [:]
        for node in (doc["anchors"] as? [[String: Any]] ?? []) + (doc["notes"] as? [[String: Any]] ?? []) where node["device"] == nil {
            if let name = node["note"] as? String { nextTexts[name] = available[name] }
        }
        selected = url; source = value; texts = nextTexts; library = available; error = nil
    }
    func ensureAgentInstructions(in directory: URL) throws {
        let url = directory.appendingPathComponent("AGENTS.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data((Self.agentInstructions + "\n").utf8).write(to: url, options: .withoutOverwriting)
        } else if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true {
            let before = try TextFiles.read(url)
            let after = before.replacingOccurrences(of: Self.legacyTimelineInstructions, with: Self.timelineInstructions)
            if before != after { try Data(after.utf8).write(to: url, options: .atomic) }
        }
    }
    /// Copy file references, not graph descendants. Remote snapshots become real temporary .md files.
    func copyFileURLs(_ files: [[String: String]]) throws -> [URL] {
        guard !files.isEmpty, files.count <= 10000 else { throw CommandError("Select notes to copy.") }
        var urls: [URL] = []
        for file in files {
            guard let name = file["name"] else { throw CommandError("Invalid Markdown copy.") }
            let original = try noteURL(name)
            if let text = file["text"] {
                guard text.utf8.count <= 512 * 1024 else { throw CommandError("The Markdown snapshot is too large.") }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Crow-note-copy-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(name)
                try Data(text.utf8).write(to: url, options: .withoutOverwriting); urls.append(url)
            } else {
                guard let expected = file["expected"], try TextFiles.read(original) == expected else { throw CommandError("The note changed. Refresh before copying.") }
                urls.append(original)
            }
        }
        return urls
    }
    /// Create one isolated agent context while keeping the selected files as live originals.
    func prepareAgentSession(nodeIDs: [String]) throws -> URL {
        guard let selected, !nodeIDs.isEmpty,
              let doc = try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any] else { throw CommandError("Select notes in a Crowmap first.") }
        let nodes = doc["notes"] as? [[String: Any]] ?? [], ids = Set(nodeIDs)
        let chosen = nodes.filter { ($0["id"] as? String).map(ids.contains) == true }
        guard chosen.count == ids.count, chosen.allSatisfy({ $0["device"] == nil }) else { throw CommandError("Select local work notes for this agent session.") }
        let files = try chosen.map { node -> URL in
            guard let name = node["note"] as? String else { throw CommandError("Invalid selected note.") }
            let url = try noteURL(name)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CommandError("The selected note is missing.") }
            return url
        }
        try ensureAgentInstructions(in: noteRoot)
        let sessions = noteRoot.appendingPathComponent(".sessions", isDirectory: true)
        guard sessions.resolvingSymlinksInPath().deletingLastPathComponent().path == noteRoot.resolvingSymlinksInPath().path else { throw CommandError("The session folder points outside this map.") }
        let session = sessions.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let notes = session.appendingPathComponent("notes", isDirectory: true)
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
            for file in files { try FileManager.default.createSymbolicLink(at: notes.appendingPathComponent(file.lastPathComponent), withDestinationURL: file) }
            let instructions = try TextFiles.read(noteRoot.appendingPathComponent("AGENTS.md"))
                + "\n\n## This session\nMap folder: \(noteRoot.path)\nMap file: \(selected.lastPathComponent)\nSelected original notes (symlinks):\n"
                + files.map { "- notes/" + $0.lastPathComponent }.joined(separator: "\n") + "\n"
            try Data(instructions.utf8).write(to: session.appendingPathComponent("AGENTS.md"), options: .withoutOverwriting)
            try FileManager.default.createSymbolicLink(atPath: session.appendingPathComponent("CLAUDE.md").path, withDestinationPath: "AGENTS.md")
            return session
        } catch { try? FileManager.default.removeItem(at: session); throw error }
    }
    /// Rename a flat note and all exact local wiki references as one reversible operation.
    /// The .crowmap files are caches, but must retain node IDs across the rename.
    func renameNote(_ name: String, to newName: String, source replacement: String? = nil) throws -> [String: String] {
        let old = try noteURL(name), target = try noteURL(newName)
        guard old != target else { return [:] }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw CommandError("A note with this name already exists.") }
        let original = try TextFiles.read(old)
        var changes: [(URL, String, String)] = []
        for entry in try FileManager.default.contentsOfDirectory(at: noteRoot, includingPropertiesForKeys: nil) where ["md", "crowmap"].contains(entry.pathExtension) {
            let file = noteRoot.appendingPathComponent(entry.lastPathComponent)
            guard file.resolvingSymlinksInPath().deletingLastPathComponent().path == noteRoot.resolvingSymlinksInPath().path else { throw CommandError("A linked file points outside the Crowmap folder.") }
            let before = try TextFiles.read(file)
            var after = before
            if file.pathExtension == "md" {
                after = Self.renamedLinks(file == old ? replacement ?? before : before, from: name, to: newName)
            } else {
                guard var doc = try JSONSerialization.jsonObject(with: Data(before.utf8)) as? [String: Any] else { throw CommandError("Invalid map: " + file.lastPathComponent) }
                var changed = false
                for key in ["anchors", "notes"] {
                    var nodes = doc[key] as? [[String: Any]] ?? []
                    for index in nodes.indices where nodes[index]["device"] == nil && nodes[index]["note"] as? String == name {
                        nodes[index]["note"] = newName; changed = true
                    }
                    doc[key] = nodes
                }
                if changed { after = String(decoding: try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) + "\n" }
            }
            if before != after { changes.append((file, before, after)) }
        }
        var written: [(URL, String, String)] = []
        do {
            for (file, before, after) in changes {
                try TextFiles.write(after, to: file, expected: before); written.append((file, before, after))
            }
            guard try TextFiles.read(old) == (changes.first { $0.0 == old }?.2 ?? original) else { throw CommandError("The note changed while renaming. Try again.") }
            try FileManager.default.moveItem(at: old, to: target)
        } catch {
            for (file, before, after) in written.reversed() { try? TextFiles.write(before, to: file, expected: after) }
            throw error
        }
        return Dictionary(uniqueKeysWithValues: changes.map { ($0.0 == old ? target.path : $0.0.path, $0.2) })
    }
    static func renamedLinks(_ text: String, from old: String, to new: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"\[\[([^\n]+?)\]\]"#)
        let oldBase = String(old.dropLast(3)), newBase = String(new.dropLast(3))
        var output = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[range]), target = String(value.prefix { $0 != "#" && $0 != "|" })
            let bare = target.hasPrefix("./") ? String(target.dropFirst(2)) : target
            guard bare.precomposedStringWithCanonicalMapping == old.precomposedStringWithCanonicalMapping || bare.precomposedStringWithCanonicalMapping == oldBase.precomposedStringWithCanonicalMapping else { continue }
            output.replaceSubrange(range, with: (target.hasPrefix("./") ? "./" : "") + (bare.hasSuffix(".md") ? new : newBase) + value.dropFirst(target.count))
        }
        return output
    }
    /// Compare every file before writing. A stale window cannot overwrite newer work.
    func save(_ replacement: String, expected: String, writes: [[String: String]], deletes: [[String: String]] = [], deletingProject: String? = nil) throws {
        guard let selected, source == expected, try TextFiles.read(selected) == expected else { throw CommandError("This map changed in another window. Refresh before saving.") }
        guard replacement.utf8.count <= TextFiles.sizeLimit,
              let doc = try JSONSerialization.jsonObject(with: Data(replacement.utf8)) as? [String: Any], doc["version"] as? Int == 1 else { throw CommandError("Invalid Crowmap document.") }
        let names = Set(((doc["anchors"] as? [[String: Any]] ?? []) + (doc["notes"] as? [[String: Any]] ?? [])).filter { $0["device"] == nil }.compactMap { $0["note"] as? String })
        var prepared: [(URL, String, String?)] = [], unique = Set<String>()
        for write in writes {
            guard let name = write["name"], names.contains(name), unique.insert(name).inserted, let text = write["text"], text.utf8.count <= 512 * 1024 else { throw CommandError("Invalid Crowmap note write.") }
            let url = try noteURL(name), exists = FileManager.default.fileExists(atPath: url.path)
            let before = exists ? try TextFiles.read(url) : nil
            guard before == write["expected"] else { throw CommandError("A note changed outside this map. Refresh before saving.") }
            prepared.append((url, text, before))
        }
        let originalDoc = try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? [String: Any]
        var removable = Set((originalDoc?["notes"] as? [[String: Any]] ?? []).filter { $0["device"] == nil }.compactMap { $0["note"] as? String })
        if let deletingProject {
            guard (originalDoc?["projects"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == deletingProject }),
                  !(doc["projects"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == deletingProject }),
                  !(doc["anchors"] as? [[String: Any]] ?? []).contains(where: { $0["project"] as? String == deletingProject }),
                  !(doc["edges"] as? [[String: Any]] ?? []).contains(where: { $0["project"] as? String == deletingProject }) else { throw CommandError("Invalid timeline deletion.") }
            let anchors = (originalDoc?["anchors"] as? [[String: Any]] ?? []).filter { $0["project"] as? String == deletingProject }.compactMap { $0["note"] as? String }
            removable.formUnion(anchors)
            guard Set(deletes.compactMap { $0["name"] }).isSuperset(of: Set(anchors)) else { throw CommandError("A timeline deletion must include all its milestone files.") }
        }
        var removals: [(URL, URL)] = [], deletedNames = Set<String>()
        let trash = root.deletingLastPathComponent().appendingPathComponent("crowmap-deleted", isDirectory: true)
        for deletion in deletes {
            guard let name = deletion["name"], removable.contains(name), !names.contains(name), deletedNames.insert(name).inserted else { throw CommandError("Invalid note deletion.") }
            let file = try noteURL(name)
            guard try TextFiles.read(file) == deletion["expected"] else { throw CommandError("The note changed. Refresh before deleting.") }
            removals.append((file, trash.appendingPathComponent(UUID().uuidString + "-" + name)))
        }
        var written: [(URL, String?)] = [], moved: [(URL, URL)] = []
        do {
            for (url, text, before) in prepared {
                if let before { try TextFiles.write(text, to: url, expected: before) }
                else { try Data(text.utf8).write(to: url, options: .withoutOverwriting) }
                written.append((url, before))
            }
            if !removals.isEmpty { try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true) }
            for (file, backup) in removals {
                try FileManager.default.moveItem(at: file, to: backup); moved.append((file, backup))
            }
            try TextFiles.write(replacement, to: selected, expected: expected)
        } catch {
            for (file, backup) in moved.reversed() { try? FileManager.default.moveItem(at: backup, to: file) }
            for (url, before) in written.reversed() {
                if let before { try? Data(before.utf8).write(to: url, options: .atomic) }
                else { try? FileManager.default.removeItem(at: url) }
            }
            throw error
        }
        try load(selected)
    }
    private func writeEmptyMap(to url: URL, title: String) throws {
        let value: [String: Any] = ["version": 1, "id": UUID().uuidString, "title": title, "projects": [], "anchors": [], "edges": [], "notes": [], "devices": []]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .withoutOverwriting)
    }
    private func uniqueLibraryName(_ base: String) -> String {
        var name = base, number = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
                || FileManager.default.fileExists(atPath: root.appendingPathComponent(name + ".crowmap").path) {
            name = base + " \(number)"; number += 1
        }
        return name
    }
    #if os(iOS)
    private func importFolderByCopying(_ source: URL, title: String, cacheName: String) throws -> URL {
        let name = uniqueLibraryName(title), destination = root.appendingPathComponent(name)
        let staging = root.appendingPathComponent(".import-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            for entry in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            where entry.lastPathComponent != ".sessions" {
                try fm.copyItem(at: entry, to: staging.appendingPathComponent(entry.lastPathComponent))
            }
            let copied = staging.appendingPathComponent(cacheName)
            if !fm.fileExists(atPath: copied.path) { try writeEmptyMap(to: copied, title: name) }
            try fm.moveItem(at: staging, to: destination)
        } catch { try? fm.removeItem(at: staging); throw error }
        let url = destination.appendingPathComponent(cacheName)
        try load(url); list(); return selected ?? url
    }
    #else
    private func importFolderByLinking(_ source: URL, cacheName: String) throws -> URL {
        let link = root.appendingPathComponent(uniqueLibraryName(source.lastPathComponent))
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: source.path)
        let url = link.appendingPathComponent(cacheName)
        do { try load(url); list(); return selected ?? url }
        catch { try? FileManager.default.removeItem(at: link); throw error }
    }
    #endif
}

struct CrowmapSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var renameURL: URL?
    @State private var renameName = ""
    @State private var deleteURL: URL?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CROWMAP").font(.system(size: 11, weight: .medium)).foregroundStyle(CrowTheme.textDim)
                Spacer()
                Button { model.crowmap.list() } label: { PanelActionIcon(symbol: "arrow.clockwise") }
                    .buttonStyle(CrowButtonStyle()).help("Refresh Crowmap files").accessibilityLabel("Refresh Crowmap files").windowDragExcluded()
                CrowMenu {
                    Button("New Crowmap", systemImage: "plus") { model.createCrowmap() }
                        .accessibilityIdentifier("crow.crowmap.new-map")
                    Button("Open Folder…", systemImage: "folder") { model.crowmapFolderImporterVisible = true }
                        .accessibilityIdentifier("crow.crowmap.open-folder")
                } label: { PanelActionIcon(symbol: "plus") }
                    .help("New Crowmap or open a folder").accessibilityLabel("New Crowmap or open a folder")
            }.padding(.horizontal, 12).frame(height: 40)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.crowmap.maps, id: \.path) { url in
                        Button { model.openCrowmap(url) } label: {
                            HStack(spacing: 8) {
                                CrowmapIcon().frame(width: 15, height: 15)
                                Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 12).frame(height: 28)
                                .background(model.crowmap.selected?.path == url.path ? CrowTheme.accent.opacity(0.08) : .clear)
                                .contentShape(Rectangle())
                        }.buttonStyle(CrowButtonStyle()).windowDragExcluded()
                            .crowContextMenu {
                                Button("Rename…", systemImage: "pencil") { renameName = url.deletingPathExtension().lastPathComponent; renameURL = url }
                                Button("Duplicate", systemImage: "plus.square.on.square") {
                                    Task { do { let copy = try await model.duplicateCrowmap(url); model.openCrowmap(copy) } catch { model.report(error) } }
                                }
                                Divider()
                                Button("Delete…", systemImage: "trash", role: .destructive) { deleteURL = url }
                            }
                        ForEach(model.crowmapAgents(in: url.deletingLastPathComponent())) { item in
                            HStack(spacing: 4) {
                                Button { model.openAgentTerminal(item.agent.id, workspaceID: item.state.id) } label: {
                                    HStack(spacing: 7) {
                                        AgentProviderIcon(provider: item.agent.provider, size: 12)
                                        Text(item.agent.title).font(.system(size: 12)).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }.padding(.leading, 34).frame(height: 28).contentShape(Rectangle())
                                }.buttonStyle(CrowButtonStyle()).accessibilityIdentifier("crow.crowmap.agent." + item.agent.id.uuidString)
                                Button { model.requestTerminalClose(item.agent.id) } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 28) }
                                    .buttonStyle(CrowButtonStyle()).help("Close agent")
                            }.windowDragExcluded()
                        }
                    }
                }
            }
        }.task { model.crowmap.list() }
            .alert("Rename Crowmap", isPresented: Binding(get: { renameURL != nil }, set: { if !$0 { renameURL = nil } })) {
                TextField("Name", text: $renameName)
                Button("Rename") {
                    if let url = renameURL { let name = renameName; Task { do { _ = try await model.renameCrowmap(url, to: name) } catch { model.report(error) } } }
                }.keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete Crowmap?", isPresented: Binding(get: { deleteURL != nil }, set: { if !$0 { deleteURL = nil } }), presenting: deleteURL) { url in
                Button("Delete", role: .destructive) { Task { do { _ = try await model.deleteCrowmap(url) } catch { model.report(error) } } }.keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: { url in
                let name = url.deletingPathExtension().lastPathComponent
                Text(model.crowmapIsLinkedFolder(url)
                     ? "Remove “\(name)” from Crow? The original folder and notes stay where they are."
                     : model.crowmapOwnsFolder(url)
                     ? "Delete “\(name)” and its notes and timelines? A recovery copy is kept in crowmap-deleted."
                     : "Delete “\(url.lastPathComponent)”? Notes in this shared folder will remain.")
            }
    }
}

struct CrowmapSurface: View {
    @Environment(AppModel.self) private var model
    let store: CrowmapStore
    var isActive = true
    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error { Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(10) }
            if store.selected != nil { CrowmapWebView(model: model, store: store, isActive: isActive) }
            else if store.error == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { Spacer() }
        }.background(CrowTheme.bg0)
    }
}

struct CrowmapFileView: View {
    @Environment(AppModel.self) private var model
    let buffer: OpenBuffer
    @State private var store = CrowmapStore()
    var body: some View {
        CrowmapSurface(store: store).task(id: buffer.id) {
            do {
                guard !buffer.isRemote else { throw CommandError("Open the local Crowmap and attach this device's notes.") }
                if store.root != model.crowmap.root { store = CrowmapStore(root: model.crowmap.root) }
                let url = URL(fileURLWithPath: buffer.path)
                try store.load(url)
                if let moved = store.selected, moved.path != buffer.path, let (state, index) = model.locate(buffer.id), !state.snapshot.buffers[index].isDirty {
                    state.snapshot.buffers[index].path = moved.path
                    state.snapshot.buffers[index].text = store.source; state.snapshot.buffers[index].savedText = store.source
                    model.schedulePersist()
                }
                model.crowmap.selected = store.selected
            } catch { store.error = error.localizedDescription }
        }
    }
}

@MainActor struct CrowmapWebView {
    let model: AppModel
    let store: CrowmapStore
    var isActive = true
    func makeCoordinator() -> Coordinator { Coordinator(model: model, store: store) }
    func makeView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.add(coordinator, contentWorld: .defaultClient, name: "crowmap")
        let script = Bundle.main.url(forResource: "crowmap", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let style = Bundle.main.url(forResource: "crowmap", withExtension: "css").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        coordinator.requestedActive = isActive
        let view = WKWebView(frame: .zero, configuration: config); view.navigationDelegate = coordinator; coordinator.view = view
        view.loadHTMLString("<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline';\"><style>\(style)</style></head><body><main></main></body></html>", baseURL: nil)
        return view
    }
    func update(_ view: WKWebView, coordinator: Coordinator) {
        if coordinator.lastSource != store.source || coordinator.lastTexts != store.library { coordinator.publish() }
        coordinator.setActive(isActive)
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let model: AppModel, store: CrowmapStore
        weak var view: WKWebView?
        var ready = false, lastSource = ""
        var active = true, requestedActive = true
        func setActive(_ value: Bool) {
            requestedActive = value
            guard ready, active != value else { return }; active = value
            if !value {
                #if os(macOS)
                if let view, let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: view) { view.window?.makeFirstResponder(nil) }
                #else
                view?.endEditing(true)
                #endif
            }
            Task { [weak view] in _ = try? await view?.callAsyncJavaScript("window.crowMap.setActive(active)", arguments: ["active": value], in: nil, contentWorld: .defaultClient) }
        }
        var lastTexts: [String: String] = [:]
        init(model: AppModel, store: CrowmapStore) { self.model = model; self.store = store }
        func payload() -> [String: Any] {
            let hosts = model.hosts.filter { host in model.states.contains { $0.snapshot.workspace.hostID == host.id && $0.remote?.isConnected == true } }
            var drafts = store.drafts
            for buffer in model.states.flatMap(\.snapshot.buffers) where !buffer.isRemote && buffer.isDirty && (buffer.path as NSString).deletingLastPathComponent == store.noteRoot.path {
                drafts[(buffer.path as NSString).lastPathComponent] = buffer.text
            }
            #if os(macOS)
            let providers = AgentProvider.allCases.map { ["id": $0.rawValue, "title": $0.title] }
            #else
            let providers: [[String: String]] = []
            #endif
            return ["source": store.source, "texts": store.library, "drafts": drafts, "agentProviders": providers, "hosts": hosts.map { ["id": $0.id.rawValue.uuidString, "label": $0.userAtHost] }]
        }
        func publish(_ method: String = "receive", error: String? = nil) {
            guard ready else { return }; lastSource = store.source; lastTexts = store.library
            let value: [String: Any] = error.map { ["error": $0] } ?? payload()
            Task { [weak view] in _ = try? await view?.callAsyncJavaScript("window.crowMap[method](value)", arguments: ["method": method, "value": value], in: nil, contentWorld: .defaultClient) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true; setActive(requestedActive); publish()
            store.flushDrafts = { [weak webView] in
                (try? await webView?.callAsyncJavaScript("return await window.crowMap.flush()", arguments: [:], in: nil, contentWorld: .defaultClient)) as? Bool == true
            }
        }
        func remoteState(_ id: String) throws -> WorkspaceState {
            guard let uuid = UUID(uuidString: id), let state = model.states.first(where: { $0.snapshot.workspace.hostID?.rawValue == uuid && $0.remote?.isConnected == true }) else { throw CommandError("Connect this device in Workspaces first.") }
            return state
        }
        func remoteRoot(_ state: WorkspaceState) async throws -> String {
            guard let remote = state.remote else { throw FileFailure.disconnected }
            let home = try await remote.realPath(".")
            let account = try await remote.realPath((home as NSString).appendingPathComponent(".crow/crowmap"))
            if store.noteRoot != store.root, let folder = try? await remote.realPath((account as NSString).appendingPathComponent(store.noteRoot.lastPathComponent)) { return folder }
            return account
        }
        func remoteNote(_ name: String, state: WorkspaceState) async throws -> String {
            _ = try store.noteURL(name)
            guard let remote = state.remote else { throw FileFailure.disconnected }
            let root = try await remoteRoot(state), path = try await remote.realPath((root as NSString).appendingPathComponent(name))
            guard path.hasPrefix(root + "/") else { throw CommandError("The note points outside this account's Crowmap folder.") }
            return path
        }
        func fetchRemoteNotes(_ hostID: String) async throws -> [[String: String]] {
            let state = try remoteState(hostID), root = try await remoteRoot(state)
            guard let remote = state.remote else { throw FileFailure.disconnected }
            let files = try await remote.list(root)
            var notes: [[String: String]] = [], total = 0
            for file in files.filter({ !$0.isDirectory && $0.name.hasSuffix(".md") && !$0.name.hasPrefix(".") }).prefix(300) {
                try Task.checkCancellation()
                let path = try await remote.realPath((root as NSString).appendingPathComponent(file.name))
                guard path.hasPrefix(root + "/") else { continue }
                let bytes = try await remote.readData(path, maximumSize: 128 * 1024)
                total += bytes.count; guard total <= 10 * 1024 * 1024 else { throw CommandError("This device's notes exceed the 10 MB refresh limit.") }
                let text = try TextFiles.decode(bytes), metadata = Self.noteMetadata(text)
                if let date = metadata["date"] { notes.append(["name": file.name, "date": date, "title": metadata["title"] ?? file.name, "text": text]) }
            }
            return notes
        }
        func refreshDevices() {
            guard let selected = store.selected,
                  let doc = try? JSONSerialization.jsonObject(with: Data(store.source.utf8)) as? [String: Any],
                  let devices = doc["devices"] as? [[String: Any]], let mapID = doc["id"] as? String else { return }
            Task { [weak self] in
                guard let self else { return }
                for device in devices {
                    guard store.selected == selected, let hostID = device["hostID"] as? String else { continue }
                    do {
                        let notes = try await fetchRemoteNotes(hostID)
                        guard store.selected == selected else { return }
                        _ = try await view?.callAsyncJavaScript("return window.crowMap.refreshDevice(value)", arguments: ["value": ["hostID": hostID, "mapID": mapID, "notes": notes]], in: nil, contentWorld: .defaultClient)
                    } catch { store.error = "Device refresh: " + error.localizedDescription }
                }
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
            if action == "focus" {
                if active, let url = store.selected { model.focusCrowmapPanel(url) }
            } else if action == "draft", let name = body["name"] as? String, let text = body["source"] as? String, let expected = body["expected"] as? String {
                do {
                    guard text.utf8.count <= 512 * 1024, let saved = store.library[name] else { throw CommandError("Invalid note draft.") }
                    let url = try store.noteURL(name)
                    if let state = model.states.first(where: { $0.snapshot.buffers.contains { !$0.isRemote && $0.path == url.path } }),
                       let index = state.snapshot.buffers.firstIndex(where: { !$0.isRemote && $0.path == url.path }) {
                        guard state.snapshot.buffers[index].text == expected else { throw CommandError("This note changed in another editor. Your draft is still in this popup; reopen the note to reconcile it.") }
                        state.snapshot.buffers[index].text = text
                        state.snapshot.buffers[index].isDirty = text != state.snapshot.buffers[index].savedText
                    } else {
                        guard (store.drafts[name] ?? saved) == expected else { throw CommandError("This note changed. Refresh before editing.") }
                    }
                    if store.draftBases[name] == nil { store.draftBases[name] = saved }
                    store.drafts[name] = text
                    model.schedulePersist()
                } catch {
                    Task { [weak view] in _ = try? await view?.callAsyncJavaScript("window.crowMap.draftError(name, message)", arguments: ["name": name, "message": error.localizedDescription], in: nil, contentWorld: .defaultClient) }
                }
            } else if action == "markdown", let text = body["text"] as? String, text.utf8.count <= 512 * 1024, let id = body["id"] as? String {
                Task { [weak view = message.webView] in
                    let html = await Task.detached(priority: .utility) { MarkdownPreview.body(text) }.value
                    _ = try? await view?.callAsyncJavaScript("window.crowMap.markdown(id, html)", arguments: ["id": id, "html": html], in: nil, contentWorld: .defaultClient)
                }
            } else if action == "copyNotes", let files = body["files"] as? [[String: String]] {
                do {
                    let paths = try Set(files.filter { $0["text"] == nil }.compactMap { $0["name"] }.map { try store.noteURL($0).path })
                    guard !model.states.flatMap(\.snapshot.buffers).contains(where: { !$0.isRemote && $0.isDirty && paths.contains($0.path) }) else { throw CommandError("Save the selected notes before copying.") }
                    guard !files.contains(where: { $0["text"] == nil && store.drafts[$0["name"] ?? ""] != nil }) else { throw CommandError("Save the selected notes before copying.") }
                    let urls = try store.copyFileURLs(files)
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.writeObjects(urls.map { $0 as NSURL }) else { throw CommandError("Could not copy the Markdown files.") }
                    #else
                    UIPasteboard.general.urls = urls
                    #endif
                } catch {
                    let error = error.localizedDescription
                    Task { [weak view] in _ = try? await view?.callAsyncJavaScript("window.crowMap.error(message)", arguments: ["message": error], in: nil, contentWorld: .defaultClient) }
                }
            } else if action == "save" {
                do {
                    guard let source = body["source"] as? String, let expected = body["expected"] as? String, let writes = body["writes"] as? [[String: String]] else { throw CommandError("Invalid map edit.") }
                    let deletes = body["deletes"] as? [[String: String]] ?? []
                    let reads = body["reads"] as? [[String: String]] ?? []
                    for write in writes {
                        if let name = write["name"], let draft = store.drafts[name], draft != write["text"], body["draftNote"] as? String != name {
                            throw CommandError("Save the affected note before changing its links or properties.")
                        }
                        if let name = write["name"], let base = store.draftBases[name], base != store.library[name] {
                            throw CommandError("This note changed since your draft. Your draft is retained; reconcile it before saving.")
                        }
                    }
                    guard !(deletes + reads).contains(where: { store.drafts[$0["name"] ?? ""] != nil }) else { throw CommandError("Save the affected notes before deleting or duplicating them.") }
                    for read in reads {
                        guard let name = read["name"], let expected = read["expected"], try TextFiles.read(store.noteURL(name)) == expected else { throw CommandError("A source note changed. Refresh before duplicating.") }
                    }
                    let paths = try Set((writes + deletes + reads).compactMap { $0["name"] }.map { try store.noteURL($0).path } + [store.selected?.path].compactMap { $0 })
                    guard !model.states.contains(where: { state in state.snapshot.buffers.contains { buffer in
                        guard paths.contains(buffer.path), buffer.isDirty else { return false }
                        return !writes.contains { $0["name"] == (buffer.path as NSString).lastPathComponent && $0["text"] == buffer.text }
                    } }) else { throw CommandError("Save or discard the open Markdown editor's changes before editing this map.") }
                    try store.save(source, expected: expected, writes: writes, deletes: deletes, deletingProject: body["deletingProject"] as? String)
                    for write in writes {
                        if let name = write["name"], let text = write["text"], store.drafts[name] != nil {
                            if store.drafts[name] == text { store.drafts.removeValue(forKey: name); store.draftBases.removeValue(forKey: name) }
                            else { store.draftBases[name] = text }
                        }
                    }
                    for state in model.states {
                        for index in state.snapshot.buffers.indices where paths.contains(state.snapshot.buffers[index].path) {
                            let path = state.snapshot.buffers[index].path
                            let text = path == store.selected?.path ? store.source : store.texts[(path as NSString).lastPathComponent]
                            if let text { state.snapshot.buffers[index].text = text; state.snapshot.buffers[index].savedText = text; state.snapshot.buffers[index].isDirty = false }
                        }
                    }
                    let deletedPaths = try Set(deletes.compactMap { $0["name"] }.map { try store.noteURL($0).path })
                    for id in model.states.flatMap(\.snapshot.buffers).filter({ !$0.isRemote && deletedPaths.contains($0.path) }).map(\.id) { model.closeBuffer(id) }
                    model.schedulePersist(); publish("saved")
                } catch { publish("saved", error: error.localizedDescription) }
            } else if action == "rename", let name = body["name"] as? String, let title = body["title"] as? String,
                      let source = body["source"] as? String, let expected = body["expected"] as? String {
                Task {
                    var result: [String: Any]
                    do {
                        let url = try store.noteURL(name)
                        guard try TextFiles.read(url) == expected else { throw CommandError("The note changed. Refresh before renaming.") }
                        var buffer = model.states.flatMap(\.snapshot.buffers).first { !$0.isRemote && $0.path == url.path }
                        if buffer == nil {
                            var created = OpenBuffer(title: name, path: url.path, text: expected, language: .markdown, isRemote: false)
                            created.savedText = expected
                            model.current.snapshot.buffers.append(created); buffer = created
                        }
                        guard let buffer, buffer.text == expected else { throw CommandError("Save the open note before renaming.") }
                        let renamed = try await model.renameMarkdown(buffer.id, title: title, source: source)
                        if let selected = store.selected { try store.load(selected) }
                        result = payload(); result["name"] = renamed
                    } catch { result = ["error": error.localizedDescription] }
                    _ = try? await view?.callAsyncJavaScript("window.crowMap.renamed(value)", arguments: ["value": result], in: nil, contentWorld: .defaultClient)
                }
            } else if action == "runAgent", let providerName = body["provider"] as? String,
                      let provider = AgentProvider(rawValue: providerName), let ids = body["nodeIDs"] as? [String] {
                #if os(macOS)
                do {
                    let selectedIDs = Set(ids)
                    let doc = try JSONSerialization.jsonObject(with: Data(store.source.utf8)) as? [String: Any]
                    let names = (doc?["notes"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String).map(selectedIDs.contains) == true }.compactMap { $0["note"] as? String }
                    let paths = try Set(names.map { try store.noteURL($0).path })
                    guard !model.states.flatMap(\.snapshot.buffers).contains(where: { !$0.isRemote && $0.isDirty && paths.contains($0.path) }) else { throw CommandError("Save the selected notes before starting an agent.") }
                    guard !names.contains(where: { store.drafts[$0] != nil }) else { throw CommandError("Save the selected notes before starting an agent.") }
                    let session = try store.prepareAgentSession(nodeIDs: ids)
                    if model.current.snapshot.workspace.isRemote || !model.hasWorkspace {
                        if let local = model.states.first(where: { !$0.snapshot.workspace.isRemote }) { model.activateWorkspace(local.id, reconnect: false) }
                        else { model.openFolder(store.noteRoot) }
                    }
                    _ = model.newAgentTerminal(provider, directory: session.path, conversationTitle: "Crowmap · \(ids.count) notes", reuseTmux: false, crowmapPath: store.selected?.path)
                } catch {
                    let message = error.localizedDescription
                    Task { [weak view] in _ = try? await view?.callAsyncJavaScript("window.crowMap.error(message)", arguments: ["message": message], in: nil, contentWorld: .defaultClient) }
                }
                #endif
            } else if action == "refresh" {
                do { if let selected = store.selected { try store.load(selected) }; publish(); refreshDevices() }
                catch { store.error = error.localizedDescription }
            } else if action == "remoteNotes", let hostID = body["hostID"] as? String {
                Task { [weak self] in
                    guard let self else { return }
                    var result: [String: Any] = ["hostID": hostID]
                    do {
                        result["notes"] = try await fetchRemoteNotes(hostID)
                    } catch { result["error"] = error.localizedDescription }
                    _ = try? await view?.callAsyncJavaScript("window.crowMap.remote(value)", arguments: ["value": result], in: nil, contentWorld: .defaultClient)
                }
            } else if action == "openNote", let name = body["name"] as? String {
                Task {
                    do {
                        let state: WorkspaceState, path: String
                        if let host = body["hostID"] as? String { state = try remoteState(host); path = try await remoteNote(name, state: state) }
                        else {
                            path = try store.noteURL(name).path
                            if !model.current.snapshot.workspace.isRemote, model.hasWorkspace { state = model.current }
                            else if let local = model.states.first(where: { !$0.snapshot.workspace.isRemote }) { state = local }
                            else { model.openFolder(store.noteRoot); state = model.current }
                        }
                        model.activateWorkspace(state.id, reconnect: false)
                        model.openFile(.init(name: name, path: path, isDirectory: false))
                    } catch { store.error = error.localizedDescription }
                }
            } else if action == "openLink", let value = body["url"] as? String {
                if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    model.newBrowser(address: value); model.sidebarPane = .files
                } else if let url = URL(string: value), ["mailto", "file"].contains(url.scheme?.lowercased() ?? "") {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    UIApplication.shared.open(url)
                    #endif
                } else {
                    Task {
                        do {
                            let relative = value.components(separatedBy: "#")[0].removingPercentEncoding ?? value
                            guard !relative.isEmpty, URL(string: relative)?.scheme == nil else { throw CommandError("Unsupported link.") }
                            let state: WorkspaceState, path: String
                            if let host = body["hostID"] as? String {
                                state = try remoteState(host)
                                guard let remote = state.remote else { throw FileFailure.disconnected }
                                let root = try await remoteRoot(state)
                                let name = (relative as NSString).pathExtension.isEmpty ? relative + ".md" : relative
                                path = try await remote.realPath(relative.hasPrefix("/") ? relative : (root as NSString).appendingPathComponent(name))
                            } else {
                                let target = (relative as NSString).pathExtension.isEmpty ? relative + ".md" : relative
                                let named = store.texts.first { Self.noteMetadata($0.value)["title"] == relative }?.key
                                path = relative.hasPrefix("/") ? relative : store.noteRoot.appendingPathComponent(named ?? target).standardizedFileURL.path
                                if !model.current.snapshot.workspace.isRemote, model.hasWorkspace { state = model.current }
                            else if let local = model.states.first(where: { !$0.snapshot.workspace.isRemote }) { state = local }
                                else { model.openFolder(store.noteRoot); state = model.current }
                            }
                            model.activateWorkspace(state.id, reconnect: false)
                            model.openFile(.init(name: (path as NSString).lastPathComponent, path: path, isDirectory: false))
                        } catch { store.error = error.localizedDescription }
                    }
                }
            }
        }
        static func noteMetadata(_ text: String) -> [String: String] {
            guard text.hasPrefix("---\n"), let end = text.dropFirst(4).range(of: "\n---") else { return [:] }
            let front = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
            var result: [String: String] = [:]
            for line in front.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1); guard parts.count == 2 else { continue }
                let key = String(parts[0]); guard ["title", "date"].contains(key) else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                result[key] = (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
            return result
        }
    }
}
#if os(macOS)
extension CrowmapWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.configuration.userContentController.removeScriptMessageHandler(forName: "crowmap", contentWorld: .defaultClient) }
}
#else
extension CrowmapWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.configuration.userContentController.removeScriptMessageHandler(forName: "crowmap", contentWorld: .defaultClient) }
}
#endif

@MainActor final class CrowmapPanelTab: Identifiable {
    nonisolated let url: URL
    let store: CrowmapStore
    nonisolated var id: String { url.path }
    init(url: URL, store: CrowmapStore) { self.url = url.standardizedFileURL; self.store = store }
}

extension AppModel {
    func isCrowmapPinned(_ path: String) -> Bool { crowmapPanel.pinnedPaths?.contains(path) == true }
    func toggleCrowmapPin(_ path: String) {
        guard crowmapTabs.contains(where: { $0.id == path }) else { return }
        var pins = crowmapPanel.pinnedPaths ?? []
        if pins.contains(path) { pins.removeAll { $0 == path } } else { pins.append(path) }
        crowmapPanel.pinnedPaths = pins; orderCrowmapPins()
    }
    func orderCrowmapPins() {
        let paths = Set(crowmapTabs.map(\.id)), pins = (crowmapPanel.pinnedPaths ?? []).filter { paths.contains($0) }
        crowmapPanel.pinnedPaths = pins.isEmpty ? nil : pins
        let pinned = Set(pins)
        crowmapTabs = crowmapTabs.filter { pinned.contains($0.id) } + crowmapTabs.filter { !pinned.contains($0.id) }
        crowmapPanel.paths = crowmapTabs.map(\.id)
    }
    var focusedPanelCrowmap: String? {
        crowmapPanel.visible && crowmapPanelFocused ? crowmapPanel.selectedPath : nil
    }
    var agentContextPath: String {
        focusedPanelCrowmap.map { ($0 as NSString).deletingLastPathComponent } ?? current.agentHistoryPath
    }
    var savedCrowmapPanel: CrowmapPanelSnapshot {
        var saved = crowmapPanel
        saved.paths = crowmapTabs.map(\.id)
        saved.drafts = Dictionary(uniqueKeysWithValues: crowmapTabs.filter { !$0.store.drafts.isEmpty }.map { ($0.id, $0.store.drafts) })
        saved.draftBases = Dictionary(uniqueKeysWithValues: crowmapTabs.filter { !$0.store.draftBases.isEmpty }.map { ($0.id, $0.store.draftBases) })
        return saved
    }
    func focusCrowmapPanel(_ url: URL) {
        guard crowmapPanel.visible, crowmapPanel.selectedPath == url.path else { return }
        crowmapPanelFocused = true
    }
    func hideCrowmapPanel() {
        crowmapPanel.visible = false; crowmapPanelFocused = false
    }
    func closeCrowmapTab(_ path: String) {
        guard let tab = crowmapTabs.first(where: { $0.id == path }) else { return }
        Task {
            if !tab.store.drafts.isEmpty {
                guard await tab.store.flushDrafts?() == true, tab.store.drafts.isEmpty else { report(CommandError("Save the Crowmap note before closing this tab.")); return }
            }
            guard let index = crowmapTabs.firstIndex(where: { $0 === tab }) else { return }
            crowmapTabs.remove(at: index); orderCrowmapPins()
            if crowmapPanel.selectedPath == path {
                let next = crowmapTabs.isEmpty ? nil : crowmapTabs[min(index, crowmapTabs.count - 1)]
                crowmapPanel.selectedPath = next?.id; crowmap.selected = next?.url
            }
            if crowmapTabs.isEmpty { crowmapPanelFocused = false }
            schedulePersist()
        }
    }
    func refreshCrowmapPanels(containing directory: String) {
        for tab in crowmapTabs where tab.url.deletingLastPathComponent().path == directory && tab.store.drafts.isEmpty {
            do { try tab.store.load(tab.url) } catch { tab.store.error = error.localizedDescription }
        }
    }
    func restoreCrowmapPanel() {
        // Move clean legacy map tabs out of workspace layouts without touching dirty source buffers.
        var paths = crowmapPanel.paths
        for state in states {
            let legacy = state.snapshot.buffers.filter { !$0.isRemote && !$0.isDirty && $0.path.hasSuffix(".crowmap") && FileManager.default.fileExists(atPath: $0.path) }
            for buffer in legacy {
                if !paths.contains(buffer.path) { paths.append(buffer.path); crowmapPanel.visible = true }
                state.snapshot.layout?.remove(.file(buffer.id))
                state.snapshot.buffers.removeAll { $0.id == buffer.id }
                if state.snapshot.selectedBufferID == buffer.id { state.snapshot.selectedBufferID = state.snapshot.buffers.last?.id }
                if state.snapshot.splitBufferID == buffer.id { state.snapshot.splitBufferID = nil }
            }
            if state.snapshot.layout?.allTabs.isEmpty == true { state.snapshot.layout?.open(.start(UUID())) }
        }
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            let url = URL(fileURLWithPath: path), store = CrowmapStore(root: crowmap.root)
            do { try store.load(url) } catch { store.error = error.localizedDescription }
            let loadedURL = (store.selected ?? url).standardizedFileURL
            if let existing = crowmapTabs.first(where: { $0.id == loadedURL.path }) {
                existing.store.drafts.merge(crowmapPanel.drafts[path] ?? [:]) { draft, _ in draft }
                existing.store.draftBases.merge(crowmapPanel.draftBases[path] ?? [:]) { base, _ in base }
            } else {
                store.drafts = crowmapPanel.drafts[path] ?? [:]; store.draftBases = crowmapPanel.draftBases[path] ?? [:]
                crowmapTabs.append(CrowmapPanelTab(url: loadedURL, store: store))
            }
            if crowmapPanel.selectedPath == path { crowmapPanel.selectedPath = loadedURL.path }
        }
        orderCrowmapPins()
        if !crowmapTabs.contains(where: { $0.id == crowmapPanel.selectedPath }) { crowmapPanel.selectedPath = crowmapTabs.first?.id }
        crowmap.selected = crowmapPanel.selectedPath.map { URL(fileURLWithPath: $0) }
        crowmapPanelFocused = false
    }
    func panelAgentHistorySource() -> (WorkspaceState, String)? {
        guard let path = focusedPanelCrowmap else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        if crowmapHistoryContext?.snapshot.rootPath != folder {
            let state = WorkspaceState(.init(workspace: .init(name: "Crowmap", kind: .local, connection: .local), rootPath: folder))
            state.panelCrowmapDirectory = folder; crowmapHistoryContext = state
        }
        return crowmapHistoryContext.map { ($0, folder) }
    }
}

/// A window-level dock: its map views stay mounted as the upper workspace changes.
struct CrowmapDockArea<Content: View>: View {
    @Environment(AppModel.self) private var model
    @State private var dragStart: CGFloat?
    @State private var liveHeight: CGFloat?
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geometry in
            let available = max(100, geometry.size.height - 60)
            let height = min(available, max(160, liveHeight ?? CGFloat(model.crowmapPanel.height)))
            VStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                ResizeHandle(axis: .vertical, label: "Resize Crowmap panel", onDrag: { delta in
                    if dragStart == nil { dragStart = height }
                    liveHeight = min(available, max(160, (dragStart ?? height) - delta))
                }, onEnd: {
                    if let liveHeight { model.crowmapPanel.height = Double(liveHeight) }
                    dragStart = nil; liveHeight = nil
                }).frame(height: model.crowmapPanel.visible ? ResizeHandle.thickness : 0).clipped()
                CrowmapDockPanel()
                    .frame(height: model.crowmapPanel.visible ? (model.crowmapPanel.maximized ? available : height) : 0)
                    .opacity(model.crowmapPanel.visible ? 1 : 0)
                    .allowsHitTesting(model.crowmapPanel.visible)
                    .accessibilityHidden(!model.crowmapPanel.visible)
                    .clipped()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CrowmapDockPanel: View {
    @Environment(AppModel.self) private var model
    private var selected: String? { model.crowmapPanel.selectedPath }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { model.showCrowmap() } label: {
                    CrowmapIcon().frame(width: 15, height: 15).frame(width: 28, height: 30)
                }.help("Crowmap files").accessibilityLabel("Crowmap files")
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(model.crowmapTabs) { tab in
                            let pinned = model.isCrowmapPinned(tab.id)
                            HStack(spacing: 4) {
                                Button { model.openCrowmap(tab.url) } label: {
                                    HStack(spacing: 5) {
                                        if pinned { Image(systemName: "pin.fill").font(.system(size: 10)).help("Pinned tab") }
                                        Text(tab.url.deletingPathExtension().lastPathComponent).font(.system(size: 12)).lineLimit(1)
                                    }.padding(.leading, 10).padding(.vertical, 8)
                                }.accessibilityIdentifier("crow.crowmap.tab." + tab.id)
                                Button { model.closeCrowmapTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 22, height: 28) }
                                    .help("Close Crowmap tab")
                            }.foregroundStyle(selected == tab.id ? CrowTheme.text : CrowTheme.textDim)
                                .background(selected == tab.id ? CrowTheme.bg0 : .clear)
                                .overlay(alignment: .bottom) { if selected == tab.id { CrowTheme.accent.frame(height: 1) } }
                                .crowContextMenu {
                                    Button(pinned ? "Unpin Tab" : "Pin Tab", systemImage: pinned ? "pin.slash" : "pin") { model.toggleCrowmapPin(tab.id) }
                                    Divider()
                                    Button("Close Tab", systemImage: "xmark") { model.closeCrowmapTab(tab.id) }
                                }
                        }
                    }
                }.scrollIndicators(.hidden)
                CrowMenu {
                    Button("New Crowmap", systemImage: "plus") { model.createCrowmap() }
                    Button("Open Folder…", systemImage: "folder") { model.crowmapFolderImporterVisible = true }
                    Divider()
                    ForEach(model.crowmap.maps, id: \.path) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { model.openCrowmap(url) }
                    }
                } label: { PanelActionIcon(symbol: "plus") }
                    .help("Open or create Crowmap").accessibilityLabel("Open or create Crowmap")
                CrowMenu {
                    ForEach(model.settings.enabledAgentProviders) { provider in
                        Button(provider.title) {
                            if let selected { model.newAgentTerminal(provider, crowmapPath: selected) }
                        }
                    }
                } label: { PanelActionIcon(symbol: "terminal") }
                    .disabled(selected == nil).help("New Crowmap agent").accessibilityLabel("New Crowmap agent")
                Button { model.crowmapPanel.maximized.toggle() } label: {
                    PanelActionIcon(symbol: model.crowmapPanel.maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }.help("Maximize or restore Crowmap panel").accessibilityLabel("Maximize or restore Crowmap panel")
                Button { model.hideCrowmapPanel() } label: { PanelActionIcon(symbol: "xmark") }
                    .help("Hide Crowmap panel").accessibilityLabel("Hide Crowmap panel")
            }.padding(.horizontal, 6).frame(height: 36).background(CrowTheme.bg1)
                .buttonStyle(CrowButtonStyle()).windowDragExcluded()
            CrowDivider()
            ZStack {
                if model.crowmapTabs.isEmpty {
                    VStack(spacing: 12) {
                        Text("Crowmap").font(.system(size: 16, weight: .medium))
                        Text("Open a map from the file list, create a new one, or open a folder of notes.").font(.system(size: 12)).foregroundStyle(CrowTheme.textDim)
                        Button("New Crowmap") { model.createCrowmap() }.buttonStyle(CrowButtonStyle(kind: .filled))
                        Button("Open Folder…") { model.crowmapFolderImporterVisible = true }.buttonStyle(CrowButtonStyle())
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(model.crowmapTabs) { tab in
                    let active = model.crowmapPanel.visible && selected == tab.id
                    CrowmapSurface(store: tab.store, isActive: active)
                        .opacity(active ? 1 : 0).allowsHitTesting(active).accessibilityHidden(!active)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }.background(CrowTheme.bg0).accessibilityIdentifier("crow.crowmap.panel")
            .task { model.crowmap.list() }
    }
}


extension AppModel {
    /// Agent history is keyed by this directory: renaming a map keeps its folder stable.
    func crowmapOwnsFolder(_ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard folder.standardizedFileURL.deletingLastPathComponent().path == crowmap.root.path,
              (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return false }
        return entries.filter { $0.pathExtension == "crowmap" }.map { $0.standardizedFileURL.path } == [url.standardizedFileURL.path]
    }
    func crowmapIsLinkedFolder(_ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        return folder.standardizedFileURL.deletingLastPathComponent().path == crowmap.root.path
            && (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
    private func prepareCrowmapFileAction(_ url: URL, includingNotes: Bool) async throws -> CrowmapStore {
        let folder = url.deletingLastPathComponent().path
        for tab in crowmapTabs where tab.url == url || includingNotes && tab.store.noteRoot.path == folder {
            if !tab.store.drafts.isEmpty {
                guard await tab.store.flushDrafts?() == true, tab.store.drafts.isEmpty else { throw CommandError("Save the Crowmap note before changing this map.") }
            }
        }
        guard !states.flatMap(\.snapshot.buffers).contains(where: {
            !$0.isRemote && $0.isDirty && ($0.path == url.path || includingNotes && $0.path.hasPrefix(folder + "/"))
        }) else { throw CommandError("Save the open notes before changing this map.") }
        guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw CommandError("Open the original Crowmap file to change it.") }
        let store = CrowmapStore(root: crowmap.root); try store.load(url); return store
    }
    @discardableResult func renameCrowmap(_ url: URL, to name: String) async throws -> URL {
        let store = try await prepareCrowmapFileAction(url, includingNotes: false)
        var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.lowercased().hasSuffix(".crowmap") { title = String(title.dropLast(8)) }
        try TextFiles.validateName(title)
        guard !title.hasPrefix(".") else { throw CommandError("Choose a visible map name.") }
        let destination = url.deletingLastPathComponent().appendingPathComponent(title + ".crowmap")
        if destination == url { return url }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CommandError("A Crowmap with this name already exists.") }
        var document = try JSONSerialization.jsonObject(with: Data(store.source.utf8)) as! [String: Any]
        document["title"] = title
        let source = String(decoding: try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) + "\n"
        var instructions: [(URL, String, String)] = []
        let sessions = url.deletingLastPathComponent().appendingPathComponent(".sessions")
        if (try? sessions.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
           let children = try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for child in children where (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false {
                let file = child.appendingPathComponent("AGENTS.md")
                guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
                let before = try TextFiles.read(file)
                let after = before.replacingOccurrences(of: "\nMap file: \(url.lastPathComponent)\n", with: "\nMap file: \(destination.lastPathComponent)\n")
                if before != after { instructions.append((file, before, after)) }
            }
        }
        try TextFiles.write(source, to: url, expected: store.source)
        var changed: [(URL, String, String)] = []
        do {
            for item in instructions { try TextFiles.write(item.2, to: item.0, expected: item.1); changed.append(item) }
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            for item in changed.reversed() { try? TextFiles.write(item.1, to: item.0, expected: item.2) }
            try? TextFiles.write(store.source, to: url, expected: source); throw error
        }
        for index in crowmapTabs.indices where crowmapTabs[index].url == url {
            let open = crowmapTabs[index].store; try open.load(destination)
            crowmapTabs[index] = CrowmapPanelTab(url: destination, store: open)
        }
        if crowmapPanel.selectedPath == url.path { crowmapPanel.selectedPath = destination.path }
        crowmapPanel.pinnedPaths = crowmapPanel.pinnedPaths?.map { $0 == url.path ? destination.path : $0 }
        if crowmap.selected == url { crowmap.selected = destination }
        for state in states {
            for index in state.snapshot.agentTerminals.indices where state.snapshot.agentTerminals[index].crowmapPath == url.path {
                state.snapshot.agentTerminals[index].crowmapPath = destination.path
            }
            for index in state.snapshot.buffers.indices where !state.snapshot.buffers[index].isRemote && state.snapshot.buffers[index].path == url.path {
                state.snapshot.buffers[index].path = destination.path; state.snapshot.buffers[index].title = destination.lastPathComponent
                state.snapshot.buffers[index].text = source; state.snapshot.buffers[index].savedText = source
            }
        }
        orderCrowmapPins(); crowmap.list(); refreshFiles(); schedulePersist()
        return destination
    }
    func duplicateCrowmap(_ url: URL) async throws -> URL {
        let store = try await prepareCrowmapFileAction(url, includingNotes: true), fm = FileManager.default
        let base = url.deletingPathExtension().lastPathComponent
        var title = base + " 2", number = 2
        while fm.fileExists(atPath: crowmap.root.appendingPathComponent(title).path) || fm.fileExists(atPath: crowmap.root.appendingPathComponent(title + ".crowmap").path) {
            number += 1; title = base + " \(number)"
        }
        try fm.createDirectory(at: crowmap.root, withIntermediateDirectories: true)
        let folder = crowmap.root.appendingPathComponent(title), staging = crowmap.root.appendingPathComponent(".duplicate-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let ownsFolder = crowmapOwnsFolder(url)
            for entry in try fm.contentsOfDirectory(at: store.noteRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) where entry.pathExtension != "crowmap" {
                if !ownsFolder {
                    if (try entry.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true { continue }
                    if entry.pathExtension == "md", entry.lastPathComponent.lowercased() != "agents.md", store.texts[entry.lastPathComponent] == nil { continue }
                }
                if entry.pathExtension == "md", entry.lastPathComponent.lowercased() != "agents.md" {
                    // Notes are real independent files even if an original uses a local symlink.
                    let original = try store.noteURL(entry.lastPathComponent)
                    try Data(contentsOf: original).write(to: staging.appendingPathComponent(entry.lastPathComponent), options: .withoutOverwriting)
                } else { try fm.copyItem(at: entry, to: staging.appendingPathComponent(entry.lastPathComponent)) }
            }
            var document = try JSONSerialization.jsonObject(with: Data(store.source.utf8)) as! [String: Any]
            document["id"] = UUID().uuidString; document["title"] = title
            try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]).write(to: staging.appendingPathComponent(title + ".crowmap"), options: .withoutOverwriting)
            try fm.moveItem(at: staging, to: folder)
        } catch { try? fm.removeItem(at: staging); throw error }
        crowmap.list(); return folder.appendingPathComponent(title + ".crowmap")
    }
    @discardableResult func deleteCrowmap(_ url: URL) async throws -> URL {
        _ = try await prepareCrowmapFileAction(url, includingNotes: true)
        let folder = url.deletingLastPathComponent(), ownsFolder = crowmapOwnsFolder(url), linked = crowmapIsLinkedFolder(url)
        let agents = crowmapAgents(in: folder)
        guard !agents.contains(where: { $0.state.terminals[$0.id]?.running == true }) else { throw CommandError("Close this map’s running agents before deleting it.") }
        let backup: URL
        if linked {
            backup = folder.resolvingSymlinksInPath()
            try FileManager.default.removeItem(at: folder)
        } else {
            let archive = crowmap.root.deletingLastPathComponent().appendingPathComponent("crowmap-deleted", isDirectory: true)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            backup = archive.appendingPathComponent(UUID().uuidString + "-" + (ownsFolder ? folder.lastPathComponent : url.lastPathComponent))
            try FileManager.default.moveItem(at: ownsFolder ? folder : url, to: backup)
        }
        let removed = crowmapTabs.filter { $0.url == url || ownsFolder && $0.store.noteRoot == folder }.map(\.id)
        crowmapTabs.removeAll { removed.contains($0.id) }; orderCrowmapPins()
        if removed.contains(crowmapPanel.selectedPath ?? "") { crowmapPanel.selectedPath = crowmapTabs.first?.id }
        crowmap.selected = crowmapPanel.selectedPath.map { URL(fileURLWithPath: $0) }
        if crowmapTabs.isEmpty { crowmapPanelFocused = false }
        let buffers = states.flatMap(\.snapshot.buffers).filter { !$0.isRemote && ($0.path == url.path || ownsFolder && $0.path.hasPrefix(folder.path + "/")) }.map(\.id)
        for id in buffers { closeBuffer(id) }
        for item in agents where ownsFolder || linked || item.agent.crowmapPath == url.path { closeTerminal(item.id) }
        crowmap.list(); refreshFiles(); schedulePersist(); return backup
    }
}
