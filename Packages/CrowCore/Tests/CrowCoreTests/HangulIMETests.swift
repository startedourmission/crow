import XCTest
@testable import CrowCore

final class HangulIMETests: XCTestCase {
    func testCompoundVowelsForEveryInitial() {
        let cases: [(Int, Character, Int)] = [
            (8, "ㅏ", 9), (8, "ㅐ", 10), (8, "ㅣ", 11),
            (13, "ㅓ", 14), (13, "ㅔ", 15), (13, "ㅣ", 16), (18, "ㅣ", 19),
        ]
        for initial in 0..<19 {
            for (medial, vowel, expectedMedial) in cases {
                let base = HangulIME.compose(initial: initial, medial: medial, final: nil)
                XCTAssertEqual(HangulIME.composeCompoundVowel(base: base, following: vowel),
                               HangulIME.compose(initial: initial, medial: expectedMedial, final: nil))
            }
        }
        XCTAssertEqual(HangulIME.composeCompoundVowel(base: "두", following: "ㅔ"), "뒈")
        XCTAssertEqual(HangulIME.composeCompoundVowel(base: "도", following: "ㅣ"), "되")
    }

    func testCompoundVowelsRejectUnrelatedInput() {
        for (base, next): (Character, Character) in [
            ("둔", "ㅔ"), ("돈", "ㅣ"), ("가", "ㅣ"), ("a", "ㅣ"),
            ("ㅗ", "ㅣ"), ("도", "a"), ("도", "ㄴ"), ("되", "ㅣ"), ("😀", "ㅣ"),
        ] {
            XCTAssertNil(HangulIME.composeCompoundVowel(base: base, following: next))
        }
    }

    func testMarkedTextNeverProducesPTYBytes() {
        XCTAssertTrue(HangulIME.ptyActionsForMarkedText("ㄱ").isEmpty)
        XCTAssertTrue(HangulIME.ptyActionsForMarkedText("가").isEmpty)
        XCTAssertTrue(HangulIME.ptyActionsForMarkedText("각").isEmpty)
        XCTAssertTrue(HangulIME.ptyActionsForMarkedText(nil).isEmpty)
    }

    func testCommitSendsFinishedSyllables() {
        var snapshot = HangulIME.Snapshot()
        let actions = HangulIME.ptyActionsForCommit("안녕", snapshot: &snapshot)
        XCTAssertEqual(actions, [.send("안녕")])
        XCTAssertEqual(snapshot.lastCommitted, "안녕")
    }

    func testResyllabificationDeletesWholeSyllableNotJamo() {
        var snapshot = HangulIME.Snapshot(lastCommitted: "각")
        let actions = HangulIME.ptyActionsForCommit("가", snapshot: &snapshot)
        XCTAssertEqual(actions, [.deleteThenSend(deleteCount: 1, text: "가")])
        XCTAssertEqual(snapshot.lastCommitted, "가")
    }

    func testBrokenForwardingDetectorCatchesTermiusPattern() {
        // Isolated jamo mixed with backspaces — the Ink TUI failure mode.
        let bytes: [UInt8] = Array("ㅇ".utf8) + [0x08] + Array("아".utf8)
        XCTAssertTrue(HangulIME.looksLikeBrokenHangulForwarding(bytes))
    }

    func testHealthyCommitIsNotFlagged() {
        let bytes = Array("안녕하세요".utf8)
        XCTAssertFalse(HangulIME.looksLikeBrokenHangulForwarding(bytes))
    }

    func testHangulOccupiesTwoCells() {
        XCTAssertEqual(EastAsianWidth.columns(in: "가"), 2)
        XCTAssertEqual(EastAsianWidth.columns(in: "안녕"), 4)
        XCTAssertEqual(EastAsianWidth.columns(in: "hi"), 2)
        XCTAssertEqual(EastAsianWidth.columns(in: "hi가"), 4)
    }

    func testDecomposeComposeRoundTrip() {
        let original: Character = "각"
        let jamo = HangulIME.decompose(original)
        XCTAssertEqual(jamo.initial, 0)
        XCTAssertEqual(jamo.medial, 0)
        XCTAssertEqual(jamo.final, 1)
        XCTAssertEqual(HangulIME.compose(initial: 0, medial: 0, final: 1), original)
        XCTAssertEqual(HangulIME.compose(initial: 0, medial: 0, final: nil), "가")
    }

    func testLanguageInference() {
        XCTAssertEqual(LanguageMode.infer(filename: "notes.md"), .markdown)
        XCTAssertEqual(LanguageMode.infer(filename: "config.json"), .json)
        XCTAssertEqual(LanguageMode.infer(filename: "nginx.conf"), .ini)
        XCTAssertEqual(LanguageMode.infer(filename: "run.sh"), .shell)
        XCTAssertEqual(LanguageMode.infer(filename: "readme.txt"), .plain)
    }
}
