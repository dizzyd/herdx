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

    /// A cursor reply placing it at one column.
    private func cursorAt(row: UInt64, column: Int) -> String {
        #"{"result":{"cursor":{"row":\#(row),"col":\#(column)}}}"#
    }

    /// A reply from a copy-mode session that has ended must not release the
    /// queue of the session now on screen.
    ///
    /// The callback used to clear the in-flight flag and pump the queue before
    /// it checked whose reply it was, so the old session's answer let the new
    /// session's second keystroke run while its own request was still out —
    /// both moving from column 0, and the second press wasted exactly as it
    /// was before any of this queued.
    func testAStaleReplyDoesNotReleaseTheNewSessionsQueue() {
        let view = gridView(panes: [pane("w1:p1")])
        var requests: [String] = []
        var replies: [(String) -> Void] = []
        view.onCopyModeRequest = { request, _, completion in
            requests.append(request)
            replies.append(completion)
        }

        // One session asks for a motion, then goes away.
        view.enterCopyMode()
        _ = view.handleCopyModeKey(keystroke("w"))
        XCTAssertEqual(requests.count, 1)
        view.exitCopyMode()

        // A new session asks for its own, and types another key behind it.
        view.enterCopyMode()
        _ = view.handleCopyModeKey(keystroke("w"))
        XCTAssertEqual(requests.count, 2)
        _ = view.handleCopyModeKey(keystroke("w"))
        XCTAssertEqual(requests.count, 2, "the second press was not held")

        // The dead session answers. Nothing of this one's may move.
        replies[0](cursorAt(row: 5, column: 9))

        XCTAssertEqual(
            requests.count, 2,
            "a reply from a session that had ended let this one's next request out")
        XCTAssertEqual(
            view.copyMode?.cursor.column, 0, "a dead session's reply moved this cursor")

        // And this session's own reply still releases it.
        replies[1](cursorAt(row: 0, column: 4))
        XCTAssertEqual(requests.count, 3, "the held keystroke never ran")
    }

    /// Everything waits for an outstanding request, not just the next motion.
    ///
    /// `l` is computed here from the cursor, so run while `w` was out it moved
    /// from the old cursor and was then overwritten by `w`'s reply: the column
    /// ended one past where `w` *started* rather than one past where it landed.
    func testALocalMoveWaitsForAnOutstandingMotion() {
        let view = gridView(panes: [pane("w1:p1")])
        var replies: [(String) -> Void] = []
        view.onCopyModeRequest = { _, _, completion in replies.append(completion) }

        view.enterCopyMode()
        _ = view.handleCopyModeKey(keystroke("w"))
        _ = view.handleCopyModeKey(keystroke("l"))

        // `l` has not been allowed to move anything yet.
        XCTAssertEqual(view.copyMode?.cursor.column, 0)

        // `w` lands on column 4, and only then does `l` take it to 5.
        replies[0](cursorAt(row: 0, column: 4))
        XCTAssertEqual(
            view.copyMode?.cursor.column, 5,
            "the local move ran against the cursor the motion replaced")
    }

    /// `vwy` must not copy before `w` has extended the selection.
    func testASelectionIsNotCopiedBeforeTheMotionExtendsIt() {
        let view = gridView(panes: [pane("w1:p1")])
        var replies: [(String) -> Void] = []
        view.onCopyModeRequest = { _, _, completion in replies.append(completion) }

        view.enterCopyMode()
        _ = view.handleCopyModeKey(keystroke("v"))
        _ = view.handleCopyModeKey(keystroke("w"))
        _ = view.handleCopyModeKey(keystroke("y"))

        // `y` copies and leaves, so still being in copy mode is the proof it
        // has not run: it is waiting for the selection it would have copied.
        XCTAssertNotNil(view.copyMode, "y copied and left before the motion answered")
        XCTAssertEqual(view.copyMode?.anchor?.column, 0, "the anchor moved early")

        // Once the motion lands, `y` runs against the selection it extended.
        replies[0](cursorAt(row: 0, column: 4))
        XCTAssertNil(view.copyMode, "the held y never ran")
    }

    /// A lost reply must not trap anyone in copy mode, so the keys that leave
    /// are never queued.
    func testEscapeAndQStillWorkWhileARequestIsOutstanding() {
        let view = gridView(panes: [pane("w1:p1")])
        view.onCopyModeRequest = { _, _, _ in }

        view.enterCopyMode()
        _ = view.handleCopyModeKey(keystroke("w"))
        _ = view.handleCopyModeKey(keystroke("q"))
        XCTAssertNil(view.copyMode, "q was queued behind a reply that never came")

        view.enterCopyMode()
        _ = view.handleCopyModeKey(keystroke("w"))
        _ = view.handleCopyModeKey(keystroke("\u{1b}", keyCode: 53))
        XCTAssertNil(view.copyMode, "Esc was queued behind a reply that never came")
    }

    /// Each motion is relative to where the cursor is, and that comes back
    /// from the server. Two presses before the first answer must not both ask
    /// to move from the same place.
    func testRapidMotionsAreAskedOneAtATime() {
        let view = gridView(panes: [pane("w1:p1")])
        var requests: [String] = []
        var replies: [(String) -> Void] = []
        view.onCopyModeRequest = { request, _, completion in
            requests.append(request)
            replies.append(completion)
        }
        view.enterCopyMode()

        _ = view.handleCopyModeKey(keystroke("w"))
        _ = view.handleCopyModeKey(keystroke("w"))

        XCTAssertEqual(requests.count, 1, "the second w went out before the first was answered")

        // The first lands on column 4; the second must start from there.
        replies[0](cursorAt(row: 0, column: 4))
        XCTAssertEqual(view.copyMode?.cursor.column, 4)
        XCTAssertEqual(requests.count, 2, "the queued motion was never sent")
        XCTAssertTrue(
            requests[1].contains("\"col\":4"),
            "the second motion asked to move from where the cursor no longer was: \(requests[1])")

        replies[1](cursorAt(row: 0, column: 8))
        XCTAssertEqual(view.copyMode?.cursor.column, 8)
    }

    /// A reply that carries nothing still has to let the queue move on.
    func testAnUnusableReplyDoesNotStrandTheQueue() {
        let view = gridView(panes: [pane("w1:p1")])
        var replies: [(String) -> Void] = []
        view.onCopyModeRequest = { _, _, completion in replies.append(completion) }
        view.enterCopyMode()

        _ = view.handleCopyModeKey(keystroke("w"))
        _ = view.handleCopyModeKey(keystroke("w"))
        replies[0]("")

        XCTAssertEqual(replies.count, 2, "copy mode stopped moving after one lost reply")
    }

    /// Leaving copy mode drops what was waiting; it belongs to a session that
    /// is gone.
    func testLeavingCopyModeForgetsQueuedMotions() {
        let view = gridView(panes: [pane("w1:p1")])
        var replies: [(String) -> Void] = []
        view.onCopyModeRequest = { _, _, completion in replies.append(completion) }
        view.enterCopyMode()

        _ = view.handleCopyModeKey(keystroke("w"))
        _ = view.handleCopyModeKey(keystroke("w"))
        view.exitCopyMode()
        replies[0](cursorAt(row: 0, column: 4))

        XCTAssertEqual(replies.count, 1, "a motion was sent for a copy mode nobody is in")
        XCTAssertNil(view.copyMode)
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

    /// The reply herdr's own test produces for "alpha beta alpha" searched
    /// forward from column 0: two matches, and the one it went to is the
    /// second.
    private var alphaBetaAlpha: String {
        """
        {"id":"search","result":{"pane_id":"w1:p1","total":2,"current":1,
         "matches":[{"start":{"row":0,"col":0},"end":{"row":0,"col":5}},
                    {"start":{"row":0,"col":11},"end":{"row":0,"col":16}}]}}
        """
    }

    func testTheSearchGoesToTheMatchTheServerChose() {
        let found = TerminalGridView.selectedMatch(fromReply: alphaBetaAlpha)
        XCTAssertEqual(
            found?.start.column, 11,
            "searching forward from column 0 landed back on column 0, so n never moved")
        XCTAssertEqual(found?.end.column, 16)
    }

    func testAMissingCurrentFallsBackToTheFirstMatch() {
        let reply = """
            {"id":"search","result":{"matches":[{"start":{"row":3,"col":2},
             "end":{"row":3,"col":7}}]}}
            """
        XCTAssertEqual(TerminalGridView.selectedMatch(fromReply: reply)?.start.column, 2)
    }

    func testACurrentThatNamesNoMatchIsNotTrusted() {
        let reply = """
            {"id":"search","result":{"current":9,"matches":[{"start":{"row":3,"col":2},
             "end":{"row":3,"col":7}}]}}
            """
        XCTAssertEqual(TerminalGridView.selectedMatch(fromReply: reply)?.start.column, 2)
    }

    func testNoMatchesIsNoMove() {
        XCTAssertNil(
            TerminalGridView.selectedMatch(fromReply: #"{"id":"search","result":{"matches":[]}}"#))
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
