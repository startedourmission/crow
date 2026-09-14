import Foundation

public struct HostID: Hashable, Codable, Sendable, RawRepresentable {
    public var rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct WorkspaceID: Hashable, Codable, Sendable, RawRepresentable {
    public var rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct BufferID: Hashable, Codable, Sendable, RawRepresentable {
    public var rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct SSHHost: Identifiable, Hashable, Codable, Sendable {
    public var id: HostID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var remotePath: String
    public var usesWSL = false
    public var authentication: SSHAuthenticationKind = .password
    public var commandArguments: [String]?
    public var commandDirectory: String?
    public var lastConnectedAt: Date?

    public init(
        id: HostID = HostID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        remotePath: String = "~"
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.remotePath = remotePath
    }

    public var userAtHost: String {
        "\(username)@\(hostname)"
    }

    /// WSL default-shell hosts retain the existing project-directory workaround.
    public func terminalStartPath(projectPath: String) -> String {
        usesWSL ? projectPath : (remotePath.isEmpty ? "~" : remotePath)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, username, remotePath, usesWSL
        case authentication, commandArguments, commandDirectory, lastConnectedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(HostID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        hostname = try values.decode(String.self, forKey: .hostname)
        port = try values.decode(Int.self, forKey: .port)
        username = try values.decode(String.self, forKey: .username)
        remotePath = try values.decode(String.self, forKey: .remotePath)
        usesWSL = try values.decodeIfPresent(Bool.self, forKey: .usesWSL) ?? false
        authentication = try values.decodeIfPresent(SSHAuthenticationKind.self, forKey: .authentication) ?? .password
        commandArguments = try values.decodeIfPresent([String].self, forKey: .commandArguments)
        commandDirectory = try values.decodeIfPresent(String.self, forKey: .commandDirectory)
        lastConnectedAt = try values.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }
}

public enum WorkspaceKind: Hashable, Codable, Sendable {
    case local
    case imeLab // Decode legacy sessions only; never create this workspace in the app.
    case remote(hostID: HostID, path: String)
}

public enum ConnectionState: Hashable, Codable, Sendable {
    case local
    case disconnected
    case connecting
    case connected
    case failed(String)
}

public struct Workspace: Identifiable, Hashable, Codable, Sendable {
    public var id: WorkspaceID
    public var name: String
    public var kind: WorkspaceKind
    public var connection: ConnectionState

    public init(
        id: WorkspaceID = WorkspaceID(),
        name: String,
        kind: WorkspaceKind,
        connection: ConnectionState
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.connection = connection
    }

    public var hostID: HostID? {
        if case .remote(let hostID, _) = kind { return hostID }; return nil
    }

    public var isRemote: Bool {
        if case .remote = kind { return true }
        return false
    }
}

public enum LanguageMode: String, Hashable, Codable, Sendable {
    case plain
    case markdown
    case json
    case yaml
    case toml
    case xml
    case html
    case shell
    case python
    case javascript
    case typescript
    case go
    case rust
    case c
    case swift
    case ruby
    case ini

    public static func infer(filename: String) -> LanguageMode {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return .markdown
        case "json", "canvas": return .json
        case "yml", "yaml", "base": return .yaml
        case "toml": return .toml
        case "xml": return .xml
        case "html", "htm": return .html
        case "sh", "bash", "zsh", "fish": return .shell
        case "py": return .python
        case "js", "mjs", "cjs": return .javascript
        case "ts", "tsx": return .typescript
        case "go": return .go
        case "rs": return .rust
        case "c", "h", "cc", "cpp", "hpp": return .c
        case "swift": return .swift
        case "rb": return .ruby
        case "ini", "conf", "cfg", "env": return .ini
        case "txt", "log", "text": return .plain
        default: return .plain
        }
    }

    public var usesMonospace: Bool {
        self != .markdown && self != .plain
    }

    public var label: String {
        switch self {
        case .plain: return "Plain"
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .xml: return "XML"
        case .html: return "HTML"
        case .shell: return "Shell"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .go: return "Go"
        case .rust: return "Rust"
        case .c: return "C"
        case .swift: return "Swift"
        case .ruby: return "Ruby"
        case .ini: return "Config"
        }
    }
}

public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var isHidden: Bool

    public init(name: String, path: String, isDirectory: Bool, isHidden: Bool? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isHidden = isHidden ?? name.hasPrefix(".")
    }
}

public struct OpenBuffer: Identifiable, Hashable, Codable, Sendable {
    public enum ContentKind: String, Codable, Sendable { case text, image }
    // Optional for sessions saved before image previews were supported.
    public var contentKind: ContentKind? = nil
    public var isImage: Bool { contentKind == .image }
    public var id: BufferID
    public var title: String
    public var path: String
    public var text: String
    public var language: LanguageMode
    public var isRemote: Bool
    public var isDirty: Bool
    public var savedText: String? = nil

    public init(
        id: BufferID = BufferID(),
        title: String,
        path: String,
        text: String,
        language: LanguageMode,
        isRemote: Bool,
        isDirty: Bool = false
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.text = text
        self.language = language
        self.isRemote = isRemote
        self.isDirty = isDirty
    }
}

public struct IMEProbe: Equatable, Sendable {
    public var lastUTF8: String
    public var lastHex: String
    public var lastByteCount: Int
    public var containedBackspace: Bool
    public var containedIsolatedJamo: Bool
    public var columns: Int

    public static let empty = IMEProbe(
        lastUTF8: "",
        lastHex: "",
        lastByteCount: 0,
        containedBackspace: false,
        containedIsolatedJamo: false,
        columns: 0
    )

    public init(
        lastUTF8: String,
        lastHex: String,
        lastByteCount: Int,
        containedBackspace: Bool,
        containedIsolatedJamo: Bool,
        columns: Int
    ) {
        self.lastUTF8 = lastUTF8
        self.lastHex = lastHex
        self.lastByteCount = lastByteCount
        self.containedBackspace = containedBackspace
        self.containedIsolatedJamo = containedIsolatedJamo
        self.columns = columns
    }

    public static func from(bytes: ArraySlice<UInt8>) -> IMEProbe {
        let array = Array(bytes)
        let text = String(bytes: array, encoding: .utf8) ?? ""
        let hex = array.map { String(format: "%02x", $0) }.joined(separator: " ")
        return IMEProbe(
            lastUTF8: text,
            lastHex: hex,
            lastByteCount: array.count,
            containedBackspace: array.contains(0x08) || array.contains(0x7f),
            containedIsolatedJamo: HangulIME.encodesAsIsolatedJamo(text),
            columns: EastAsianWidth.columns(in: text)
        )
    }

    public var isHealthyCommit: Bool {
        !containedIsolatedJamo || lastUTF8.isEmpty
    }
}

public enum SidebarPane: String, Hashable, Codable, Sendable, CaseIterable {
    case files
    case workspaces
    case automation

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "files": self = .files
        case "automation": self = .automation
        case "workspaces", "hosts", "agents", "tmux": self = .workspaces
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown sidebar pane")
        }
    }
}

public enum CompactSurface: String, Hashable, Codable, Sendable, CaseIterable {
    case hosts
    case editor
    case terminal
    case files
}
