import Foundation

/// Contract for what may reach a PTY from an Apple IME.
///
/// iOS Hangul composition mutates a syllable in place (`ㄱ` → `가` → `각`) and,
/// if those updates are forwarded, TUIs see leftover jamo plus backspaces.
/// Crow never sends marked text. Only committed UTF-8 goes to the PTY.
/// Resyllabification is expressed as deleting whole syllables, never isolated jamo.
public enum HangulIME: Sendable {
    public enum Action: Equatable, Sendable {
        case send(String)
        case deleteThenSend(deleteCount: Int, text: String)
    }

    public struct Snapshot: Equatable, Sendable {
        public var lastCommitted: String

        public init(lastCommitted: String = "") {
            self.lastCommitted = lastCommitted
        }
    }

    /// Composing (marked) text must never produce PTY bytes.
    public static func ptyActionsForMarkedText(_ marked: String?) -> [Action] {
        _ = marked
        return []
    }

    /// Confirmed text from `insertText` / `unmarkText`.
    public static func ptyActionsForCommit(_ text: String, snapshot: inout Snapshot) -> [Action] {
        guard !text.isEmpty else { return [] }

        if let (deleteCount, insert) = resyllabify(previous: snapshot.lastCommitted, incoming: text) {
            snapshot.lastCommitted = lastHangulRun(in: insert)
            return [.deleteThenSend(deleteCount: deleteCount, text: insert)]
        }

        snapshot.lastCommitted = lastHangulRun(in: text)
        return [.send(text)]
    }

    public static func encodesAsIsolatedJamo(_ text: String) -> Bool {
        text.unicodeScalars.contains { isCompatibilityJamo($0) || isConjoiningJamo($0) }
    }

    /// True when `bytes` contain DEL/BS plus compatibility jamo — the Termius/Blink failure mode.
    public static func looksLikeBrokenHangulForwarding(_ bytes: [UInt8]) -> Bool {
        let hasDelete = bytes.contains(0x08) || bytes.contains(0x7f)
        guard hasDelete, let text = String(bytes: bytes, encoding: .utf8) else { return false }
        return encodesAsIsolatedJamo(text)
    }

    // MARK: - Hangul

    static func resyllabify(previous: String, incoming: String) -> (Int, String)? {
        guard let prevLast = previous.last, isPrecomposedHangul(prevLast),
              let nextFirst = incoming.first, isPrecomposedHangul(nextFirst)
        else { return nil }

        let prev = decompose(prevLast)
        let next = decompose(nextFirst)
        guard let prevFinal = prev.final,
              let mappedInitial = jongseongToChoseong[prevFinal],
              next.initial == mappedInitial
        else { return nil }

        let rebuilt = compose(initial: prev.initial, medial: prev.medial, final: nil)
        guard rebuilt == nextFirst else { return nil }
        return (1, incoming)
    }

    static func lastHangulRun(in text: String) -> String {
        var run = ""
        for character in text.reversed() {
            if isPrecomposedHangul(character) {
                run.insert(character, at: run.startIndex)
            } else {
                break
            }
        }
        return run
    }

    public static func isPrecomposedHangul(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return (0xAC00...0xD7A3).contains(scalar.value)
    }

    public static func isCompatibilityJamo(_ scalar: Unicode.Scalar) -> Bool {
        (0x3131...0x318E).contains(scalar.value)
    }

    public static func isConjoiningJamo(_ scalar: Unicode.Scalar) -> Bool {
        (0x1100...0x11FF).contains(scalar.value) || (0xA960...0xA97F).contains(scalar.value) || (0xD7B0...0xD7FF).contains(scalar.value)
    }

    public struct Jamo: Equatable, Sendable {
        public var initial: Int
        public var medial: Int
        public var final: Int?
    }

    public static func decompose(_ character: Character) -> Jamo {
        let value = character.unicodeScalars.first?.value ?? 0
        let sIndex = Int(value - 0xAC00)
        let initial = sIndex / 588
        let medial = (sIndex % 588) / 28
        let finalIndex = sIndex % 28
        return Jamo(initial: initial, medial: medial, final: finalIndex == 0 ? nil : finalIndex)
    }

    public static func compose(initial: Int, medial: Int, final: Int?) -> Character {
        let sIndex = (initial * 21 + medial) * 28 + (final ?? 0)
        let value = 0xAC00 + sIndex
        return Character(Unicode.Scalar(value)!)
    }

    /// Jongseong index → choseong index. Compound batchim (ㄳ, ㄵ, …) are omitted;
    /// those split into two syllables and are handled as a later commit.
    private static let jongseongToChoseong: [Int: Int] = [
        1: 0,  // ㄱ
        2: 1,  // ㄲ
        4: 2,  // ㄴ
        7: 3,  // ㄷ
        8: 5,  // ㄹ
        16: 6, // ㅁ
        17: 7, // ㅂ
        19: 9, // ㅅ
        20: 10, // ㅆ
        21: 11, // ㅇ
        22: 12, // ㅈ
        23: 14, // ㅊ
        24: 15, // ㅋ
        25: 16, // ㅌ
        26: 17, // ㅍ
        27: 18, // ㅎ
    ]
}

/// East Asian Width used for terminal cell occupancy. Hangul is two cells.
public enum EastAsianWidth: Sendable {
    public static func columns(_ scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if (0x1100...0x115F).contains(value) { return 2 }
        if (0x2329...0x232A).contains(value) { return 2 }
        if (0x2E80...0xA4CF).contains(value) && value != 0x303F { return 2 }
        if (0xAC00...0xD7A3).contains(value) { return 2 }
        if (0xF900...0xFAFF).contains(value) { return 2 }
        if (0xFE10...0xFE19).contains(value) { return 2 }
        if (0xFE30...0xFE6F).contains(value) { return 2 }
        if (0xFF00...0xFF60).contains(value) { return 2 }
        if (0xFFE0...0xFFE6).contains(value) { return 2 }
        if (0x3000...0x303E).contains(value) { return 2 }
        if (0x3131...0x318E).contains(value) { return 2 }
        if (0x1F300...0x1FAFF).contains(value) { return 2 }
        return 1
    }

    public static func columns(in string: String) -> Int {
        string.unicodeScalars.reduce(0) { $0 + columns($1) }
    }
}
