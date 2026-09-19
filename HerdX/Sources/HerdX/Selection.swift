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

    /// Whether this selection covers cells, or only marks where a click landed.
    ///
    /// Endpoints are inclusive, so a one-character word is a selection whose
    /// anchor and cursor are the same cell — by coordinates alone
    /// indistinguishable from a press that has not been dragged anywhere. The
    /// difference is not in the geometry but in how the selection was made, so
    /// that is what gets recorded.
    enum Origin {
        /// A press, so far. Nothing is selected until it is dragged.
        case click
        /// A span chosen outright: a drag, a double-click, a triple-click.
        case span
    }

    let paneID: String
    var anchor: Point
    var cursor: Point
    var origin: Origin = .span

    /// Reading order, top-left first.
    var ordered: (start: Point, end: Point) {
        anchor <= cursor ? (anchor, cursor) : (cursor, anchor)
    }

    /// Whether there is nothing here to highlight or copy.
    ///
    /// A single cell is not nothing: double-clicking a one-character word
    /// selects it, and that used to produce no highlight and copy nothing.
    var isEmpty: Bool { origin == .click && anchor == cursor }

    /// Records that the cursor has been dragged away from where it started,
    /// which turns a press into a selection.
    mutating func extend(to point: Point) {
        cursor = point
        if point != anchor {
            origin = .span
        }
    }

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

    /// A request to read this selection's text.
    ///
    /// `content_revision` is deliberately omitted. The server rejects a
    /// revision that no longer matches *or* that is odd, which is how it marks
    /// a pane mid-update — so pinning it means a copy fails whenever output is
    /// flowing, which in an agent session is most of the time. herdr's own
    /// client does the same for live selections: output arriving between the
    /// frame you selected on and the read must not reject the copy.
    func readRequest(id: String) -> String? {
        let (start, end) = ordered
        let body: [String: Any] = [
            "id": id,
            "method": "pane.selection.read",
            "params": [
                "pane_id": paneID,
                "anchor": ["row": start.row, "col": start.column],
                "cursor": ["row": end.row, "col": end.column],
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
