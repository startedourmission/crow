import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex, claude, grok
    public var id: String { rawValue }
    public var title: String {
        switch self { case .codex: "Codex"; case .claude: "Claude"; case .grok: "Grok" }
    }
    public var arguments: [String] {
        switch self {
        case .codex: ["--dangerously-bypass-approvals-and-sandbox"]
        case .claude: ["--dangerously-skip-permissions"]
        case .grok: ["--always-approve"]
        }
    }
    public func command(directory: String) -> String {
        TerminalCommand.environment + "cd " + TerminalCommand.path(directory) + " && exec "
            + ([rawValue] + arguments).map(TerminalCommand.quote).joined(separator: " ")
    }
}

/// Presentation metadata only. Conversation history belongs to the CLI.
public struct AgentTerminal: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var provider: AgentProvider
    public var directory: String
    public var name = ""
    public var isPinned = false
    public var sessionID: String?
    public var forkSession: Bool?
    /// Legacy isolated-agent tabs must be reopened explicitly as ordinary agents.
    public var isManagedReverse: Bool?
    public var command: String {
        guard let sessionID else { return provider.command(directory: directory) }
        let resume: [String] = provider == .codex ? [forkSession == true ? "fork" : "resume", sessionID]
            : ["--resume", sessionID] + (forkSession == true ? ["--fork-session"] : [])
        return TerminalCommand.environment + "cd " + TerminalCommand.path(directory) + " && exec "
            + ([provider.rawValue] + resume + provider.arguments).map(TerminalCommand.quote).joined(separator: " ")
    }
    public var title: String { name.isEmpty ? provider.title : name }
    public init(provider: AgentProvider, directory: String) { self.provider = provider; self.directory = directory }
}

public enum TerminalCommand {
    // SSH servers need not have en_US.UTF-8 installed. Pick an available UTF-8
    // locale only when the effective character encoding is not already UTF-8.
    public static let utf8Environment = """
    case "$(locale charmap 2>/dev/null)" in
      UTF-8|UTF8|utf-8|utf8) ;;
      *)
        crow_utf8_locale=$(locale -a 2>/dev/null | LC_ALL=C awk 'tolower($0) ~ /^(c|en_us)[.]utf-?8$/ { print; found=1; exit } tolower($0) ~ /utf-?8$/ && !fallback { fallback=$0 } END { if (!found) print fallback }')
        if [ -n "$crow_utf8_locale" ]; then
          export LANG="$crow_utf8_locale" LC_CTYPE="$crow_utf8_locale"
          if [ -n "${LC_ALL-}" ]; then export LC_ALL="$crow_utf8_locale"; fi
        fi
        unset crow_utf8_locale ;;
    esac;
    """

    public static func utf8Environment(_ original: [String: String], fallback: String = "en_US.UTF-8") -> [String: String] {
        var result = original
        let effective = ["LC_ALL", "LC_CTYPE", "LANG"].compactMap { original[$0] }.first { !$0.isEmpty } ?? ""
        let normalized = effective.lowercased().replacingOccurrences(of: "-", with: "")
        if !normalized.contains("utf8") {
            result["LANG"] = fallback
            result["LC_CTYPE"] = fallback
            if let all = original["LC_ALL"], !all.isEmpty { result["LC_ALL"] = fallback }
        }
        result["TERM"] = "xterm-256color"
        return result
    }

    public static let environment = "export PATH=\"$PATH:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin\"; "
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func path(_ value: String) -> String {
        value == "~" ? "\"$HOME\"" : value.hasPrefix("~/") ? "\"$HOME\"/" + quote(String(value.dropFirst(2))) : quote(value)
    }
}

public enum AgentActivity: String, Sendable {
    case working, idle, needsInput, unknown
    public var title: String {
        switch self {
        case .working: "Working"
        case .idle: "Idle"
        case .needsInput: "Needs input"
        case .unknown: "Running"
        }
    }
}

/// A best-effort reading of the current terminal screen, never a conversation log.
/// Silence alone is not evidence that an agent has finished its turn.
public enum AgentActivityDetector {
    public static func detect(provider: AgentProvider, lines: [String], cursorRow: Int,
                              outputIsRecent: Bool) -> AgentActivity {
        let rows = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let footer = Array(rows.prefix((rows.lastIndex { !$0.isEmpty } ?? -1) + 1).suffix(18))
        let text = footer.joined(separator: "\n")
        let prompt = rows.indices.contains(cursorRow) ? rows[cursorRow] : ""
        let markers: [String] = provider == .codex ? ["›", "❯"] : provider == .claude ? ["❯", ">"] : ["❯", "›", ">"]
        let atPrompt = markers.contains { prompt == $0 || prompt.hasPrefix($0 + " ") }
        let promptValue = String(prompt.dropFirst()).trimmingCharacters(in: .whitespaces)
        let selectedOption = promptValue.first?.isNumber == true || ["yes,", "no,", "allow "].contains { promptValue.hasPrefix($0) }
        let atComposer = atPrompt && !selectedOption
        let busy = ["esc to interrupt", "esc to stop", "escape to interrupt", "ctrl+c to interrupt", "ctrl-c to interrupt"]
            .contains { text.contains($0) }
        // Approval/question pickers replace the composer and can coexist with a
        // paused busy indicator. Require a choice/confirmation control as well.
        let approval = ["do you want to proceed", "would you like to run", "requires approval", "allow once", "yes, allow", "yes, proceed", "permission required", "승인하시겠", "허용하시겠"]
            .contains { text.contains($0) }
        let choices = footer.contains { line in
            line.hasPrefix("❯") || line.hasPrefix("›") || line.hasPrefix("1.") || line.hasPrefix("1)")
                || line.contains("enter to select") || line.contains("enter to confirm") || line.contains("[y/n]")
        }
        if !atComposer && approval && choices { return .needsInput }
        if !atComposer && choices && ["tab to navigate", "enter to select", "enter to submit", "type your answer", "select an option", "select all that apply"]
            .contains(where: { text.contains($0) }) { return .needsInput }
        if busy { return .working }
        // Use the live cursor row, rather than old prompts left in scrollback.
        guard rows.indices.contains(cursorRow) else { return .unknown }
        if atComposer && !outputIsRecent {
            let preceding = rows[max(0, cursorRow - 6)..<cursorRow].filter {
                !$0.isEmpty && !$0.allSatisfy { "─━—-│╰╭╮╯ ".contains($0) }
            }
            if let last = preceding.last, last.hasSuffix("?") || last.hasSuffix("？") { return .needsInput }
            return .idle
        }
        return outputIsRecent ? .working : .unknown
    }
}
