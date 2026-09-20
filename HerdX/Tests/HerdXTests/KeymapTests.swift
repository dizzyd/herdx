import AppKit
import XCTest

@testable import HerdX

/// The keymap is the user's, read from what the server exports. These use the
/// shape `toml::to_string_pretty` actually writes, checked against the
/// vendored server rather than assumed.
final class KeymapTests: XCTestCase {
    private func keystroke(
        _ characters: String, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    /// An arrow, which is a key code rather than a character the profile spells.
    private func arrow(_ keyCode: UInt16) -> NSEvent {
        keystroke("\u{F700}", keyCode: keyCode)
    }

    private func bindings(
        of action: Keymap.Action, in keymap: Keymap
    ) -> [Keymap.Binding] {
        keymap.bindings.filter { $0.action == action }.map(\.binding)
    }

    // MARK: - The shape the server writes

    func testAProfileUnderTheKeysTableParses() {
        let keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+a"
                new_tab = "prefix+t"
                next_tab = "prefix+n"
                """)

        XCTAssertNotNil(keymap)
        XCTAssertEqual(keymap?.prefix.key, .character("a"))
        XCTAssertTrue(keymap?.prefix.control == true)
        XCTAssertEqual(bindings(of: .newTab, in: keymap!).count, 1)
    }

    func testAnArrayValuedBindingBecomesOneBindingPerSpelling() {
        // How toml::to_string_pretty writes BindingConfig::Many — over several
        // lines, which is what a line parser has to be told about.
        let keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                next_tab = [
                    "prefix+n",
                    "alt+]",
                ]
                """)

        let next = bindings(of: .nextTab, in: keymap!)
        XCTAssertEqual(next.count, 2, "both spellings are ways to reach the action")
        XCTAssertEqual(next.first?.key, .character("n"))
        XCTAssertTrue(next.first?.usesPrefix == true)
        XCTAssertEqual(next.last?.key, .character("]"))
        XCTAssertTrue(next.last?.option == true)
        XCTAssertFalse(next.last?.usesPrefix == true)
    }

    func testAnArrayIsNotReadAsABindingOnTheBracketKey() {
        let keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                next_tab = [
                    "prefix+n",
                ]
                """)

        XCTAssertFalse(
            bindings(of: .nextTab, in: keymap!).contains { $0.key == .character("[") },
            "the opening bracket is the array's, not a key")
    }

    func testAnInlineArrayParsesToo() {
        let keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                zoom = ["prefix+z", "alt+z"]
                """)

        XCTAssertEqual(bindings(of: .zoom, in: keymap!).count, 2)
    }

    func testABracketKeyIsStillABracketKey() {
        // `copy_mode = "prefix+["` is one spelling that happens to end in a
        // bracket, and must not be mistaken for an array.
        let keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                copy_mode = "prefix+["
                """)

        XCTAssertEqual(bindings(of: .copyMode, in: keymap!).first?.key, .character("["))
    }

    func testKeysInOtherTablesAreNotReadAsActions() {
        // herdr writes these beside [keys]; `key` and `command` are not action
        // names, but a parser that ignores table headers has no way to know a
        // future one would not be.
        let keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                new_tab = "prefix+c"

                [keys.indexed]
                tabs = "ctrl"

                [[keys.command]]
                key = "prefix+g"
                command = "lazygit"
                """)

        XCTAssertEqual(bindings(of: .newTab, in: keymap!).count, 1)
        XCTAssertEqual(keymap?.prefix.key, .character("b"))
    }

    func testAProfileWithNoTableHeaderStillParses() {
        // The fallback and the additions are written that way.
        XCTAssertFalse(Keymap.fallback.bindings.isEmpty)
        XCTAssertEqual(Keymap.fallback.prefix.key, .character("b"))
    }

    // MARK: - Dispatch

    func testADirectBindingDispatches() {
        let keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                new_tab = "alt+t"
                """)!
        let resolver = ChordResolver()
        resolver.keymap = keymap

        let (action, consumed) = resolver.resolve(keystroke("t", flags: [.option]))

        XCTAssertEqual(action, .newTab, "a binding without the prefix never dispatched")
        XCTAssertTrue(consumed, "a key that ran an action must not also reach the pane")
    }

    func testAnUnboundKeyStillReachesThePane() {
        let resolver = ChordResolver()
        resolver.keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                new_tab = "alt+t"
                """)!

        let (action, consumed) = resolver.resolve(keystroke("t"))

        XCTAssertNil(action)
        XCTAssertFalse(consumed, "plain typing belongs to the pane")
    }

    func testAPrefixedBindingStillNeedsThePrefix() {
        let resolver = ChordResolver()
        resolver.keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                new_tab = "prefix+c"
                """)!

        XCTAssertNil(resolver.resolve(keystroke("c")).action)
        XCTAssertFalse(resolver.resolve(keystroke("c")).consumed)

        let (_, armed) = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertTrue(armed)
        XCTAssertEqual(resolver.resolve(keystroke("c")).action, .newTab)
    }

    func testEitherSpellingOfAnArrayBindingDispatches() {
        let resolver = ChordResolver()
        resolver.keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                next_tab = [
                    "prefix+n",
                    "alt+]",
                ]
                """)!

        XCTAssertEqual(
            resolver.resolve(keystroke("]", flags: [.option])).action, .nextTab,
            "the second spelling disappeared during parsing")

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(resolver.resolve(keystroke("n")).action, .nextTab)
    }

    // MARK: - Spellings that contain a comma

    func testASpellingContainingACommaSurvivesParsing() {
        // format_key_combo writes Char(',') as a literal comma, so this is what
        // the exported profile holds for a binding on that key.
        let keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                next_tab = ["prefix+n", "alt+,"]
                """)

        let next = bindings(of: .nextTab, in: keymap!)
        XCTAssertEqual(next.count, 2, "the comma spelling was split in half and dropped")
        XCTAssertEqual(next.last?.key, .character(","))
        XCTAssertTrue(next.last?.option == true)
    }

    func testACommaSpellingSurvivesAMultilineArray() {
        let keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                next_tab = [
                    "prefix+n",
                    "alt+,",
                ]
                """)

        XCTAssertEqual(bindings(of: .nextTab, in: keymap!).count, 2)
    }

    func testACommaSpellingDispatches() {
        let resolver = ChordResolver()
        resolver.keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                next_tab = ["prefix+n", "alt+,"]
                """)!

        let (action, consumed) = resolver.resolve(keystroke(",", flags: [.option]))

        XCTAssertEqual(action, .nextTab, "alt+comma reached the terminal instead")
        XCTAssertTrue(consumed)
    }

    func testABracketSpellingInAnArrayIsStillABracket() {
        let keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                copy_mode = ["prefix+[", "alt+]"]
                """)

        let copy = bindings(of: .copyMode, in: keymap!)
        XCTAssertEqual(copy.count, 2)
        XCTAssertEqual(copy.first?.key, .character("["))
        XCTAssertEqual(copy.last?.key, .character("]"))
    }





    // MARK: - Shift

    func testAnExplicitShiftIsRequired() {
        let resolver = ChordResolver()
        resolver.keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                new_tab = "ctrl+shift+t"
                """)!

        let (plain, consumed) = resolver.resolve(keystroke("t", flags: [.control]))
        XCTAssertNil(plain, "ctrl+t is a distinct keystroke and belongs to the terminal")
        XCTAssertFalse(consumed)

        XCTAssertEqual(
            resolver.resolve(keystroke("t", flags: [.control, .shift])).action, .newTab)
    }


    func testShiftedPunctuationStillMatchesWithoutADeclaredShift() {
        // `help = "prefix+?"` says nothing about shift because "?" already
        // carries one. This is what the fallback exists for.
        let resolver = ChordResolver()
        resolver.keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                help = "prefix+?"
                """)!

        _ = resolver.resolve(keystroke("b", flags: [.control]))

        XCTAssertEqual(resolver.resolve(keystroke("?", flags: [.shift])).action, .help)
    }


    func testALetterBindingDoesNotAbsorbItsShiftedForm() {
        let resolver = ChordResolver()
        resolver.keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                focus_pane_left = "prefix+h"
                """)!

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        let (action, _) = resolver.resolve(keystroke("h", flags: [.shift]))

        XCTAssertNil(action, "prefix+shift+h is a binding herdr uses for something else")
    }


    func testTheTwoFormsOfALetterStayDistinct() {
        let resolver = ChordResolver()
        resolver.keymap = Keymap(
            profile: """
                [keys]
                prefix = "ctrl+b"
                focus_pane_left = "prefix+h"
                swap_pane_left = "prefix+shift+h"
                """)!

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(resolver.resolve(keystroke("h")).action, .focusPaneLeft)

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(
            resolver.resolve(keystroke("h", flags: [.shift])).action, .swapPaneLeft)
    }

    // MARK: - The agent keys HerdX adds

    func testTheAgentKeysAreBoundBecauseHerdrLeavesThemUnset() {
        // herdr ships next_agent, previous_agent and focus_agent with no
        // binding at all, so these take nothing away from anybody.
        let keymap = Keymap(profile: """
            [keys]
            prefix = "ctrl+b"
            new_tab = "prefix+c"
            """)!
        let resolver = ChordResolver()
        resolver.keymap = keymap

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(resolver.resolve(keystroke("a")).0, .focusTopAgent)

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(resolver.resolve(keystroke("n", flags: [.option])).0, .nextAgent)

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(resolver.resolve(keystroke("p", flags: [.option])).0, .previousAgent)
    }

    // MARK: - The local workspace key

    func testTheLocalWorkspaceKeyIsACommandChordAfterThePrefix() {
        // herdr's defaults never reach for ⌘, so the chord is free — but it
        // has to actually resolve, and a modifier the parser dropped would
        // leave prefix+n meaning this instead of next_tab.
        let resolver = ChordResolver()
        resolver.keymap = Keymap(profile: """
            [keys]
            prefix = "ctrl+b"
            new_workspace = "prefix+shift+n"
            next_tab = "prefix+n"
            """)!

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(
            resolver.resolve(keystroke("n", flags: [.command])).0, .newLocalWorkspace)

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(
            resolver.resolve(keystroke("n")).0, .nextTab,
            "the command modifier was dropped and this chord ate a plain key")

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(
            resolver.resolve(keystroke("n", flags: [.shift])).0, .newWorkspace,
            "and herdr's own shifted form is untouched")
    }

    func testTheLocalWorkspaceKeyStandsAsideForAProfileThatSpentIt() {
        let resolver = ChordResolver()
        resolver.keymap = Keymap(profile: """
            [keys]
            prefix = "ctrl+b"
            zoom = "prefix+cmd+n"
            """)!

        _ = resolver.resolve(keystroke("b", flags: [.control]))

        XCTAssertEqual(
            resolver.resolve(keystroke("n", flags: [.command])).0, .zoom,
            "an addition that overrode the user's own keymap would be the guessing "
                + "Keymap exists to stop")
    }

    func testTheLocalWorkspaceChordIsReachableFromAKeystroke() {
        // The same question HERDX_PROBE_CHORDS asks of a live keymap: a
        // binding nothing can type is worse than no binding at all.
        let binding = bindings(of: .newLocalWorkspace, in: Keymap.fallback).first
        XCTAssertNotNil(binding, "the addition never reached the fallback keymap")
        XCTAssertEqual(binding?.key, .character("n"))
        XCTAssertTrue(binding?.command == true)
        XCTAssertTrue(binding?.usesPrefix == true)
        XCTAssertFalse(binding?.shift == true, "⇧⌘N is a different keystroke from ⌘N")
    }

    // MARK: - The hibernate key

    func testHibernateTakesCommandHWithoutDisturbingH() {
        // herdr binds prefix+h and prefix+shift+h to two different things, so
        // the ⌘ form has to be told apart from both.
        let resolver = ChordResolver()
        resolver.keymap = Keymap(profile: """
            [keys]
            prefix = "ctrl+b"
            focus_pane_left = "prefix+h"
            swap_pane_left = "prefix+shift+h"
            """)!

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(
            resolver.resolve(keystroke("h", flags: [.command])).0, .hibernateWorkspace)

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(
            resolver.resolve(keystroke("h")).0, .focusPaneLeft,
            "a key that ends processes must not be reachable by a plain letter")

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(resolver.resolve(keystroke("h", flags: [.shift])).0, .swapPaneLeft)
    }

    func testHibernateStandsAsideForAProfileThatSpentTheKey() {
        let resolver = ChordResolver()
        resolver.keymap = Keymap(profile: """
            [keys]
            prefix = "ctrl+b"
            zoom = "prefix+cmd+h"
            """)!

        _ = resolver.resolve(keystroke("b", flags: [.control]))

        XCTAssertEqual(
            resolver.resolve(keystroke("h", flags: [.command])).0, .zoom,
            "the keymap belongs to the user, even for keys we would rather have")
    }

    func testTheHibernateChordIsReachableFromAKeystroke() {
        let binding = bindings(of: .hibernateWorkspace, in: Keymap.fallback).first
        XCTAssertNotNil(binding, "the addition never reached the fallback keymap")
        XCTAssertEqual(binding?.key, .character("h"))
        XCTAssertTrue(binding?.command == true)
        XCTAssertTrue(binding?.usesPrefix == true)
        XCTAssertFalse(binding?.shift == true)
    }

    func testTheUpArrowIsItsOwnActionSoItCanDoMoreThanKDoes() {
        let keymap = Keymap(profile: """
            [keys]
            prefix = "ctrl+b"
            focus_pane_up = "prefix+k"
            """)!
        let resolver = ChordResolver()
        resolver.keymap = keymap

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(
            resolver.resolve(arrow(126)).0, .focusAbove,
            "the arrow has to be told apart from k, or the handler cannot treat it differently")

        _ = resolver.resolve(keystroke("b", flags: [.control]))
        XCTAssertEqual(
            resolver.resolve(keystroke("k")).0, .focusPaneUp,
            "and k stays exactly the pane move herdr bound it to")
    }

    func testTheUsersOwnBindingKeepsTheKeyTheAdditionWanted() {
        // The keymap belongs to the user: an addition is only ever taken up
        // where herdr left the key free.
        let keymap = Keymap(profile: """
            [keys]
            prefix = "ctrl+b"
            zoom = "prefix+a"
            """)!
        let resolver = ChordResolver()
        resolver.keymap = keymap

        _ = resolver.resolve(keystroke("b", flags: [.control]))

        XCTAssertEqual(
            resolver.resolve(keystroke("a")).0, .zoom,
            "the jump must not take a key the user has already spent")
    }

    func testTheDefaultKeymapClaimsNothingUnprefixed() {
        // herdr's own defaults are all prefixed, so nothing this change added
        // should start swallowing ordinary typing.
        let resolver = ChordResolver()
        for letter in ["a", "c", "n", "t", "x", "z"] {
            XCTAssertFalse(
                resolver.resolve(keystroke(letter)).consumed,
                "\(letter) was taken from the pane")
        }
    }
}
