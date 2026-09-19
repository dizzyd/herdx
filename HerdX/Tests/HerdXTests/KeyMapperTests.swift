import AppKit
import CHerdrCore
import XCTest

@testable import HerdX

/// Which keystrokes are herdr's semantic keys, and which are text an input
/// method may still be composing.
final class KeyMapperTests: XCTestCase {
    /// `characters` is what the layout produced; `unmodified` is the key.
    ///
    /// The two differ under Option, and that difference is the whole question
    /// here, so both are given rather than assumed equal.
    private func keystroke(
        characters: String, unmodified: String, keyCode: UInt16,
        flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: unmodified, isARepeat: false, keyCode: keyCode)!
    }

    func testAnOptionDeadKeyIsLeftToTheInputContext() {
        // Option+E on a US layout. UCKeyTranslate gives it no characters at all
        // and a dead-key state of 1: the layout has started an acute accent and
        // is waiting for the letter it goes on.
        let deadKey = keystroke(characters: "", unmodified: "e", keyCode: 14, flags: [.option])

        XCTAssertNil(
            KeyMapper.map(deadKey),
            "sent as Alt-E, the composition never starts and é cannot be typed")
    }

    func testEveryOptionDeadKeyOnTheUSLayoutIsLeftAlone() {
        // The five the layout reports: E, U, I, N and backtick.
        for (key, code) in [("e", 14), ("u", 32), ("i", 34), ("n", 45), ("`", 50)] {
            let event = keystroke(
                characters: "", unmodified: key, keyCode: UInt16(code), flags: [.option])
            XCTAssertNil(KeyMapper.map(event), "option+\(key) begins a composition")
        }
    }

    func testAnOptionKeyThatProducesTextIsStillAnAltChord() {
        // Option+B is "∫" on a US layout, not a dead key. It has to stay an Alt
        // chord or Meta-B stops reaching readline, which is word-back.
        let altB = keystroke(characters: "∫", unmodified: "b", keyCode: 11, flags: [.option])

        guard let mapped = KeyMapper.map(altB) else {
            return XCTFail("option+b is not a composition; it is Alt-B")
        }
        XCTAssertEqual(mapped.codepoint, UnicodeScalar("b").value)
        XCTAssertEqual(mapped.modifiers & UInt8(HX_MOD_ALT), UInt8(HX_MOD_ALT))
    }

    func testAltChordsUsedForWordMovementStillMap() {
        for (key, produced, code) in [("b", "∫", 11), ("f", "ƒ", 3), ("d", "∂", 2)] {
            let event = keystroke(
                characters: produced, unmodified: key, keyCode: UInt16(code), flags: [.option])
            XCTAssertNotNil(KeyMapper.map(event), "alt+\(key) is a terminal shortcut")
        }
    }

    func testControlChordsAreUnaffected() {
        let ctrlB = keystroke(
            characters: "\u{02}", unmodified: "b", keyCode: 11, flags: [.control])

        guard let mapped = KeyMapper.map(ctrlB) else { return XCTFail("ctrl+b is a chord") }
        XCTAssertEqual(mapped.modifiers & UInt8(HX_MOD_CONTROL), UInt8(HX_MOD_CONTROL))
    }

    func testPlainTypingIsLeftToTheInputContext() {
        XCTAssertNil(KeyMapper.map(keystroke(characters: "a", unmodified: "a", keyCode: 0)))
    }

    func testKeysWithNamesOfTheirOwnStillMap() {
        // Return carries Option here: a named key is named whatever is held.
        let enter = keystroke(characters: "\r", unmodified: "\r", keyCode: 36, flags: [.option])
        XCTAssertEqual(KeyMapper.map(enter)?.kind, UInt16(HX_KEY_ENTER))

        let left = keystroke(
            characters: "\u{F702}", unmodified: "\u{F702}", keyCode: 123, flags: [.option])
        XCTAssertEqual(KeyMapper.map(left)?.kind, UInt16(HX_KEY_LEFT))
    }
}
