import AppKit
import XCTest

@testable import HerdX

/// A key that is still being composed is not text yet, and the view has to know
/// the difference or input methods cannot work through it at all.
@MainActor
final class TextInputTests: XCTestCase {
    private var window: NSWindow!
    private var view: TerminalGridView!

    override func setUp() async throws {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        XCTAssertFalse(window.isVisible, "the test window must stay off screen")

        view = TerminalGridView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular), lineHeight: 1)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView?.addSubview(view)
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        view = nil
    }

    func testTheViewIsATextInputClient() {
        XCTAssertTrue(
            view is NSTextInputClient,
            "without this an input method has nothing to talk to")
    }

    func testTheViewOffersAnInputContextOnceItHasTheKeys() {
        XCTAssertTrue(window.makeFirstResponder(view))

        XCTAssertNotNil(
            view.inputContext,
            "AppKit only provides one to a view an input method can drive")
    }

    func testNothingIsMarkedToBeginWith() {
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange().location, NSNotFound)
    }

    func testAComposingKeyMarksTextRatherThanSendingIt() {
        // What a dead key, or the first keystroke of a kana, produces.
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedText, "か")
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 1))
    }

    func testMarkedTextIsReplacedAsCompositionContinues() {
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("かん", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.markedText, "かん")
        XCTAssertEqual(view.markedRange().length, 2)
        XCTAssertEqual(view.selectedRange().location, 2)
    }

    func testAnAttributedCompositionIsReadAsItsString() {
        // Input methods hand this over attributed, with the clause underlined.
        let underlined = NSAttributedString(
            string: "かん", attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
        view.setMarkedText(underlined, selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.markedText, "かん")
    }

    func testCommittingClearsTheComposition() {
        view.setMarkedText("かん", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))

        view.insertText("漢", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertFalse(
            view.hasMarkedText(),
            "the composition is finished; leaving it marked draws it twice")
        XCTAssertNil(view.markedText)
    }

    func testAbandoningACompositionClearsIt() {
        view.setMarkedText("かん", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))

        view.unmarkText()

        XCTAssertFalse(view.hasMarkedText())
    }

    func testAnEmptyCompositionCountsAsNone() {
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        // Backspacing the last character of a composition.
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertFalse(
            view.hasMarkedText(),
            "an empty marked range would keep every later key away from the pane")
    }

    func testTheCandidateWindowIsPlacedOverTheTerminal() {
        XCTAssertTrue(window.makeFirstResponder(view))

        let rect = view.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)

        XCTAssertFalse(
            rect.isEmpty, "an empty rect puts the candidate list in a screen corner")
        XCTAssertTrue(
            window.frame.intersects(rect),
            "the candidate list belongs over the text being composed")
    }

    func testChangingMachineDropsAnUnfinishedComposition() {
        view.setMarkedText("かん", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))

        view.forgetSurface()

        XCTAssertFalse(
            view.hasMarkedText(),
            "it was being composed into a pane that is no longer on screen")
    }
}
