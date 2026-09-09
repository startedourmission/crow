import Foundation

/// Minimal input discipline for the echo workspaces, until a PTY/SSH host owns editing.
/// Input bytes remain untouched for the IME inspector; only display output is interpreted.
public struct LocalEcho {
    public enum Action: Equatable {
        case write(String)
        case erase(columns: Int)
    }

    public private(set) var line = ""
    private var pendingUTF8: [UInt8] = []
    private var escapeState = 0
    private var lastWasCR = false

    public init() {}

    public mutating func receive(_ bytes: ArraySlice<UInt8>) -> [Action] {
        var actions: [Action] = []
        for byte in bytes {
            // Cursor/function keys are not shell editing commands in the echo lab.
            // Consume their escape sequences instead of moving over the prompt.
            if escapeState != 0 {
                if escapeState == 1 {
                    escapeState = (byte == 0x5b || byte == 0x4f) ? 2 : 0
                } else if (0x40...0x7e).contains(byte) {
                    escapeState = 0
                }
                continue
            }
            let followsCR = lastWasCR
            lastWasCR = byte == 0x0d
            switch byte {
            case 0x1b:
                escapeState = 1
            case 0x08, 0x7f:
                pendingUTF8.removeAll()
                if let character = line.popLast() {
                    // A grapheme (Hangul, combining accents, emoji) is one deletion.
                    let width = character.unicodeScalars.map(EastAsianWidth.columns).max() ?? 1
                    actions.append(.erase(columns: width))
                }
            case 0x0d, 0x0a:
                pendingUTF8.removeAll()
                line.removeAll()
                if byte != 0x0a || !followsCR {
                    actions.append(.write("\r\n"))
                }
            case 0x09:
                // Expand tabs so their display width and subsequent deletion agree.
                line += "    "
                actions.append(.write("    "))
            case 0x00...0x1f:
                break
            default:
                pendingUTF8.append(byte)
                if let text = String(bytes: pendingUTF8, encoding: .utf8) {
                    line += text
                    actions.append(.write(text))
                    pendingUTF8.removeAll()
                } else if pendingUTF8.count >= 4 {
                    let replacement = String(decoding: pendingUTF8, as: UTF8.self)
                    line += replacement
                    actions.append(.write(replacement))
                    pendingUTF8.removeAll()
                }
            }
        }
        return actions
    }
}
