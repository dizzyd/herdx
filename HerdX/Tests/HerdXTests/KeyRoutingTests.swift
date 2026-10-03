import AppKit
import XCTest

@testable import HerdX

/// Does a keystroke typed into a text field stay in the text field?
///
/// herdr's bindings come off a local event monitor, which AppKit calls for
/// every key the application receives. It asked nothing about where the event
/// came from, so `⌃b x` typed while renaming a tab closed a pane: the chord
/// resolver saw the keys, the field saw them too, and the pane was gone before
/// anyone could connect the two.
@MainActor
final class KeyRoutingTests: XCTestCase {
    private func window() -> NSWindow {
        // Offscreen and never ordered in: a test must not put anything on
        // anybody's display.
        NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true)
    }

    func testTheTerminalsOwnKeystrokeIsItsToInterpret() {
        let terminal = window()
        let grid = NSView()
        XCTAssertTrue(
            KeyRouting.belongsToTerminal(
                event: terminal, terminal: terminal, firstResponder: grid, terminalView: grid))
    }

    /// The bug: a sheet is a window of its own, so its field's keys arrive
    /// through the same monitor.
    func testASheetsKeystrokeIsNotTheTerminals() {
        let terminal = window()
        let sheet = window()
        let grid = NSView()
        let field = NSTextField()
        XCTAssertFalse(
            KeyRouting.belongsToTerminal(
                event: sheet, terminal: terminal, firstResponder: field, terminalView: grid),
            "a prompt's field would have run a terminal chord")
    }

    /// Settings and Machines are separate windows, and both are full of fields.
    func testAnotherWindowsKeystrokeIsNotTheTerminals() {
        let terminal = window()
        let settings = window()
        let grid = NSView()
        XCTAssertFalse(
            KeyRouting.belongsToTerminal(
                event: settings, terminal: terminal, firstResponder: grid, terminalView: grid),
            "the window was ignored, so only the responder stood between a "
                + "field and close_pane")
    }

    /// Belt as well as braces: if anything in the terminal window ever takes
    /// keyboard input, the keys are not the terminal's while it holds it.
    func testAFieldInsideTheTerminalWindowStillKeepsItsKeys() {
        let terminal = window()
        let grid = NSView()
        let field = NSTextField()
        XCTAssertFalse(
            KeyRouting.belongsToTerminal(
                event: terminal, terminal: terminal, firstResponder: field, terminalView: grid))
    }

    /// A window with nothing focused is not the terminal having focus. An
    /// `NSWindow` is its own first responder until something else is made one,
    /// so this is the state the window starts in.
    func testAWindowWithNothingFocusedIsNotTheTerminalFocused() {
        let terminal = window()
        let grid = NSView()
        XCTAssertFalse(
            KeyRouting.belongsToTerminal(
                event: terminal, terminal: terminal, firstResponder: terminal,
                terminalView: grid))
        XCTAssertFalse(
            KeyRouting.belongsToTerminal(
                event: terminal, terminal: terminal, firstResponder: nil, terminalView: grid))
    }

    /// A chord resolved before asking eats the key, and the view never hears
    /// about it — which for a composing input method means a composition that
    /// cannot be finished or abandoned.
    func testAComposingInputMethodOwnsEveryKey() {
        let view = TerminalGridView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular), lineHeight: 1)
        XCTAssertFalse(view.ownsEveryKey, "nothing is composing yet")

        view.setMarkedText("\u{306B}", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.ownsEveryKey, "a chord would eat the composition's keys")

        view.unmarkText()
        XCTAssertFalse(view.ownsEveryKey)
    }

    /// herdr's own exception: while a copy-mode search prompt is open the
    /// prefix belongs to the query, because a query is text.
    ///
    /// Copy mode at large is deliberately *not* an exception — herdr arms the
    /// prefix from inside it, and disagreeing with the TUI about a shared key
    /// would be worse than the binding it shadows.
    func testACopyModeSearchPromptOwnsEveryKeyButCopyModeDoesNot() {
        let view = TerminalGridView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular), lineHeight: 1)
        view.setPanesForTesting([
            PaneView(
                id: "w1:p1", rect: CellRect(x: 0, y: 0, width: 80, height: 24),
                inner: CellRect(x: 0, y: 0, width: 80, height: 24), focused: true,
                alternateScreen: false, mouseReporting: false, scrollOffsetFromBottom: 0,
                scrollMaxOffsetFromBottom: 0, contentRevision: 1)
        ])

        view.enterCopyMode()
        XCTAssertFalse(
            view.ownsEveryKey,
            "copy mode took the prefix, which herdr gives to the prefix")

        view.enterCopyMode(searching: true)
        XCTAssertTrue(view.ownsEveryKey, "the search query lost its keys to a chord")
    }

    /// An event with no window at all — a synthesised one, or one from the
    /// system — is nobody's to act on.
    func testAWindowlessEventIsNotActedOn() {
        let terminal = window()
        let grid = NSView()
        XCTAssertFalse(
            KeyRouting.belongsToTerminal(
                event: nil, terminal: terminal, firstResponder: grid, terminalView: grid))
    }
}
