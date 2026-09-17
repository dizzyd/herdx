import AppKit
import CHerdrCore

/// Draws the pane surface herdr sends us.
///
/// The server composes one grid for the whole active tab and reports where each
/// pane sits inside it. This view draws that single grid, but every span is
/// routed through its owning pane first, so panes can become real `NSView`s
/// later without changing how surfaces or patches are delivered.
final class TerminalGridView: NSView {
    var session: HerdrSession?
    var theme: Theme = .default
    var onResize: ((Int, Int) -> Void)?
    /// Raised when a click lands in a pane that does not have focus.
    var onFocusPane: ((String) -> Void)?

    private(set) var cellSize: CGSize = .zero
    private let glyphs: GlyphRunDrawer
    private var lastRevision: UInt64 = .max
    /// Last grid size we told the server about, so a live drag does not send a
    /// resize per pixel.
    private var reportedGridSize: (cols: Int, rows: Int)?
    /// Pane geometry from the last surface we drew.
    ///
    /// Cached because resolving it means crossing the FFI boundary and
    /// allocating a string per pane, which is far too much work to repeat for
    /// every mouse-moved and scroll event.
    fileprivate var panes: [PaneView] = []

    /// The focused pane, from the snapshot rather than the surface.
    ///
    /// The snapshot is the authority and arrives before the first surface, so
    /// relying on the surface alone would drop keystrokes typed before the
    /// first paint.
    var focusedPaneFromSnapshot: String?

    fileprivate var focusedPane: String? {
        focusedPaneFromSnapshot ?? panes.first(where: \.focused)?.id
    }

    fileprivate var scrollAccumulator: CGFloat = 0

    /// The active drag selection, if any.
    fileprivate var selection: Selection?
    /// Raised when a selection is copied, with the request to read its text.
    var onReadSelection: ((String) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(pointSize: CGFloat) {
        glyphs = GlyphRunDrawer(pointSize: pointSize)
        cellSize = glyphs.cellSize
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var gridSize: (cols: Int, rows: Int) {
        guard cellSize.width > 0, cellSize.height > 0 else { return (80, 24) }
        return (
            max(Int(bounds.width / cellSize.width), 1),
            max(Int(bounds.height / cellSize.height), 1)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A live resize drag fires this continuously; only the grid size
        // matters to the server, so report it when it actually changes.
        let size = gridSize
        guard reportedGridSize == nil || reportedGridSize! != size else { return }
        reportedGridSize = size
        onResize?(size.cols, size.rows)
    }

    /// Called each tick; only repaints when the surface actually advanced.
    func refreshIfNeeded() {
        guard let session else { return }
        let latest = session.withGrid { (revision: $0.revision, panes: $0.panes) }
        guard let latest, latest.revision != lastRevision else { return }
        lastRevision = latest.revision
        panes = latest.panes
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        theme.background.setFill()
        context.fill(dirtyRect)

        guard let session else { return }
        session.withGrid { grid in
            panes = grid.panes

            // Route by pane so the per-pane seam stays real even with one view.
            if grid.panes.isEmpty {
                drawRegion(grid, CellRect(x: 0, y: 0, width: grid.width, height: grid.height),
                           in: context)
            } else {
                for pane in grid.panes {
                    drawRegion(grid, pane.rect, in: context)
                }
            }
            drawSelection(grid, in: context)
            drawCursor(grid, in: context)
        }
    }

    /// Paints the selection as a translucent overlay.
    ///
    /// Drawn after the text so it tints rather than hides it; a terminal
    /// selection has to stay readable.
    private func drawSelection(_ grid: GridView, in context: CGContext) {
        guard let selection, !selection.isEmpty,
            let pane = panes.first(where: { $0.id == selection.paneID })
        else { return }

        context.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).cgColor)
        for viewportRow in 0..<pane.inner.height {
            let absolute = pane.viewportTopRow + UInt64(viewportRow)
            guard let span = selection.span(onRow: absolute, width: pane.inner.width) else {
                continue
            }
            context.fill(
                CGRect(
                    x: CGFloat(pane.inner.x + span.lowerBound) * cellSize.width,
                    y: CGFloat(pane.inner.y + viewportRow) * cellSize.height,
                    width: CGFloat(span.count) * cellSize.width,
                    height: cellSize.height))
        }
    }

    private func drawRegion(_ grid: GridView, _ region: CellRect, in context: CGContext) {
        let maxY = min(region.y + region.height, grid.height)
        let maxX = min(region.x + region.width, grid.width)
        guard maxX > region.x, maxY > region.y else { return }

        for row in region.y..<maxY {
            // Runs of identical background paint in one fill.
            var runStart = region.x
            var runColor: NSColor?

            for col in region.x..<maxX {
                let cell = grid.cells[row * grid.width + col]
                let style = CellStyle(rawValue: cell.modifier)
                let bg = resolvedBackground(cell, style: style)

                if bg != runColor {
                    flushBackground(runColor, from: runStart, to: col, row: row, in: context)
                    runStart = col
                    runColor = bg
                }
            }
            flushBackground(runColor, from: runStart, to: maxX, row: row, in: context)

            drawText(grid, row: row, from: region.x, to: maxX, in: context)
        }
    }

    private func resolvedBackground(_ cell: HxCell, style: CellStyle) -> NSColor {
        let bg = PackedColor(cell.bg, theme: theme, isForeground: false)
        let fg = PackedColor(cell.fg, theme: theme, isForeground: true)
        return style.contains(.reversed)
            ? fg.resolved(theme: theme, isForeground: true)
            : bg.resolved(theme: theme, isForeground: false)
    }

    private func flushBackground(
        _ color: NSColor?, from startCol: Int, to endCol: Int, row: Int, in context: CGContext
    ) {
        guard let color, endCol > startCol, color != theme.background else { return }
        color.setFill()
        context.fill(
            CGRect(
                x: CGFloat(startCol) * cellSize.width,
                y: CGFloat(row) * cellSize.height,
                width: CGFloat(endCol - startCol) * cellSize.width,
                height: cellSize.height))
    }

    /// Draws one row as runs of identical style.
    ///
    /// Terminal output is overwhelmingly long stretches of one style, so
    /// batching collapses a row into a handful of draws instead of one per
    /// column.
    private func drawText(
        _ grid: GridView, row: Int, from startCol: Int, to endCol: Int, in context: CGContext
    ) {
        var runCells: [(column: Int, text: String)] = []
        var runStyle: (fg: UInt32, bg: UInt32, modifier: UInt16)?

        func flush() {
            guard let style = runStyle, !runCells.isEmpty else {
                runCells.removeAll(keepingCapacity: true)
                return
            }
            paint(runCells, row: row, style: style, in: context)
            runCells.removeAll(keepingCapacity: true)
        }

        for col in startCol..<endCol {
            let cell = grid.cells[row * grid.width + col]
            let style = CellStyle(rawValue: cell.modifier)
            if style.contains(.hidden) { continue }

            let text = grid.glyph(cell)
            if text.isEmpty || text == " " { continue }

            let key = (fg: cell.fg, bg: cell.bg, modifier: cell.modifier)
            if runStyle == nil || runStyle! != key {
                flush()
                runStyle = key
            }
            runCells.append((column: col, text: text))
        }
        flush()
    }

    private func paint(
        _ cells: [(column: Int, text: String)],
        row: Int,
        style key: (fg: UInt32, bg: UInt32, modifier: UInt16),
        in context: CGContext
    ) {
        let style = CellStyle(rawValue: key.modifier)
        let fg = PackedColor(key.fg, theme: theme, isForeground: true)
        let bg = PackedColor(key.bg, theme: theme, isForeground: false)
        var color =
            style.contains(.reversed)
            ? bg.resolved(theme: theme, isForeground: false)
            : fg.resolved(theme: theme, isForeground: true)
        if style.contains(.dim) { color = color.withAlphaComponent(0.55) }

        let font = glyphs.font(bold: style.contains(.bold), italic: style.contains(.italic))
        let fallback = glyphs.draw(
            cells: cells, row: row, font: font, color: color, in: context)

        // Clusters and glyphs missing from the font go through AppKit so its
        // font fallback applies — emoji and box drawing mostly.
        if !fallback.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color,
            ]
            for cell in fallback {
                NSAttributedString(string: cell.text, attributes: attributes).draw(
                    at: CGPoint(
                        x: CGFloat(cell.column) * cellSize.width,
                        y: CGFloat(row) * cellSize.height))
            }
        }

        if style.contains(.underlined) || style.contains(.crossedOut) {
            decorate(cells, row: row, style: style, color: color, in: context)
        }
    }

    /// Underlines and strikethroughs, drawn as spans rather than per glyph.
    private func decorate(
        _ cells: [(column: Int, text: String)],
        row: Int,
        style: CellStyle,
        color: NSColor,
        in context: CGContext
    ) {
        guard let first = cells.first, let last = cells.last else { return }
        let x = CGFloat(first.column) * cellSize.width
        let width = CGFloat(last.column - first.column + 1) * cellSize.width
        let top = CGFloat(row) * cellSize.height
        context.setFillColor(color.cgColor)
        if style.contains(.underlined) {
            context.fill(CGRect(x: x, y: top + cellSize.height - 1, width: width, height: 1))
        }
        if style.contains(.crossedOut) {
            context.fill(
                CGRect(x: x, y: top + cellSize.height / 2, width: width, height: 1))
        }
    }

    private func drawCursor(_ grid: GridView, in context: CGContext) {
        guard grid.cursor.visible, window?.isKeyWindow == true else { return }
        let rect = CGRect(
            x: CGFloat(grid.cursor.x) * cellSize.width,
            y: CGFloat(grid.cursor.y) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height)
        theme.foreground.withAlphaComponent(0.75).setFill()
        // DECSCUSR: 3/4 underline, 5/6 bar, everything else block.
        switch grid.cursor.shape {
        case 3, 4:
            context.fill(
                CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
        case 5, 6:
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
        default:
            context.fill(rect)
        }
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        guard let session, let pane = focusedPane else { return }
        guard let mapped = KeyMapper.map(event) else {
            // Anything we do not classify travels as committed text, which lets
            // IME and dead keys work without us re-implementing composition.
            if let text = event.characters, !text.isEmpty {
                session.send(text: text, to: pane)
            }
            return
        }
        session.send(
            key: mapped.kind, codepoint: mapped.codepoint, modifiers: mapped.modifiers, to: pane)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }
}

// MARK: - Mouse

extension TerminalGridView {
    /// Which pane covers a point, and where inside the surface it landed.
    private func hit(_ event: NSEvent) -> (pane: PaneView, column: Int, row: Int)? {
        guard cellSize.width > 0, cellSize.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let column = Int(point.x / cellSize.width)
        let row = Int(point.y / cellSize.height)

        let pane = panes.first {
            column >= $0.rect.x && column < $0.rect.x + $0.rect.width
                && row >= $0.rect.y && row < $0.rect.y + $0.rect.height
        }
        guard let pane else { return nil }
        return (pane, column, row)
    }

    private func mouseEvent(
        _ event: NSEvent, kind: UInt16, button: UInt8, column: Int, row: Int, lines: Int = 0
    ) -> HxMouseEvent {
        let point = convert(event.locationInWindow, from: nil)
        return HxMouseEvent(
            kind: kind,
            button: button,
            column: UInt16(max(column, 0)),
            row: UInt16(max(row, 0)),
            pixel_x: UInt32(max(point.x, 0)),
            pixel_y: UInt32(max(point.y, 0)),
            modifiers: KeyMapper.modifiers(event.modifierFlags),
            lines: UInt16(max(lines, 0)))
    }

    private func send(_ event: NSEvent, kind: UInt16, button: UInt8) {
        guard let session, let hit = hit(event) else { return }
        // Clicking an unfocused pane focuses it. herdr leaves this to the
        // client shell, which is us.
        if kind == UInt16(HX_MOUSE_DOWN), !hit.pane.focused {
            onFocusPane?(hit.pane.id)
        }
        session.send(
            mouse: mouseEvent(event, kind: kind, button: button, column: hit.column, row: hit.row),
            to: hit.pane.id)
    }

    /// Whether a drag selects text rather than going to the pane's program.
    ///
    /// A program that asked for mouse reporting owns the drag, which is what
    /// makes editors and pagers work. Holding option overrides that, the
    /// convention every terminal uses for selecting out of such a program.
    private func dragSelectsText(_ event: NSEvent, pane: PaneView) -> Bool {
        !pane.mouseReporting || event.modifierFlags.contains(.option)
    }

    /// Converts a hit into an absolute scrollback point within the pane.
    private func point(in pane: PaneView, column: Int, row: Int) -> Selection.Point {
        let localColumn = (column - pane.inner.x).clamped(to: 0...max(pane.inner.width - 1, 0))
        let localRow = (row - pane.inner.y).clamped(to: 0...max(pane.inner.height - 1, 0))
        return Selection.Point(
            row: pane.viewportTopRow + UInt64(localRow), column: localColumn)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let hit = hit(event) else { return }

        if dragSelectsText(event, pane: hit.pane) {
            switch event.clickCount {
            case 2: selectWord(in: hit.pane, column: hit.column, row: hit.row)
            case 3...: selectLine(in: hit.pane, row: hit.row)
            default:
                let start = point(in: hit.pane, column: hit.column, row: hit.row)
                selection = Selection(
                    paneID: hit.pane.id,
                    contentRevision: hit.pane.contentRevision,
                    anchor: start,
                    cursor: start)
            }
            needsDisplay = true
            if !hit.pane.focused { onFocusPane?(hit.pane.id) }
            return
        }
        send(event, kind: UInt16(HX_MOUSE_DOWN), button: UInt8(HX_BUTTON_LEFT))
    }

    override func mouseUp(with event: NSEvent) {
        if selection != nil {
            // An empty selection is just a click; clear it so a stray highlight
            // does not linger.
            if selection?.isEmpty == true { selection = nil; needsDisplay = true }
            return
        }
        send(event, kind: UInt16(HX_MOUSE_UP), button: UInt8(HX_BUTTON_LEFT))
    }

    override func mouseDragged(with event: NSEvent) {
        if selection != nil, let hit = hit(event) {
            selection?.cursor = point(in: hit.pane, column: hit.column, row: hit.row)
            needsDisplay = true
            return
        }
        send(event, kind: UInt16(HX_MOUSE_DRAG), button: UInt8(HX_BUTTON_LEFT))
    }

    /// Characters a double-click treats as part of a word.
    ///
    /// Terminals lean inclusive here because the things worth double-clicking
    /// are paths, URLs and identifiers rather than prose.
    private static let wordCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_-./~:@+=%#?&"))

    private func isWordCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count >= 1 else {
            return false
        }
        return Self.wordCharacters.contains(scalar)
    }

    /// Selects the word under a double-click.
    ///
    /// Only the visible row is inspected: a double-click targets something the
    /// user can see, so the drawn cells are the right source and no round trip
    /// to the server is needed.
    private func selectWord(in pane: PaneView, column: Int, row: Int) {
        guard let session else { return }
        let localRow = row - pane.inner.y
        let localColumn = column - pane.inner.x
        guard localRow >= 0, localRow < pane.inner.height,
            localColumn >= 0, localColumn < pane.inner.width
        else { return }

        let bounds: (start: Int, end: Int)? = session.withGrid { grid in
            func text(at localColumn: Int) -> String {
                let x = pane.inner.x + localColumn
                let y = pane.inner.y + localRow
                guard x < grid.width, y < grid.height else { return " " }
                return grid.glyph(grid.cells[y * grid.width + x])
            }
            guard isWordCharacter(text(at: localColumn)) else { return nil }

            var start = localColumn
            while start > 0, isWordCharacter(text(at: start - 1)) { start -= 1 }
            var end = localColumn
            while end + 1 < pane.inner.width, isWordCharacter(text(at: end + 1)) { end += 1 }
            return (start, end)
        } ?? nil

        guard let bounds else { return }
        let absolute = pane.viewportTopRow + UInt64(localRow)
        selection = Selection(
            paneID: pane.id,
            contentRevision: pane.contentRevision,
            anchor: Selection.Point(row: absolute, column: bounds.start),
            cursor: Selection.Point(row: absolute, column: bounds.end))
    }

    private func selectLine(in pane: PaneView, row: Int) {
        let localRow = (row - pane.inner.y).clamped(to: 0...max(pane.inner.height - 1, 0))
        let absolute = pane.viewportTopRow + UInt64(localRow)
        selection = Selection(
            paneID: pane.id,
            contentRevision: pane.contentRevision,
            anchor: Selection.Point(row: absolute, column: 0),
            cursor: Selection.Point(row: absolute, column: max(pane.inner.width - 1, 0)))
    }

    /// Copies the selection by asking the server for its text.
    ///
    /// The grid only holds what is on screen, and a selection can cover
    /// scrollback that was never rendered, so the text has to come from the
    /// pane rather than from the cells we drew.
    @objc func copy(_ sender: Any?) {
        guard let selection, !selection.isEmpty,
            let request = selection.readRequest(id: "selection-\(UUID().uuidString)")
        else { return }
        onReadSelection?(request)
    }

    @objc func paste(_ sender: Any?) {
        guard let session, let pane = focusedPane,
            let text = NSPasteboard.general.string(forType: .string), !text.isEmpty
        else { return }
        session.send(paste: text, to: pane)
    }

    override func selectAll(_ sender: Any?) {
        guard let pane = panes.first(where: { $0.id == focusedPane }) else { return }
        selection = Selection(
            paneID: pane.id,
            contentRevision: pane.contentRevision,
            anchor: Selection.Point(row: 0, column: 0),
            cursor: Selection.Point(
                row: pane.viewportTopRow + UInt64(max(pane.inner.height - 1, 0)),
                column: max(pane.inner.width - 1, 0)))
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        send(event, kind: UInt16(HX_MOUSE_DOWN), button: UInt8(HX_BUTTON_RIGHT))
    }

    override func rightMouseUp(with event: NSEvent) {
        send(event, kind: UInt16(HX_MOUSE_UP), button: UInt8(HX_BUTTON_RIGHT))
    }

    override func otherMouseDown(with event: NSEvent) {
        send(event, kind: UInt16(HX_MOUSE_DOWN), button: UInt8(HX_BUTTON_MIDDLE))
    }

    override func otherMouseUp(with event: NSEvent) {
        send(event, kind: UInt16(HX_MOUSE_UP), button: UInt8(HX_BUTTON_MIDDLE))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let session, let hit = hit(event) else { return }

        // Trackpads report fractional pixel deltas; the protocol counts rows, so
        // accumulate and only send whole ones. Otherwise a slow drag scrolls
        // nothing at all, or a fast one scrolls wildly.
        let delta: CGFloat
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY
            delta = (scrollAccumulator / cellSize.height).rounded(.towardZero)
            scrollAccumulator -= delta * cellSize.height
        } else {
            delta = event.scrollingDeltaY
        }
        guard delta != 0 else { return }

        // A natural-scrolling gesture reports positive deltaY when content
        // should move down, which is a scroll *up* through history.
        let kind = delta > 0 ? HX_MOUSE_SCROLL_UP : HX_MOUSE_SCROLL_DOWN
        session.send(
            mouse: mouseEvent(
                event, kind: UInt16(kind), button: UInt8(HX_BUTTON_LEFT),
                column: hit.column, row: hit.row, lines: Int(abs(delta))),
            to: hit.pane.id)
    }
}
