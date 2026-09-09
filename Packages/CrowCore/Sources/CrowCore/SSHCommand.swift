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
}

public struct CommandError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
