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
        if [ -n "${ZSH_VERSION-}" ]; then typeset -ga precmd_functions; precmd_functions=(_crow_cwd "${(@)precmd_functions:#_crow_cwd}");
        else case "$(declare -p PROMPT_COMMAND 2>/dev/null)" in
        'declare -a'*) PROMPT_COMMAND=(_crow_cwd "${PROMPT_COMMAND[@]}");;
        *) PROMPT_COMMAND="_crow_cwd${PROMPT_COMMAND:+; $PROMPT_COMMAND}";; esac; fi; _crow_cwd
        """##.replacingOccurrences(of: "\n", with: " ")
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "if [ -n \"${BASH_VERSION-}${ZSH_VERSION-}\" ]; then eval " + quoted + "; fi"
    }

    /// Install tracking after the user's startup files, without changing those files
    /// or sending setup commands through an authentication prompt.
    public static func interactiveShellCommand(directory: String) -> String {
        let hook = directoryTrackingCommand
        let zshFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"].map { file in
            let tracking = [".zshrc", ".zlogin"].contains(file) ? hook : ""
            return """
            cat > "$crow_init/\(file)" <<'CROW_SHELL_RC'
            export ZDOTDIR="$CROW_USER_ZDOTDIR"
            [[ -r "$ZDOTDIR/\(file)" ]] && source "$ZDOTDIR/\(file)"
            CROW_USER_ZDOTDIR="${ZDOTDIR:-$HOME}"
            \(tracking)
            export ZDOTDIR="$CROW_SHELL_INIT"
            CROW_SHELL_RC
            """
        }.joined(separator: "\n")
        return """
        \(remoteDirectoryCommand(directory)) || exit
        crow_shell=${SHELL:-/bin/sh}
        case "$crow_shell" in
        */zsh|*/bash) ;;
        *) exec "$crow_shell" -l ;;
        esac
        crow_init=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/crow-shell.XXXXXXXX") || exit
        trap 'rm -rf -- "$crow_init"' EXIT
        export CROW_SHELL_INIT="$crow_init" CROW_USER_ZDOTDIR="${ZDOTDIR:-$HOME}"
        case "$crow_shell" in
        */zsh)
        \(zshFiles)
        ZDOTDIR="$crow_init" "$crow_shell" -il
        ;;
        */bash)
        cat > "$crow_init/bashrc" <<'CROW_SHELL_RC'
        [ -r /etc/profile ] && . /etc/profile
        if [ -r "$HOME/.bash_profile" ]; then . "$HOME/.bash_profile"
        elif [ -r "$HOME/.bash_login" ]; then . "$HOME/.bash_login"
        elif [ -r "$HOME/.profile" ]; then . "$HOME/.profile"
        elif [ -r "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
        \(hook)
        CROW_SHELL_RC
        "$crow_shell" --rcfile "$crow_init/bashrc" -i
        ;;
        esac
        crow_status=$?
        exit "$crow_status"
        """
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

/// Hide the PTY's echo and continuation prompts while it reads Crow's startup
/// group. The marker executes only after the complete group has been parsed;
/// everything after it (including setup errors and OSC directory reports) stays visible.
///
/// `command(_:)` types the whole group ahead in one write. On macOS, bash 3.2's
/// readline toggles canonical mode after every line, and XNU corrupts more than
/// about 1 KB of pending type-ahead when that happens, so interactive sessions type
/// `readinessProbe` first and send `script(_:)` only after `isShellReady`.
public struct SSHStartupOutput: Sendable {
    let token: String
    private let marker: Data
    private let readyMarker: Data
    private let lineReadyMarker: Data
    private var pending = Data()
    public private(set) var isReady = false
    /// The shell executed `readinessProbe` and is waiting for `script(_:)`.
    public private(set) var isShellReady = false
    /// bash/zsh read the whole script with one `read`; other shells read it line by line.
    public private(set) var shellReadsScript = false

    public init() {
        token = UUID().uuidString
        marker = Data("\u{1b}]1337;CrowStartup=\(token)\u{7}".utf8)
        readyMarker = Data("\u{1b}]1337;CrowReady=\(token)\u{7}".utf8)
        lineReadyMarker = Data("\u{1b}]1337;CrowReadyLine=\(token)\u{7}".utf8)
    }

    public func command(_ setup: String) -> String {
        "{\nprintf '\\033]1337;CrowStartup=%s\\007' " + TerminalCommand.quote(token)
            + "\n" + setup + "\n}\n"
    }

    /// One short line, run by the shell only once it reads commands. bash/zsh report
    /// readiness and then read the startup group in a single unechoed, non-canonical
    /// `read`, so no line editor toggles the terminal mode while it is pending. The
    /// echoed text of this line cannot match a marker: the escape bytes exist only in
    /// printf's output.
    public var readinessProbe: String {
        let token = TerminalCommand.quote(token)
        return "case \"${BASH_VERSION-}${ZSH_VERSION-}\" in '') printf '\\033]1337;CrowReadyLine=%s\\007' " + token
            + ";; *) printf '\\033]1337;CrowReady=%s\\007' " + token
            + "; IFS= read -r -s -d \"$(printf '\\037')\" crow_startup; eval \"$crow_startup\"; unset crow_startup;; esac"
    }

    /// The startup group to send once `isShellReady`; for bash/zsh it ends with the
    /// probe's `read` delimiter (US).
    public func script(_ setup: String) -> String {
        command(setup) + (shellReadsScript ? "\u{1f}" : "")
    }

    public mutating func receive(_ bytes: [UInt8]) -> [UInt8] {
        guard !isReady else { return bytes }
        pending.append(contentsOf: bytes)
        if !isShellReady {
            let reads = pending.range(of: readyMarker), lines = pending.range(of: lineReadyMarker)
            if let range = reads ?? lines {
                isShellReady = true; shellReadsScript = reads != nil
                pending = Data(pending[range.upperBound...])
            }
        }
        if let range = pending.range(of: marker) {
            let output = Array(pending[range.upperBound...])
            pending.removeAll(); isReady = true; isShellReady = true
            return output
        }
        // Only a split marker can matter; never retain banners or command echo.
        pending = Data(pending.suffix([marker.count, readyMarker.count, lineReadyMarker.count].max()! - 1))
        return []
    }
}

/// Crow's interactive SSH startup: type only `probe`, then send the startup script
/// once the remote shell reports that it is reading commands. If that report does
/// not arrive before `deadline` (a password/OTP prompt, a forced command, a menu, a
/// shell that cannot run the probe), `timedOut(at:)` becomes true and the startup
/// commands are never typed into that program.
public struct SSHShellStartup: Sendable {
    public static let readinessTimeout: Duration = .seconds(20)
    public static let readinessTimeoutMessage =
        "SSH shell did not become ready within 20 seconds, so Crow did not send its startup commands. Reconnect to try again."

    private var output = SSHStartupOutput()
    private var setup: String?
    public let deadline: ContinuousClock.Instant

    public init(setup: String, timeout: Duration = SSHShellStartup.readinessTimeout,
                now: ContinuousClock.Instant = .now) {
        self.setup = setup
        deadline = now + timeout
    }

    var token: String { output.token }
    /// The only bytes to write before the shell is ready.
    // MUTATION (experiment only): skip the handshake and type the startup script
    // immediately behind the probe, before the shell has reported readiness.
    public var probe: String { output.readinessProbe + "\n" + output.command(setup ?? "") + "\u{1f}" }
    public var isShellReady: Bool { output.isShellReady }
    /// The startup group ran; everything from here on is the user's terminal.
    public var isReady: Bool { output.isReady }

    /// Returns the output to show and, exactly once, the startup script to write
    /// as soon as the shell is ready.
    public mutating func receive(_ bytes: [UInt8]) -> (visible: [UInt8], send: String?) {
        let visible = output.receive(bytes)
        guard false, output.isShellReady, !output.isReady, let setup else { return (visible, nil) } // MUTATION: never sent after readiness
        self.setup = nil
        return (visible, output.script(setup))
    }

    public func timedOut(at now: ContinuousClock.Instant = .now) -> Bool {
        !output.isShellReady && now >= deadline
    }
}

public struct CommandError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
