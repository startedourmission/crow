import Foundation

public enum WorkspaceTab: Hashable, Codable, Sendable {
    case file(BufferID)
    case terminal(UUID)
    case start(UUID)
    public var key: String {
        switch self {
        case .file(let id): return "file-\(id.rawValue)"
        case .terminal(let id): return "terminal-\(id)"
        case .start(let id): return "start-\(id)"
        }
    }
}

public struct WorkspacePane: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var tabs: [WorkspaceTab]
    public var selected: WorkspaceTab?
    public init(tabs: [WorkspaceTab], selected: WorkspaceTab? = nil) {
        id = UUID(); self.tabs = tabs
        self.selected = selected.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first
    }
}

public enum PaneAxis: String, Codable, Sendable { case horizontal, vertical }
public enum PanePlacement: String, Sendable { case center, left, right, top, bottom }

public indirect enum PaneNode: Codable, Equatable, Sendable {
    case pane(UUID)
    case split(id: UUID, axis: PaneAxis, fraction: Double, first: PaneNode, second: PaneNode)

    public var id: UUID {
        switch self { case .pane(let id), .split(let id, _, _, _, _): return id }
    }
    public var paneIDs: [UUID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, _, let first, let second): return first.paneIDs + second.paneIDs
        }
    }
    public func retaining(_ ids: Set<UUID>) -> PaneNode? {
        switch self {
        case .pane(let id): return ids.contains(id) ? self : nil
        case .split(let id, let axis, let fraction, let first, let second):
            let a = first.retaining(ids), b = second.retaining(ids)
            if let a, let b { return .split(id: id, axis: axis, fraction: fraction, first: a, second: b) }
            return a ?? b
        }
    }
    public func replacing(_ id: UUID, with replacement: PaneNode) -> PaneNode {
        if self.id == id { return replacement }
        switch self {
        case .pane: return self
        case .split(let splitID, let axis, let fraction, let a, let b):
            return .split(id: splitID, axis: axis, fraction: fraction,
                first: a.replacing(id, with: replacement), second: b.replacing(id, with: replacement))
        }
    }
    public func resizing(_ id: UUID, fraction: Double) -> PaneNode {
        switch self {
        case .pane: return self
        case .split(let splitID, let axis, let old, let a, let b):
            return .split(id: splitID, axis: axis, fraction: splitID == id ? min(0.9, max(0.1, fraction)) : old,
                first: a.resizing(id, fraction: fraction), second: b.resizing(id, fraction: fraction))
        }
    }
}

public struct WorkspaceLayout: Codable, Equatable, Sendable {
    public var panes: [WorkspacePane]
    public var root: PaneNode?
    public var activePaneID: UUID?

    public init(files: [BufferID], selectedFile: BufferID?, terminals: [UUID], selectedTerminal: UUID?, terminalFraction: Double = 0.34) {
        panes = []
        if !files.isEmpty { panes.append(.init(tabs: files.map(WorkspaceTab.file), selected: selectedFile.map(WorkspaceTab.file))) }
        if !terminals.isEmpty { panes.append(.init(tabs: terminals.map(WorkspaceTab.terminal), selected: selectedTerminal.map(WorkspaceTab.terminal))) }
        activePaneID = panes.first?.id
        if panes.count == 2 {
            root = .split(id: UUID(), axis: .vertical, fraction: 1 - terminalFraction,
                first: .pane(panes[0].id), second: .pane(panes[1].id))
        } else { root = panes.first.map { .pane($0.id) } }
    }
    public var allTabs: [WorkspaceTab] { panes.flatMap(\.tabs) }
    public var activePane: WorkspacePane? { panes.first { $0.id == activePaneID } ?? panes.first }

    public mutating func select(_ tab: WorkspaceTab, in paneID: UUID? = nil) {
        guard let index = panes.firstIndex(where: { (paneID == nil || $0.id == paneID) && $0.tabs.contains(tab) }) else { return }
        panes[index].selected = tab; activePaneID = panes[index].id
    }
    public mutating func open(_ tab: WorkspaceTab, in paneID: UUID? = nil) {
        if allTabs.contains(tab) {
            let target = panes.first { $0.id == (paneID ?? activePaneID) && $0.tabs.contains(tab) }
                ?? panes.first { $0.tabs.contains(tab) }
            select(tab, in: target?.id); return
        }
        if let index = panes.firstIndex(where: { $0.id == (paneID ?? activePaneID) }) {
            if case .start = tab {
                panes[index].tabs.append(tab)
            } else if let selected = panes[index].selected, case .start = selected,
                      let position = panes[index].tabs.firstIndex(of: selected) {
                panes[index].tabs[position] = tab
            } else { panes[index].tabs.append(tab) }
            panes[index].selected = tab; activePaneID = panes[index].id
        } else {
            let pane = WorkspacePane(tabs: [tab]); panes.append(pane); activePaneID = pane.id
            if let root { self.root = .split(id: UUID(), axis: .horizontal, fraction: 0.5, first: root, second: .pane(pane.id)) }
            else { root = .pane(pane.id) }
        }
    }
    public mutating func remove(_ tab: WorkspaceTab, from paneID: UUID? = nil) {
        for index in panes.indices where paneID == nil || panes[index].id == paneID {
            panes[index].tabs.removeAll { $0 == tab }
            if panes[index].selected == tab { panes[index].selected = panes[index].tabs.last }
        }
        prune()
    }
    public mutating func prune() {
        panes.removeAll { $0.tabs.isEmpty }
        root = root?.retaining(Set(panes.map(\.id)))
        if !panes.contains(where: { $0.id == activePaneID }) { activePaneID = panes.first?.id }
    }
    @discardableResult public mutating func move(_ tab: WorkspaceTab, from sourceID: UUID, to targetID: UUID,
        placement: PanePlacement = .center, before: WorkspaceTab? = nil, copy: Bool = false) -> Bool {
        guard let source = panes.first(where: { $0.id == sourceID }), source.tabs.contains(tab),
              panes.contains(where: { $0.id == targetID }) else { return false }
        if copy, case .terminal = tab { return false } // A PTY view can only have one owner.
        if sourceID == targetID && placement != .center && source.tabs.count == 1 && !copy { return false }
        if placement == .center && sourceID == targetID && before == tab { return true }
        if !copy {
            let index = panes.firstIndex { $0.id == sourceID }!
            panes[index].tabs.removeAll { $0 == tab }
            if panes[index].selected == tab { panes[index].selected = panes[index].tabs.last }
        }
        if placement == .center {
            let index = panes.firstIndex { $0.id == targetID }!
            panes[index].tabs.removeAll { $0 == tab }
            let insertion = before.flatMap { panes[index].tabs.firstIndex(of: $0) } ?? panes[index].tabs.count
            panes[index].tabs.insert(tab, at: insertion); panes[index].selected = tab; activePaneID = targetID
        } else {
            let pane = WorkspacePane(tabs: [tab]); panes.append(pane); activePaneID = pane.id
            let leading = placement == .left || placement == .top
            let axis: PaneAxis = placement == .left || placement == .right ? .horizontal : .vertical
            root = root?.replacing(targetID, with: .split(id: UUID(), axis: axis, fraction: 0.5,
                first: .pane(leading ? pane.id : targetID), second: .pane(leading ? targetID : pane.id)))
        }
        prune(); return true
    }
}
