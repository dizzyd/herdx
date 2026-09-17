import AppKit

/// A drag selection inside one pane.
///
/// Points are stored in absolute scrollback coordinates rather than viewport
/// rows, so a selection survives the pane scrolling or new output arriving
/// underneath it — which is exactly what happens while an agent is working.
struct Selection {
    struct Point: Comparable {
        var row: UInt64
        var column: Int

        static func < (a: Point, b: Point) -> Bool {
            a.row == b.row ? a.column < b.column : a.row < b.row
        }
    }

    let paneID: String
    let contentRevision: UInt64
    var anchor: Point
    var cursor: Point

    /// Reading order, top-left first.
    var ordered: (start: Point, end: Point) {
        anchor <= cursor ? (anchor, cursor) : (cursor, anchor)
    }

    var isEmpty: Bool { anchor == cursor }

    /// The selected span on one absolute row, clipped to the pane's width.
    ///
    /// Returns nil when the row lies outside the selection.
    func span(onRow row: UInt64, width: Int) -> Range<Int>? {
        let (start, end) = ordered
        guard row >= start.row, row <= end.row else { return nil }
        let first = row == start.row ? start.column : 0
        // The last row stops at the cursor; earlier rows run to the edge,
        // which is how a terminal selection reads.
        let last = row == end.row ? end.column : width - 1
        guard last >= first else { return nil }
        return first..<min(last + 1, width)
    }

    func readRequest(id: String) -> String? {
        let (start, end) = ordered
        let body: [String: Any] = [
            "id": id,
            "method": "pane.selection.read",
            "params": [
                "pane_id": paneID,
                "anchor": ["row": start.row, "col": start.column],
                "cursor": ["row": end.row, "col": end.column],
                "content_revision": contentRevision,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Selection.Point: Equatable {}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
