import AppKit
import CHerdrCore
import XCTest

@testable import HerdX

/// What a press is doing is decided when it goes down. Working it out
/// afterwards from whatever state is lying around gets it wrong as soon as two
/// panes are involved.
@MainActor
final class MouseGestureTests: XCTestCase {
    private func pane(
        _ id: String, x: Int, width: Int, reporting: Bool = false, top: UInt64 = 0
    ) -> PaneView {
        let rect = CellRect(x: x, y: 0, width: width, height: 10)
        return PaneView(
            id: id, rect: rect, inner: rect, focused: true,
            alternateScreen: false, mouseReporting: reporting,
            scrollOffsetFromBottom: top, scrollMaxOffsetFromBottom: top,
            contentRevision: 2)
    }

    private func view(_ panes: [PaneView]) -> TerminalGridView {
        let view = TerminalGridView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular), lineHeight: 1)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        view.setPanesForTesting(panes)
        return view
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func keystroke(_ characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    /// The middle of a cell, as an event carries it.
    ///
    /// An event's location is in window coordinates, and the grid is flipped,
    /// so the y the view will work with is measured from the other end.
    private func at(column: Int, row: Int = 0, in view: TerminalGridView) -> NSPoint {
        let inView = view.contentOrigin.y + view.cellSize.height * (CGFloat(row) + 0.5)
        return NSPoint(
            x: view.contentOrigin.x + view.cellSize.width * (CGFloat(column) + 0.5),
            y: view.bounds.height - inView)
    }

    /// A program that asked for mouse reporting must see the whole click.
    func testAClickIntoAReportingPaneIsNotSwallowedByAnOldSelection() {
        let left = pane("w1:p1", x: 0, width: 20)
        let right = pane("w1:p2", x: 20, width: 20, reporting: true)
        let view = self.view([left, right])

        // A selection made earlier, in the other pane, and left standing.
        view.mouseDown(with: event(.leftMouseDown, at: at(column: 2, in: view)))
        view.mouseDragged(with: event(.leftMouseDragged, at: at(column: 8, in: view)))
        view.mouseUp(with: event(.leftMouseUp, at: at(column: 8, in: view)))
        XCTAssertNotNil(view.selection, "the fixture needs a selection left over")

        var reported: [(UInt16, String)] = []
        view.mouseReportForTesting = { kind, pane, _ in reported.append((kind, pane)) }

        view.mouseDown(with: event(.leftMouseDown, at: at(column: 25, in: view)))
        view.mouseDragged(with: event(.leftMouseDragged, at: at(column: 27, in: view)))
        view.mouseUp(with: event(.leftMouseUp, at: at(column: 27, in: view)))

        XCTAssertEqual(
            reported.map(\.0),
            [UInt16(HX_MOUSE_DOWN), UInt16(HX_MOUSE_DRAG), UInt16(HX_MOUSE_UP)],
            "the program saw a button go down and never come up")
        XCTAssertTrue(reported.allSatisfy { $0.1 == "w1:p2" })
    }

    /// Select-all over a program that owns the mouse used to be permanent: its
    /// clicks go to the program, and nothing else cleared the highlight.
    func testAClickTheProgramReceivesDropsTheSelection() {
        let only = pane("w1:p1", x: 0, width: 20, reporting: true)
        let view = self.view([only])

        view.selectAll(nil)
        XCTAssertNotNil(view.selection, "the fixture needs a selection")

        var reported: [(UInt16, String)] = []
        view.mouseReportForTesting = { kind, pane, _ in reported.append((kind, pane)) }

        view.mouseDown(with: event(.leftMouseDown, at: at(column: 4, in: view)))
        view.mouseUp(with: event(.leftMouseUp, at: at(column: 4, in: view)))

        XCTAssertNil(view.selection)
        XCTAssertEqual(
            reported.map(\.0), [UInt16(HX_MOUSE_DOWN), UInt16(HX_MOUSE_UP)],
            "dismissing the selection must not cost the program its click")
        XCTAssertTrue(reported.allSatisfy { $0.1 == "w1:p1" })
    }

    /// Clearing only copy mode's highlight left its anchor live: `y` copied
    /// cells nobody could see, and the next motion painted them back.
    func testAClickTheProgramReceivesLeavesCopyMode() throws {
        let view = self.view([pane("w1:p1", x: 0, width: 20, reporting: true)])
        var replies: [(String) -> Void] = []
        view.onCopyModeRequest = { _, _, completion in replies.append(completion) }
        var reads = 0
        view.onReadSelection = { _ in reads += 1 }

        view.enterCopyMode()
        _ = view.handleCopyModeKey(keystroke("v"))
        _ = view.handleCopyModeKey(keystroke("w"))
        XCTAssertNotNil(view.copyMode?.anchor, "the fixture needs a copy-mode selection")
        XCTAssertEqual(replies.count, 1, "the fixture needs a motion in flight")

        view.mouseDown(with: event(.leftMouseDown, at: at(column: 4, in: view)))
        view.mouseUp(with: event(.leftMouseUp, at: at(column: 4, in: view)))

        XCTAssertNil(view.copyMode)
        XCTAssertNil(view.selection)

        let reply = try XCTUnwrap(replies.first)
        reply(#"{"result":{"cursor":{"row":0,"col":4}}}"#)
        XCTAssertNil(view.selection, "a late motion reply painted the highlight back")
        XCTAssertNil(view.copyMode)

        _ = view.handleCopyModeKey(keystroke("y"))
        view.copy(nil)
        XCTAssertEqual(reads, 0, "something was copied after the selection was dismissed")
    }

    /// A drag that wanders into the neighbour still belongs to the pane it
    /// started in, and must be measured against that one.
    func testADragIntoTheNeighbourStaysInItsOwnPane() {
        let left = pane("w1:p1", x: 0, width: 20, top: 0)
        // A different scrollback position, so measuring against the wrong pane
        // shows up as a row rather than only as a column.
        let right = pane("w1:p2", x: 20, width: 20, top: 500)
        let view = self.view([left, right])

        view.mouseDown(with: event(.leftMouseDown, at: at(column: 2, in: view)))
        view.mouseDragged(with: event(.leftMouseDragged, at: at(column: 30, in: view)))

        XCTAssertEqual(view.selection?.paneID, "w1:p1")
        let cursor = try? XCTUnwrap(view.selection?.cursor)
        XCTAssertEqual(
            cursor?.row, left.viewportTopRow,
            "the drag was measured against the neighbour's scrollback")
        XCTAssertEqual(
            cursor?.column, left.inner.width - 1,
            "a drag past the edge should stop at it, not report the other pane's column")
    }

    /// The press that began in a reporting pane keeps reporting even if the
    /// pointer leaves it.
    /// A drag that leaves its pane is still that pane's drag.
    ///
    /// Reported kinds alone are not enough — they were right while every event
    /// after the press was hit-tested afresh, which sent the neighbour a drag
    /// it never started and left the pane that *did* start it waiting for a
    /// release that went somewhere else. A button put down has to come back up
    /// in the same place, so the target is what this asserts.
    func testAReportingDragThatLeavesThePaneStaysWithThatPane() {
        let left = pane("w1:p1", x: 0, width: 20, reporting: true)
        let right = pane("w1:p2", x: 20, width: 20, reporting: true)
        let view = self.view([left, right])

        var reported: [(UInt16, String)] = []
        view.mouseReportForTesting = { kind, pane, _ in reported.append((kind, pane)) }

        view.mouseDown(with: event(.leftMouseDown, at: at(column: 25, in: view)))
        view.mouseDragged(with: event(.leftMouseDragged, at: at(column: 5, in: view)))
        view.mouseUp(with: event(.leftMouseUp, at: at(column: 5, in: view)))

        XCTAssertEqual(
            reported.map(\.0),
            [UInt16(HX_MOUSE_DOWN), UInt16(HX_MOUSE_DRAG), UInt16(HX_MOUSE_UP)])
        XCTAssertEqual(
            reported.map(\.1), ["w1:p2", "w1:p2", "w1:p2"],
            "the gesture wandered into the pane under the pointer")
        XCTAssertNil(view.selection, "a reporting press must not start a selection")
    }

    /// And a release outside every pane still reaches the pane that was
    /// pressed, rather than being dropped — which left a button down for good.
    func testAReleaseOutsideEveryPaneStillReachesTheOwner() {
        let only = pane("w1:p1", x: 0, width: 10, reporting: true)
        let view = self.view([only])

        var reported: [(UInt16, String)] = []
        view.mouseReportForTesting = { kind, pane, _ in reported.append((kind, pane)) }

        view.mouseDown(with: event(.leftMouseDown, at: at(column: 5, in: view)))
        // Well past the pane's last column, where nothing is.
        view.mouseUp(with: event(.leftMouseUp, at: at(column: 40, in: view)))

        XCTAssertEqual(
            reported.map(\.0), [UInt16(HX_MOUSE_DOWN), UInt16(HX_MOUSE_UP)],
            "the release was dropped, so the program still has the button down")
        XCTAssertEqual(reported.map(\.1), ["w1:p1", "w1:p1"])
    }

    /// The coordinates a program actually receives.
    ///
    /// The server hands the position straight to the addressed pane's
    /// emulator without subtracting anything, so surface coordinates told a
    /// pane twenty columns across that every click was twenty columns further
    /// right than it was.
    func testAReportIsInThePanesOwnCoordinates() throws {
        let right = pane("w1:p2", x: 20, width: 20, reporting: true)
        let view = self.view([pane("w1:p1", x: 0, width: 20), right])

        var reports: [HxMouseEvent] = []
        view.mouseReportForTesting = { _, _, report in reports.append(report) }

        // Surface column 25 is the pane's own column 5.
        view.mouseDown(with: event(.leftMouseDown, at: at(column: 25, row: 3, in: view)))

        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.column, 5, "a surface column reached the program")
        XCTAssertEqual(report.row, 3)
    }

    /// A drag past the pane's edge reports the edge, not a cell outside it.
    /// herdr clamps into `inner_rect` for the same reason.
    func testADragPastTheEdgeReportsTheEdge() throws {
        let left = pane("w1:p1", x: 0, width: 20, reporting: true)
        let view = self.view([left, pane("w1:p2", x: 20, width: 20)])

        var reports: [HxMouseEvent] = []
        view.mouseReportForTesting = { _, _, report in reports.append(report) }

        view.mouseDown(with: event(.leftMouseDown, at: at(column: 5, in: view)))
        view.mouseDragged(with: event(.leftMouseDragged, at: at(column: 35, in: view)))

        let drag = try XCTUnwrap(reports.last)
        XCTAssertEqual(drag.column, 19, "the report left the pane it belongs to")
    }

    /// A press and its release are one thing to the program receiving them.
    ///
    /// The right and middle buttons each hit-tested independently, so a press
    /// in one pane and a release in another sent an unmatched pair to two
    /// programs: one left holding a button that never comes up, the other
    /// handed a release it never asked for.
    func testARightClickReleasesInThePaneItWasPressedIn() {
        let left = pane("w1:p1", x: 0, width: 20, reporting: true)
        let right = pane("w1:p2", x: 20, width: 20, reporting: true)
        let view = self.view([left, right])

        var reported: [(UInt16, String)] = []
        view.mouseReportForTesting = { kind, pane, _ in reported.append((kind, pane)) }

        view.rightMouseDown(with: event(.rightMouseDown, at: at(column: 25, in: view)))
        view.rightMouseUp(with: event(.rightMouseUp, at: at(column: 5, in: view)))

        XCTAssertEqual(
            reported.map(\.1), ["w1:p2", "w1:p2"],
            "the release went to the pane under the pointer, not the one pressed")
    }

    func testAMiddleClickReleasesInThePaneItWasPressedIn() {
        let view = self.view([
            pane("w1:p1", x: 0, width: 20, reporting: true),
            pane("w1:p2", x: 20, width: 20, reporting: true),
        ])
        var reported: [(UInt16, String)] = []
        view.mouseReportForTesting = { kind, pane, _ in reported.append((kind, pane)) }

        view.otherMouseDown(with: event(.otherMouseDown, at: at(column: 5, in: view)))
        view.otherMouseUp(with: event(.otherMouseUp, at: at(column: 25, in: view)))

        XCTAssertEqual(reported.map(\.1), ["w1:p1", "w1:p1"])
    }

    /// A release with no press of ours is not ours to invent. It happens — a
    /// click that only brought the window forward — and hit-testing it hands
    /// a program a release it never asked for.
    func testAReleaseWithNoPressIsNotSent() {
        let view = self.view([pane("w1:p1", x: 0, width: 20, reporting: true)])
        var reported: [UInt16] = []
        view.mouseReportForTesting = { kind, _, _ in reported.append(kind) }

        view.rightMouseUp(with: event(.rightMouseUp, at: at(column: 5, in: view)))
        view.mouseUp(with: event(.leftMouseUp, at: at(column: 5, in: view)))

        XCTAssertTrue(reported.isEmpty, "a release was invented: \(reported)")
    }

    /// Switching machines under a held button leaves the owner on a server
    /// that is no longer there. The release belongs to nobody still present,
    /// and must not be aimed at whatever has taken that part of the screen.
    func testAHeldButtonIsNotReleasedOntoAReplacementPane() {
        let view = self.view([pane("w1:p1", x: 0, width: 20, reporting: true)])
        var reported: [(UInt16, String)] = []
        view.mouseReportForTesting = { kind, pane, _ in reported.append((kind, pane)) }

        view.mouseDown(with: event(.leftMouseDown, at: at(column: 5, in: view)))
        XCTAssertEqual(reported.count, 1)

        // The machine changes: the surface goes, and a pane with the same id
        // on the new server takes its place.
        view.forgetSurface()
        view.setPanesForTesting([pane("w1:p1", x: 0, width: 20, reporting: true)])
        view.mouseUp(with: event(.leftMouseUp, at: at(column: 5, in: view)))

        XCTAssertEqual(
            reported.count, 1,
            "the release was delivered to a pane on another machine that happens "
                + "to share an id")
    }

    /// A pixel-mouse program scales against the geometry it is sent, so the
    /// pane's size is the only one that describes it.
    func testAReportCarriesThePanesOwnGeometry() throws {
        let right = pane("w1:p2", x: 20, width: 20, reporting: true)
        let view = self.view([pane("w1:p1", x: 0, width: 20), right])

        var reports: [HxMouseEvent] = []
        view.mouseReportForTesting = { _, _, report in reports.append(report) }

        view.mouseDown(with: event(.leftMouseDown, at: at(column: 25, in: view)))

        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.cols, 20, "the whole surface's width was sent")
        XCTAssertEqual(report.rows, 10)
        XCTAssertEqual(report.width_px, UInt32(20 * view.cellSize.width))
        // Pixels against the pane's origin, like the cells.
        XCTAssertLessThan(report.pixel_x, report.width_px)
    }
}
