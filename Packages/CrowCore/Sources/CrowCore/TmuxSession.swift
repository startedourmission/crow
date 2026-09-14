import Foundation

public struct TmuxSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let windows: Int
    public let clients: Int
    public var windowList: [TmuxWindow] = []
}

public struct TmuxWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let index: Int
    public let name: String
    public let isActive: Bool
    public var panes: [TmuxPane] = []
}

public struct TmuxPane: Identifiable, Equatable, Sendable {
    public let id: String
    public let index: Int
    public let command: String
    public let isActive: Bool
}

public struct TmuxLocation: Equatable, Sendable {
    public let sessionID: String
    public let windowID: String?
    public let paneID: String?
    public init(sessionID: String, windowID: String? = nil, paneID: String? = nil) {
        self.sessionID = sessionID; self.windowID = windowID; self.paneID = paneID
    }
}

public enum TmuxCommand {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    private static let prefix = TerminalCommand.environment + TerminalCommand.utf8Environment + "unset TMUX; command -v tmux >/dev/null 2>&1 || { printf '%s\\n' 'tmux is not installed on this host.' >&2; exit 127; }; "
    // Non-UTF-8 tmux clients sanitize tabs to underscores. Use printable separators
    // and force UTF-8 so both field boundaries and non-ASCII names survive SSH.
    private static let format = "CROW_TMUX|#{session_id}|#{session_windows}|#{session_attached}|#{session_name}"
    private static let windowFormat = "CROW_WINDOW|#{session_id}|#{window_id}|#{window_index}|#{window_active}|#{window_name}"
    private static let paneFormat = "CROW_PANE|#{session_id}|#{window_id}|#{pane_id}|#{pane_index}|#{pane_active}|#{pane_current_command}"
    public static let list = prefix + """
    if crow_tmux_result=$(LC_ALL=C tmux -u list-sessions -F \(TerminalCommand.quote(format)) 2>&1); then
      printf '%s\\n' CROW_TMUX_BEGIN "$crow_tmux_result"
      LC_ALL=C tmux -u list-windows -a -F \(TerminalCommand.quote(windowFormat)) || exit $?
      LC_ALL=C tmux -u list-panes -a -F \(TerminalCommand.quote(paneFormat)) || exit $?
      printf '%s\\n' CROW_TMUX_END
    else
      case "$crow_tmux_result" in
        'no server running on '*|'error connecting to '*' (No such file or directory)') printf '%s\\n' CROW_TMUX_BEGIN CROW_TMUX_END ;;
        *) printf '%s\\n' "$crow_tmux_result" >&2; exit 1 ;;
      esac
    fi
    """

    public static func parse(_ output: String) throws -> [TmuxSession] {
        let lines = output.components(separatedBy: .newlines)
        guard let begin = lines.firstIndex(of: "CROW_TMUX_BEGIN"),
              let end = lines[(begin + 1)...].firstIndex(of: "CROW_TMUX_END") else {
            throw Failure("Could not read tmux’s session list. The server returned an incomplete response.")
        }
        var sessions: [TmuxSession] = []
        var windows: [(session: String, value: TmuxWindow)] = []
        var panes: [(session: String, window: String, value: TmuxPane)] = []
        for line in lines[(begin + 1)..<end] where !line.isEmpty {
            let kind = line.prefix(while: { $0 != "|" })
            let limit = kind == "CROW_TMUX" ? 4 : kind == "CROW_WINDOW" ? 5 : 6
            let f = line.split(separator: "|", maxSplits: limit, omittingEmptySubsequences: false).map(String.init)
            switch kind {
            case "CROW_TMUX":
                guard f.count == 5, validID(f[1]), let count = Int(f[2]), count >= 0,
                      let clients = Int(f[3]), clients >= 0 else { throw malformed(line) }
                sessions.append(TmuxSession(id: f[1], name: f[4], windows: count, clients: clients))
            case "CROW_WINDOW":
                guard f.count == 6, validID(f[1]), validID(f[2], prefix: "@"), let index = Int(f[3]),
                      index >= 0, ["0", "1"].contains(f[4]) else { throw malformed(line) }
                windows.append((f[1], TmuxWindow(id: f[2], index: index, name: f[5], isActive: f[4] == "1")))
            case "CROW_PANE":
                guard f.count == 7, validID(f[1]), validID(f[2], prefix: "@"), validID(f[3], prefix: "%"),
                      let index = Int(f[4]), index >= 0, ["0", "1"].contains(f[5]) else { throw malformed(line) }
                panes.append((f[1], f[2], TmuxPane(id: f[3], index: index, command: f[6], isActive: f[5] == "1")))
            default: throw malformed(line)
            }
        }
        for i in sessions.indices {
            let sessionID = sessions[i].id
            sessions[i].windowList = windows.filter { $0.session == sessionID }.map { row in
                var window = row.value
                let windowID = window.id
                window.panes = panes.filter { $0.session == row.session && $0.window == windowID }.map(\.value).sorted { $0.index < $1.index }
                return window
            }.sorted { $0.index < $1.index }
        }
        return sessions
    }
    private static func malformed(_ line: String) -> Failure { Failure("Could not read tmux’s session list: " + String(line.prefix(160))) }
    public static func create(name: String, directory: String) throws -> String {
        try validateName(name)
        // Inherit cwd rather than passing a path through tmux's format expansion.
        return prefix + "cd " + TerminalCommand.path(directory) + " && tmux -u new-session -d -s " + TerminalCommand.quote(name)
            + " -e LANG=\"${LANG-}\" -e LC_CTYPE=\"${LC_CTYPE-${LANG-}}\" -e LC_ALL=\"${LC_ALL-}\""
    }
    public enum SplitDirection: Sendable { case sideBySide, stacked }
    private static let createdFormat = "CROW_CREATED|#{session_id}|#{window_id}|#{pane_id}"
    private static let localeArguments = " -e LANG=\"${LANG-}\" -e LC_CTYPE=\"${LC_CTYPE-${LANG-}}\" -e LC_ALL=\"${LC_ALL-}\""

    public static func newWindow(sessionID: String) throws -> String {
        _ = try target(sessionID)
        return prefix + "tmux -u new-window -d -P -F " + TerminalCommand.quote(createdFormat)
            + " -c '#{pane_current_path}' -t " + TerminalCommand.quote(sessionID + ":") + localeArguments
    }
    public static func splitPane(_ location: TmuxLocation, direction: SplitDirection) throws -> String {
        guard validID(location.sessionID), let window = location.windowID, validID(window, prefix: "@"),
              let pane = location.paneID, validID(pane, prefix: "%") else { throw Failure("Select a pane to split.") }
        return prefix + "tmux -u split-window -d " + (direction == .sideBySide ? "-h" : "-v")
            + " -P -F " + TerminalCommand.quote(createdFormat) + " -c '#{pane_current_path}' -t "
            + TerminalCommand.quote(location.sessionID + ":" + window + "." + pane) + localeArguments
    }
    public static func parseCreated(_ output: String, sessionID: String) throws -> TmuxLocation {
        let records = output.components(separatedBy: .newlines).filter { $0.hasPrefix("CROW_CREATED|") }
        guard records.count == 1 else { throw Failure("Could not identify the new tmux window or pane. Refresh the session list.") }
        let fields = records[0].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, fields[1] == sessionID, validID(fields[1]),
              validID(fields[2], prefix: "@"), validID(fields[3], prefix: "%") else {
            throw Failure("Could not identify the new tmux window or pane. Refresh the session list.")
        }
        return .init(sessionID: fields[1], windowID: fields[2], paneID: fields[3])
    }

    public static func rename(id: String, name: String) throws -> String {
        try validateName(name)
        return prefix + "tmux rename-session -t " + (try target(id)) + " -- " + TerminalCommand.quote(name)
    }
    public static func kill(id: String) throws -> String { prefix + "tmux kill-session -t " + (try target(id)) }
    public static func attach(id: String) throws -> String { try attach(.init(sessionID: id)) }
    public static func attach(_ location: TmuxLocation) throws -> String {
        let commands = try selectionCommands(location) + ["exec tmux -u attach-session -t " + target(location.sessionID)]
        return prefix + commands.joined(separator: " && ")
    }
    public static func select(_ location: TmuxLocation) throws -> String {
        let commands = try ["tmux has-session -t " + target(location.sessionID)] + selectionCommands(location)
        return prefix + commands.joined(separator: " && ")
    }
    private static func selectionCommands(_ location: TmuxLocation) throws -> [String] {
        _ = try target(location.sessionID)
        var commands: [String] = []
        if let windowID = location.windowID {
            commands.append("tmux select-window -t " + (try windowTarget(sessionID: location.sessionID, windowID: windowID)))
        }
        if let paneID = location.paneID {
            guard location.windowID != nil else { throw Failure("Select a window before selecting a pane.") }
            commands.append("tmux select-pane -t " + (try target(paneID, prefix: "%")))
        }
        return commands
    }
    public static func killWindow(sessionID: String, windowID: String) throws -> String {
        prefix + "tmux kill-window -t " + (try windowTarget(sessionID: sessionID, windowID: windowID))
    }
    public static func killPane(id: String) throws -> String { prefix + "tmux kill-pane -t " + (try target(id, prefix: "%")) }
    private static func windowTarget(sessionID: String, windowID: String) throws -> String {
        guard validID(sessionID), validID(windowID, prefix: "@") else { throw Failure("Invalid tmux window ID.") }
        return TerminalCommand.quote(sessionID + ":" + windowID)
    }
    private static func target(_ id: String, prefix: Character = "$") throws -> String {
        guard validID(id, prefix: prefix) else { throw Failure("Invalid tmux session ID.") }
        return TerminalCommand.quote(id)
    }
    private static func validID(_ id: String, prefix: Character = "$") -> Bool {
        id.first == prefix && id.count > 1 && id.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 128,
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_- ".unicodeScalars.contains($0) }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Failure("Use letters, numbers, spaces, underscores or hyphens for the session name.")
        }
    }
}
