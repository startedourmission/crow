import Foundation

/// Tokenizes one command without running a shell or expanding substitutions.
public struct SSHCommand: Equatable, Sendable {
    public let arguments: [String]
    public init(_ line: String) throws {
        var words: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for character in line {
            if escaped { word.append(character); escaped = false; started = true; continue }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { word.append(character) }
                continue
            }
            if character == "'" || character == "\"" { quote = character; started = true; continue }
            if character.isWhitespace {
                if started { words.append(word); word = ""; started = false }; continue
            }
            guard !";|&<>`$\0".contains(character) else { throw CommandError("Enter a single ssh command, without shell operators or substitutions.") }
            word.append(character); started = true
        }
        guard quote == nil, !escaped else { throw CommandError("Finish the quote or escape in the SSH command.") }
        if started { words.append(word) }
        guard words.first == "ssh" || words.first == "/usr/bin/ssh", words.count > 1 else {
            throw CommandError("Use ssh user@host, optionally with -p, -i or a config alias.")
        }
        arguments = Array(words.dropFirst())
    }

    /// Reject commands/modes that should remain terminal-only (tunnels, -G, etc.).
    public static func isInteractive(_ arguments: [String]) -> Bool {
        let valued = Set("BbcDEeFIiJLlmOopQRSWw"), flags = Set("46AaCfGgKkMNnqsTtVvXxYy")
        var destination = false, index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--" { index += 1; guard index == arguments.count - 1 else { return false }; return !arguments[index].isEmpty }
            if arg.hasPrefix("-"), arg != "-" {
                let chars = Array(arg.dropFirst())
                guard !chars.isEmpty else { return false }
                for (position, option) in chars.enumerated() {
                    if "fGMNOQSWVNTs".contains(option) { return false }
                    if valued.contains(option) {
                        if position == chars.count - 1 { index += 1; if index >= arguments.count { return false } }
                        break
                    }
                    if !flags.contains(option) { return false }
                }
            } else { if destination { return false }; destination = !arg.isEmpty }
            index += 1
        }
        return destination
    }

    public func portableHost(defaultUsername: String) throws -> (SSHHost, String?) {
        var user = defaultUsername, port = 22, identity: String?, target: String?, index = 0
        while index < arguments.count {
            let value = arguments[index]
            if value.hasPrefix("-") {
                guard value.count >= 2 else { throw CommandError("Missing SSH option.") }
                let option = String(value.prefix(2))
                guard ["-p", "-l", "-i"].contains(option) else {
                    throw CommandError("On iPhone/iPad use ssh user@host with -p, -l or -i. Mac also supports OpenSSH config and options.")
                }
                let parameter: String
                if value.count > 2 { parameter = String(value.dropFirst(2)) }
                else { index += 1; guard index < arguments.count else { throw CommandError("Missing value for \(option).") }; parameter = arguments[index] }
                switch option {
                case "-p": guard let number = Int(parameter), (1...65535).contains(number) else { throw CommandError("Invalid SSH port.") }; port = number
                case "-l": user = parameter
                default: identity = parameter
                }
            } else {
                guard target == nil else { throw CommandError("Remote commands are terminal-only; enter just the connection command here.") }
                target = value
            }
            index += 1
        }
        guard var hostname = target else { throw CommandError("Missing SSH host.") }
        if let at = hostname.lastIndex(of: "@") { user = String(hostname[..<at]); hostname = String(hostname[hostname.index(after: at)...]) }
        if hostname.hasPrefix("["), hostname.hasSuffix("]") { hostname = String(hostname.dropFirst().dropLast()) }
        guard !hostname.isEmpty, !user.isEmpty else { throw CommandError("Use ssh user@host.") }
        return (SSHHost(name: target!, hostname: hostname, port: port, username: user), identity)
    }

    /// Resolve home in the remote shell, independently of SFTP's initial directory.
    public static func remoteDirectoryCommand(_ path: String) -> String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if path.isEmpty || path == "~" { return "cd -- \"$HOME\"" }
        if path.hasPrefix("~/") { return "cd -- \"$HOME\"/" + quote(String(path.dropFirst(2))) }
        return "cd -- " + quote(path)
    }

    /// Session-only bash/zsh prompt hook. Reports cwd through OSC 7 without polling
    /// or writing commands into a terminal that may be running an editor or agent.
    public static var directoryTrackingCommand: String {
        let script = ##"""
        _crow_cwd(){ local x=$? p="$PWD";
        p=${p//\%/%25}; p=${p// /%20}; p=${p//\#/%23}; p=${p//\?/%3F};
        p=${p//$'\n'/%0A}; p=${p//$'\r'/%0D}; p=${p//$'\t'/%09}; p=${p//$'\e'/%1B}; p=${p//$'\a'/%07};
        printf '\e]7;file://localhost%s\a' "$p"; return "$x"; };
        if [ -n "${ZSH_VERSION-}" ]; then typeset -ga precmd_functions; precmd_functions=(_crow_cwd "${precmd_functions[@]}");
        else case "$(declare -p PROMPT_COMMAND 2>/dev/null)" in
        'declare -a'*) PROMPT_COMMAND=(_crow_cwd "${PROMPT_COMMAND[@]}");;
        *) PROMPT_COMMAND="_crow_cwd${PROMPT_COMMAND:+; $PROMPT_COMMAND}";; esac; fi; _crow_cwd
        """##.replacingOccurrences(of: "\n", with: " ")
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "if [ -n \"${BASH_VERSION-}${ZSH_VERSION-}\" ]; then eval " + quoted + "; fi"
    }

    public static func terminalDirectory(_ report: String?) -> String? {
        guard let report, report.hasPrefix("file://") else { return nil }
        let parts = report.dropFirst(7).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let authority = URLComponents(string: "file://" + parts[0] + "/"),
              authority.user == nil, authority.password == nil, authority.query == nil, authority.fragment == nil,
              !parts[1].contains("?"), !parts[1].contains("#"),
              let path = ("/" + parts[1]).removingPercentEncoding, !path.contains("\0") else { return nil }
        // Decode once. URL(string:) re-escapes existing percent sequences when a
        // report also contains raw Unicode (common in bash/zsh OSC 7 hooks).
        return path
    }
}

public struct CommandError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
