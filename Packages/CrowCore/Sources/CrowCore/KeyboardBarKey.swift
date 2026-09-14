import Foundation

public struct KeyboardBarKey: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var key: String
    public var control: Bool
    public var shift: Bool
    public var option: Bool
    public var command: Bool
    public init(id: UUID = UUID(), key: String, control: Bool = false, shift: Bool = false, option: Bool = false, command: Bool = false) {
        self.id = id; self.key = key; self.control = control; self.shift = shift; self.option = option; self.command = command
    }
    public static let defaults = ["Escape", "Tab", "Control", "Shift", "ArrowLeft", "ArrowUp", "ArrowDown", "ArrowRight"].map { KeyboardBarKey(key: $0) }
    public static let specialKeys = ["Escape", "Tab", "Control", "Shift", "ArrowLeft", "ArrowUp", "ArrowDown", "ArrowRight", "Enter", "Backspace", "Delete", "Home", "End", "PageUp", "PageDown"]
    public var label: String {
        let labels = ["Escape": "esc", "Tab": "tab", "Control": "ctrl", "Shift": "shift", "ArrowLeft": "←", "ArrowUp": "↑", "ArrowDown": "↓", "ArrowRight": "→", "Enter": "enter", "Backspace": "⌫", "Delete": "del", "Home": "home", "End": "end", "PageUp": "pgup", "PageDown": "pgdn"]
        return (control ? "ctrl+" : "") + (option ? "alt+" : "") + (command ? "cmd+" : "") + (shift ? "shift+" : "") + (labels[key] ?? key)
    }
    public func terminalText(applicationCursor: Bool) -> String {
        let modifier = 1 + (shift ? 1 : 0) + (option ? 2 : 0) + (control ? 4 : 0) + (command ? 8 : 0)
        if let final = ["ArrowLeft": "D", "ArrowUp": "A", "ArrowDown": "B", "ArrowRight": "C", "Home": "H", "End": "F"][key] {
            return modifier == 1 ? "\u{1b}" + (applicationCursor ? "O" : "[") + final : "\u{1b}[1;\(modifier)\(final)"
        }
        if let number = ["Delete": 3, "PageUp": 5, "PageDown": 6][key] {
            return "\u{1b}[\(number)" + (modifier == 1 ? "" : ";\(modifier)") + "~"
        }
        let value: String
        switch key {
        case "Escape": value = "\u{1b}"
        case "Tab": value = shift ? "\u{1b}[Z" : "\t"
        case "Enter": value = "\r"
        case "Backspace": value = "\u{7f}"
        case "Control", "Shift": return ""
        default:
            if control, key == " " { value = "\0" }
            else if control, key.utf8.count == 1, let byte = key.uppercased().utf8.first, (64...95).contains(byte) {
                value = String(UnicodeScalar(byte & 31))
            } else { value = shift ? key.uppercased() : key }
        }
        return (option ? "\u{1b}" : "") + value
    }
}

public struct TextSnippet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var text: String
    public var memo: String
    public init(id: UUID = UUID(), name: String, text: String, memo: String = "") {
        self.id = id; self.name = name; self.text = text; self.memo = memo
    }
    private enum CodingKeys: String, CodingKey { case id, name, text, memo }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        text = try values.decode(String.self, forKey: .text)
        memo = try values.decodeIfPresent(String.self, forKey: .memo) ?? ""
    }
}
