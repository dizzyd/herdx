import XCTest

@testable import HerdX

/// Selection endpoints are inclusive, which makes a one-cell selection and an
/// undragged click the same pair of coordinates.
final class SelectionTests: XCTestCase {
    private func point(_ row: UInt64, _ column: Int) -> Selection.Point {
        Selection.Point(row: row, column: column)
    }

    private func selection(
        from anchor: Selection.Point,
        to cursor: Selection.Point,
        origin: Selection.Origin
    ) -> Selection {
        Selection(paneID: "w1:p1", anchor: anchor, cursor: cursor, origin: origin)
    }

    func testAClickThatHasNotMovedSelectsNothing() {
        let click = selection(from: point(4, 2), to: point(4, 2), origin: .click)
        XCTAssertTrue(click.isEmpty)
    }

    func testDoubleClickingAOneCharacterWordSelectsThatCharacter() {
        // What selectWord produces for a word one cell wide: start == end.
        let word = selection(from: point(4, 2), to: point(4, 2), origin: .span)

        XCTAssertFalse(word.isEmpty, "a one-character word is something to copy")
        XCTAssertEqual(
            word.span(onRow: 4, width: 80), 2..<3,
            "the span was always right; it was isEmpty that hid it")
    }

    func testDraggingAwayFromTheAnchorMakesAClickASelection() {
        var drag = selection(from: point(4, 2), to: point(4, 2), origin: .click)
        XCTAssertTrue(drag.isEmpty)

        drag.extend(to: point(4, 6))

        XCTAssertFalse(drag.isEmpty)
        XCTAssertEqual(drag.span(onRow: 4, width: 80), 2..<7)
    }

    func testAPressThatWobblesWithinOneCellIsStillAClick() {
        // mouseDragged fires for movement too small to leave the cell, and that
        // must not leave a highlight behind after what felt like a click.
        var press = selection(from: point(4, 2), to: point(4, 2), origin: .click)

        press.extend(to: point(4, 2))

        XCTAssertTrue(press.isEmpty)
    }

    func testDraggingBackToTheAnchorKeepsTheOneCellSelection() {
        var drag = selection(from: point(4, 2), to: point(4, 2), origin: .click)
        drag.extend(to: point(4, 9))
        drag.extend(to: point(4, 2))

        XCTAssertFalse(drag.isEmpty, "the drag happened; the user chose that cell")
        XCTAssertEqual(drag.span(onRow: 4, width: 80), 2..<3)
    }

    func testAOneCellSelectionProducesAReadRequest() {
        let word = selection(from: point(7, 5), to: point(7, 5), origin: .span)
        guard let request = word.readRequest(id: "selection-1"),
            let body = try? JSONSerialization.jsonObject(
                with: Data(request.utf8)) as? [String: Any],
            let params = body["params"] as? [String: Any]
        else { return XCTFail("a one-cell selection should still be readable") }

        XCTAssertEqual(params["pane_id"] as? String, "w1:p1")
        XCTAssertEqual((params["anchor"] as? [String: Any])?["col"] as? Int, 5)
        XCTAssertEqual((params["cursor"] as? [String: Any])?["col"] as? Int, 5)
    }

    func testSelectionsSpanningRowsRunToTheEdge() {
        let across = selection(from: point(3, 70), to: point(5, 4), origin: .span)

        XCTAssertEqual(across.span(onRow: 3, width: 80), 70..<80)
        XCTAssertEqual(across.span(onRow: 4, width: 80), 0..<80)
        XCTAssertEqual(across.span(onRow: 5, width: 80), 0..<5)
        XCTAssertNil(across.span(onRow: 6, width: 80))
    }
}
