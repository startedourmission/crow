import Foundation

public enum SSHAuthenticationKind: String, Codable, CaseIterable, Sendable {
    case password, ed25519, rsa
}

public struct WorkspaceSnapshot: Codable, Sendable {
    public var workspace: Workspace
    public var rootPath: String
    public var directoryPath: String
    public var bookmark: Data?
    public var buffers: [OpenBuffer]
    public var selectedBufferID: BufferID?
    public var splitBufferID: BufferID?
    public var terminalIDs: [UUID]
    public var selectedTerminalID: UUID?
    public var terminalSplit = false
    public var layout: WorkspaceLayout?

    public init(workspace: Workspace, rootPath: String, bookmark: Data? = nil) {
        self.workspace = workspace
        self.rootPath = rootPath
        directoryPath = rootPath
        self.bookmark = bookmark
        buffers = []
        terminalIDs = [UUID()]
        selectedTerminalID = terminalIDs.first
    }

    public mutating func relocateRoot(to newRoot: String) {
        let oldRoot = rootPath
        guard oldRoot != newRoot else { return }
        func relocated(_ path: String) -> String {
            if path == oldRoot { return newRoot }
            if path.hasPrefix(oldRoot + "/") { return newRoot + path.dropFirst(oldRoot.count) }
            return path
        }
        directoryPath = relocated(directoryPath)
        for index in buffers.indices { buffers[index].path = relocated(buffers[index].path) }
        rootPath = newRoot
    }

    private enum CodingKeys: String, CodingKey {
        case workspace, rootPath, directoryPath, bookmark, buffers, selectedBufferID, splitBufferID
        case terminalIDs, selectedTerminalID, terminalSplit
        case layout
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try values.decode(Workspace.self, forKey: .workspace)
        rootPath = try values.decode(String.self, forKey: .rootPath)
        directoryPath = try values.decodeIfPresent(String.self, forKey: .directoryPath) ?? rootPath
        bookmark = try values.decodeIfPresent(Data.self, forKey: .bookmark)
        buffers = try values.decodeIfPresent([OpenBuffer].self, forKey: .buffers) ?? []
        selectedBufferID = try values.decodeIfPresent(BufferID.self, forKey: .selectedBufferID)
        splitBufferID = try values.decodeIfPresent(BufferID.self, forKey: .splitBufferID)
        terminalIDs = try values.decodeIfPresent([UUID].self, forKey: .terminalIDs) ?? [UUID()]
        selectedTerminalID = try values.decodeIfPresent(UUID.self, forKey: .selectedTerminalID) ?? terminalIDs.first
        terminalSplit = try values.decodeIfPresent(Bool.self, forKey: .terminalSplit) ?? false
        layout = try values.decodeIfPresent(WorkspaceLayout.self, forKey: .layout)
    }
}

public struct EditorSettings: Codable, Equatable, Sendable {
    public var fontSize: Double = 16
    public var terminalFontSize: Double = 16
    public var indentWidth: Int = 4
    public var lineNumbers = true
    public var terminalFraction: Double = 0.34
    public var sidebarVisible = true
    public var terminalVisible = true
    public init() {}
}

public struct SessionSnapshot: Codable, Sendable {
    public var version = 1
    public var hosts: [SSHHost]
    public var workspaces: [WorkspaceSnapshot]
    public var selectedWorkspaceID: WorkspaceID
    public var settings: EditorSettings

    public init(hosts: [SSHHost], workspaces: [WorkspaceSnapshot], selectedWorkspaceID: WorkspaceID,
                settings: EditorSettings) {
        self.hosts = hosts
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID
        self.settings = settings
    }
}

public enum FileFailure: LocalizedError {
    case invalidName, unsupportedText, tooLarge, conflict, disconnected
    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Use a nonempty name without /, : or a newline."
        case .unsupportedText: return "This file is not UTF-8 text. It has not been opened or changed."
        case .tooLarge: return "This file exceeds the 16 MB text editing limit."
        case .conflict: return "The file changed on disk or on the server since it was opened."
        case .disconnected: return "Connect to this host before accessing its files."
        }
    }
}

public enum TextFiles {
    public static let sizeLimit = 16 * 1024 * 1024

    public static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..",
              !name.contains(where: { "/:\n\r\0".contains($0) }) else { throw FileFailure.invalidName }
    }

    public static func decode(_ data: Data) throws -> String {
        guard data.count <= sizeLimit else { throw FileFailure.tooLarge }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw FileFailure.unsupportedText
        }
        return text
    }

    public static func read(_ url: URL, maximumSize: Int = sizeLimit) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumSize else { throw FileFailure.tooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while let chunk = try file.read(upToCount: min(65_536, maximumSize - data.count + 1)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumSize else { throw FileFailure.tooLarge }
        }
        return try decode(data)
    }

    public static func write(_ text: String, to url: URL, expected: String?, overwrite: Bool = false) throws {
        if !overwrite, let expected, try read(url) != expected { throw FileFailure.conflict }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    public static func saveSession(_ session: SessionSnapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
