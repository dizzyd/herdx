import AppKit
import XCTest

@testable import HerdX

/// Motions and searches are answered by the server, so a reply can arrive after
/// the copy mode that asked for it has gone.
@MainActor
final class CopyModeTests: XCTestCase {
    private func pane(_ id: String) -> PaneView {
        PaneView(
            id: id,
            rect: CellRect(x: 0, y: 0, width: 80, height: 24),
            inner: CellRect(x: 0, y: 0, width: 78, height: 22),
            focused: true,
            alternateScreen: false,
            mouseReporting: false,
            scrollOffsetFromBottom: 0,
            scrollMaxOffsetFromBottom: 0,
            contentRevision: 2)
    }

    private func gridView(panes: [PaneView]) -> TerminalGridView {
        let view = TerminalGridView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular), lineHeight: 1)
        view.setPanesForTesting(panes)
        return view
    }

    private func keystroke(_ characters: String, keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    /// A search reply placing a match at row 40.
    private let matchAtRowForty = """
        {"result":{"matches":[{"start":{"row":40,"col":3},"end":{"row":40,"col":9}}]}}
        """

    /// Types `query` into the search field and returns the reply handler the
    /// request was issued with.
    private func startSearch(
        _ query: String, in view: TerminalGridView
    ) -> ((String) -> Void)? {
        var reply: ((String) -> Void)?
        view.onCopyModeRequest = { _, _, completion in reply = completion }

        view.enterCopyMode(searching: true)
        for character in query {
            _ = view.handleCopyModeKey(keystroke(String(character)))
        }
        _ = view.handleCopyModeKey(keystroke("\r", keyCode: 36))
        return reply
    }

    func testEachEntryIntoCopyModeIsANewSession() {
        let view = gridView(panes: [pane("w1:p1")])

        view.enterCopyMode()
        let first = view.copyMode?.generation
        view.exitCopyMode()
        view.enterCopyMode()
        let second = view.copyMode?.generation

        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second, "two sessions have to be tellable apart")
    }

    func testASearchReplyMovesTheCursorOfTheSessionThatAskedForIt() {
        let view = gridView(panes: [pane("w1:p1")])
        let reply = startSearch("needle", in: view)

        XCTAssertNotNil(reply)
        reply?(matchAtRowForty)

        XCTAssertEqual(view.copyMode?.cursor.row, 40)
        XCTAssertEqual(view.selection?.paneID, "w1:p1")
    }

    func testALateSearchReplyDoesNotMoveTheSessionThatReplacedIt() {
        // The reported failure: search in pane A, leave copy mode, enter it in
        // pane B, and A's delayed reply arrives.
        let view = gridView(panes: [pane("w1:p1"), pane("w1:p2")])
        view.focusedPaneFromSnapshot = "w1:p1"
        let replyForPaneA = startSearch("needle", in: view)

        view.exitCopyMode()
        view.focusedPaneFromSnapshot = "w1:p2"
        view.onCopyModeRequest = nil
        view.enterCopyMode()
        let cursorInPaneB = view.copyMode?.cursor

        replyForPaneA?(matchAtRowForty)

        XCTAssertEqual(view.copyMode?.paneID, "w1:p2")
        XCTAssertEqual(
            view.copyMode?.cursor, cursorInPaneB,
            "a result found in another pane moved this one's cursor")
        XCTAssertNil(view.selection, "and replaced its selection")
    }

    func testALateReplyDoesNothingAfterCopyModeIsLeftAltogether() {
        let view = gridView(panes: [pane("w1:p1")])
        let reply = startSearch("needle", in: view)

        view.exitCopyMode()
        reply?(matchAtRowForty)

        XCTAssertNil(view.copyMode, "a reply must not put copy mode back")
        XCTAssertNil(view.selection)
    }

    func testReenteringTheSamePaneIsStillADifferentSession() {
        // The pane id is the same, so nothing but the generation tells these
        // apart.
        let view = gridView(panes: [pane("w1:p1")])
        let reply = startSearch("needle", in: view)

        view.exitCopyMode()
        view.onCopyModeRequest = nil
        view.enterCopyMode()
        let freshCursor = view.copyMode?.cursor

        reply?(matchAtRowForty)

        XCTAssertEqual(
            view.copyMode?.cursor, freshCursor,
            "the new session never asked for this result")
    }

    func testALateStaleReplyDoesNotRetryForASessionThatIsGone() {
        let view = gridView(panes: [pane("w1:p1")])
        var requests = 0
        var reply: ((String) -> Void)?
        view.onCopyModeRequest = { _, _, completion in
            requests += 1
            reply = completion
        }

        view.enterCopyMode(searching: true)
        _ = view.handleCopyModeKey(keystroke("x"))
        _ = view.handleCopyModeKey(keystroke("\r", keyCode: 36))
        XCTAssertEqual(requests, 1)

        view.exitCopyMode()
        reply?(#"{"error":{"code":"stale_content"}}"#)

        XCTAssertEqual(
            requests, 1,
            "retrying asks the server a question whose answer has nowhere to go")
    }

    func testAMotionReplyForAnEndedSessionIsIgnored() {
        let view = gridView(panes: [pane("w1:p1")])
        var reply: ((String) -> Void)?
        view.onCopyModeRequest = { _, _, completion in reply = completion }

        view.enterCopyMode()
        _ = view.handleCopyModeKey(keystroke("w"))
        XCTAssertNotNil(reply, "w is a server-side motion")

        view.exitCopyMode()
        view.onCopyModeRequest = nil
        view.enterCopyMode()
        let freshCursor = view.copyMode?.cursor

        reply?(#"{"result":{"cursor":{"row":40,"col":3}}}"#)

        XCTAssertEqual(view.copyMode?.cursor, freshCursor)
    }
}
