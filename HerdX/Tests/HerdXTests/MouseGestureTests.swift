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
        view.mouseReportForTesting = { reported.append(($0, $1)) }

        view.mouseDown(with: event(.leftMouseDown, at: at(column: 25, in: view)))
        view.mouseDragged(with: event(.leftMouseDragged, at: at(column: 27, in: view)))
        view.mouseUp(with: event(.leftMouseUp, at: at(column: 27, in: view)))

        XCTAssertEqual(
            reported.map(\.0),
            [UInt16(HX_MOUSE_DOWN), UInt16(HX_MOUSE_DRAG), UInt16(HX_MOUSE_UP)],
            "the program saw a button go down and never come up")
        XCTAssertTrue(reported.allSatisfy { $0.1 == "w1:p2" })
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
    func testAReportingDragThatLeavesThePaneIsStillReported() {
        let left = pane("w1:p1", x: 0, width: 20)
        let right = pane("w1:p2", x: 20, width: 20, reporting: true)
        let view = self.view([left, right])

        var reported: [UInt16] = []
        view.mouseReportForTesting = { kind, _ in reported.append(kind) }

        view.mouseDown(with: event(.leftMouseDown, at: at(column: 25, in: view)))
        view.mouseDragged(with: event(.leftMouseDragged, at: at(column: 5, in: view)))
        view.mouseUp(with: event(.leftMouseUp, at: at(column: 5, in: view)))

        XCTAssertEqual(
            reported, [UInt16(HX_MOUSE_DOWN), UInt16(HX_MOUSE_DRAG), UInt16(HX_MOUSE_UP)])
        XCTAssertNil(view.selection, "a reporting press must not start a selection")
    }
}
