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
    /// Cached pane colours are resolved against the theme, so they go stale
    /// with it.
    var theme: Theme = .dark {
        didSet { recomputePaneBackgrounds() }
    }
    /// The chrome the frame and rules are drawn from, so the terminal's edges
    /// match the sidebar and tabs rather than the system's accent alone.
    var chrome = Chrome(theme: .dark)
    var onResize: ((Int, Int) -> Void)?
    /// Raised when the colour the panes are actually painted in changes.
    ///
    /// The configured background is only a default: a program that sets its own
    /// is what you are really looking at, and the chrome should follow that
    /// rather than a preference the screen is not obeying.
    var onBackgroundChanged: ((NSColor) -> Void)?
    /// Raised when a click lands in a pane that does not have focus.
    var onFocusPane: ((String) -> Void)?

    private(set) var cellSize: CGSize = .zero
    /// Space between a pane's border and its text.
    ///
    /// Applied once as a translation when drawing, and subtracted again when
    /// hit-testing, so every cell-to-point conversion stays in plain cell
    /// coordinates. It is drawn rather than reserved per pane — the server
    /// decides how many cells each pane gets — so the grid asks for enough
    /// slack to cover it, which is why the server has to be told when it
    /// changes.
    private var panePadding: CGFloat = 6

    /// It changes how many cells fit, so the server has to be told.
    func apply(panePadding padding: CGFloat) {
        guard padding != panePadding else { return }
        panePadding = padding
        reportGridSize()
        needsDisplay = true
    }
    private var glyphs: GlyphRunDrawer
    private var lastRevision: UInt64 = .max
    /// Last grid size we told the server about, so a live drag does not send a
    /// resize per pixel.
    private var reportedGridSize: (cols: Int, rows: Int)?
    /// Pane geometry from the last surface we drew.
    ///
    /// Cached because resolving it means crossing the FFI boundary and
    /// allocating a string per pane, which is far too much work to repeat for
    /// every mouse-moved and scroll event.
    private(set) var panes: [PaneView] = []

    /// The colour each pane is mostly painted in, keyed by pane id.
    ///
    /// The padding around a pane's text belongs to that pane, not to the
    /// window, so it has to be filled in the pane's own background — a program
    /// that sets its own would otherwise sit in a frame of the theme's colour.
    /// Recomputed only when the surface advances, since counting cells per
    /// frame would be far too much work for something that rarely changes.
    private var paneBackgrounds: [String: NSColor] = [:]

    /// The pane background covering the most cells: what the terminal looks
    /// like, taken as a whole.
    private(set) var dominantBackground: NSColor?

    /// The focused pane, from the snapshot rather than the surface.
    ///
    /// The snapshot is the authority and arrives before the first surface, so
    /// relying on the surface alone would drop keystrokes typed before the
    /// first paint.
    var focusedPaneFromSnapshot: String?

    var focusedPane: String? {
        focusedPaneFromSnapshot ?? panes.first(where: \.focused)?.id
    }

    fileprivate var scrollAccumulator: CGFloat = 0

    /// One child view per pane, keyed by pane id.
    private var paneViews: [String: PaneContentView] = [:]

    /// Decoded images, keyed by asset id.
    ///
    /// Decoding is far too expensive to redo per frame, and the server only
    /// sends an asset's bytes once, so results are kept until the asset is gone.
    private var imageCache: [UInt64: CGImage] = [:]

    /// Active copy mode, if any.
    var copyMode: CopyMode?
    /// Raised with the status text when copy mode starts, changes or ends.
    var onCopyModeChanged: ((String?) -> Void)?
    /// Raised to run a copy-mode request that needs a reply.
    var onCopyModeRequest: ((String, String, @escaping (String) -> Void) -> Void)?

    /// The active drag selection, if any.
    var selection: Selection?
    /// Raised when a selection is copied, with the request to read its text.
    var onReadSelection: ((String) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(font: NSFont) {
        glyphs = GlyphRunDrawer(base: font)
        cellSize = glyphs.cellSize
        super.init(frame: .zero)
        // Layer-backed because its pane views are, and with the redraw policy
        // that actually redraws on invalidation rather than only on resize.
    }

    /// Swaps the font, which changes the cell size and therefore the grid.
    func apply(font: NSFont) {
        glyphs = GlyphRunDrawer(base: font)
        cellSize = glyphs.cellSize
        syncPaneViews()
        // The grid size changed under the server; make it re-lay-out.
        reportedGridSize = nil
        let size = gridSize
        reportedGridSize = size
        onResize?(size.cols, size.rows)
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var gridSize: (cols: Int, rows: Int) {
        guard cellSize.width > 0, cellSize.height > 0 else { return (80, 24) }
        // The padding is drawn inside each pane, so leave room for it or the
        // last column and row would be pushed under the border.
        let reserved = panePadding * 2
        let usable = CGSize(width: bounds.width - reserved, height: bounds.height - reserved)
        return (
            max(Int(usable.width / cellSize.width), 1),
            max(Int(usable.height / cellSize.height), 1)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A live resize drag fires this continuously; only the grid size
        // matters to the server, so report it when it actually changes.
        //
        // Nothing is recorded before a handler exists: layout runs before the
        // session is connected, and remembering that early size meant the real
        // one was later judged "unchanged" and never sent, leaving the server
        // composing a surface for a window that had since grown.
        guard let onResize else { return }
        let size = gridSize
        if let reported = reportedGridSize, reported == size { return }
        reportedGridSize = size
        onResize(size.cols, size.rows)
    }

    /// Tells the server the current size, whatever it last heard.
    func reportGridSize() {
        let size = gridSize
        reportedGridSize = size
        onResize?(size.cols, size.rows)
    }

    /// Discards the current surface, for when the machine underneath changes.
    func forgetSurface() {
        lastRevision = .max
        panes = []
        paneBackgrounds = [:]
        selection = nil
        copyMode = nil
        paneViews.values.forEach { $0.removeFromSuperview() }
        paneViews.removeAll()
        needsDisplay = true
    }

    /// Called each tick; only repaints when the surface actually advanced.
    func refreshIfNeeded() {
        guard let session else { return }
        let latest = session.withGrid {
            (revision: $0.revision, panes: $0.panes, placements: $0.placements)
        }
        guard let latest, latest.revision != lastRevision else { return }
        lastRevision = latest.revision
        panes = latest.panes
        recomputePaneBackgrounds()
        pruneImageCache(keeping: latest.placements)
        syncPaneViews()
        needsDisplay = true
    }

    /// Creates, moves and retires pane views to match the current surface.
    private func syncPaneViews() {
        var live = Set<String>()
        for pane in panes {
            live.insert(pane.id)
            let view = paneViews[pane.id] ?? {
                let created = PaneContentView(paneID: pane.id, owner: self)
                paneViews[pane.id] = created
                addSubview(created)
                return created
            }()
            view.place(pane, cellSize: cellSize)
        }
        for (id, view) in paneViews where !live.contains(id) {
            view.removeFromSuperview()
            paneViews.removeValue(forKey: id)
        }
    }

    /// What to say when there is nothing to draw.
    ///
    /// An empty terminal should explain itself. Without this, "still
    /// connecting", "connected but no surface yet" and "a bug in the renderer"
    /// all look identical, which is exactly the ambiguity that made this hard
    /// to diagnose from a screenshot.
    var placeholder: String?

    /// Finds the dominant background of each pane.
    ///
    /// The mode rather than, say, the first cell: a pane's first row is as
    /// likely to be a coloured status line as it is to be ordinary output, and
    /// the colour wanted here is the one the pane is mostly filled with.
    private func recomputePaneBackgrounds() {
        guard let session, !panes.isEmpty else {
            paneBackgrounds = [:]
            return
        }
        let previous = dominantBackground
        paneBackgrounds =
            session.withGrid { grid in
                var result: [String: NSColor] = [:]
                for pane in panes {
                    let maxY = min(pane.inner.y + pane.inner.height, grid.height)
                    let maxX = min(pane.inner.x + pane.inner.width, grid.width)
                    guard maxX > pane.inner.x, maxY > pane.inner.y else { continue }

                    var counts: [UInt32: Int] = [:]
                    for row in pane.inner.y..<maxY {
                        let base = row * grid.width
                        for col in pane.inner.x..<maxX {
                            counts[grid.cells[base + col].bg, default: 0] += 1
                        }
                    }
                    guard let packed = counts.max(by: { $0.value < $1.value })?.key else {
                        continue
                    }
                    result[pane.id] = PackedColor(packed, theme: theme, isForeground: false)
                        .resolved(theme: theme, isForeground: false)
                }
                return result
            } ?? [:]

        // Weighted by area, so one small pane running a coloured program does
        // not repaint the whole window.
        dominantBackground =
            panes
            .compactMap { pane in
                paneBackgrounds[pane.id].map {
                    (color: $0, cells: pane.inner.width * pane.inner.height)
                }
            }
            .reduce(into: [NSColor: Int]()) { $0[$1.color, default: 0] += $1.cells }
            .max { $0.value < $1.value }?.key

        if let dominantBackground, dominantBackground != previous {
            onBackgroundChanged?(dominantBackground)
        }
    }

    /// The colour to lay a pane down on, and to leave showing in its padding.
    private func background(of pane: PaneView) -> NSColor {
        paneBackgrounds[pane.id] ?? theme.background
    }

    /// A pane's text area grown by the padding: what the pane visually covers.
    private func paddedRect(of pane: PaneView) -> CGRect {
        CGRect(
            x: CGFloat(pane.inner.x) * cellSize.width,
            y: CGFloat(pane.inner.y) * cellSize.height,
            width: CGFloat(pane.inner.width) * cellSize.width,
            height: CGFloat(pane.inner.height) * cellSize.height
        ).insetBy(dx: -panePadding, dy: -panePadding)
    }

    /// The container paints only the background; panes draw themselves.
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // The whole view, not just `dirtyRect`: every cell is redrawn below,
        // and cells whose background matches the theme skip their own fill, so
        // clearing only the dirty rect leaves the previous frame's text showing
        // through everywhere else.
        chrome.content.setFill()
        context.fill(bounds)

        if !panes.isEmpty, let session {
            context.saveGState()
            context.translateBy(x: panePadding, y: panePadding)
            session.withGrid { grid in
                for pane in panes {
                    let background = background(of: pane)
                    if background != theme.background {
                        context.addPath(
                            CGPath(
                                roundedRect: paddedRect(of: pane), cornerWidth: 4,
                                cornerHeight: 4, transform: nil))
                        context.setFillColor(background.cgColor)
                        context.fillPath()
                    }
                    // The pane's *inner* rect: the margin between it and `rect`
                    // is where the server drew its own border, and drawing both
                    // that and ours gave every pane a double outline.
                    drawRegion(grid, pane.inner, over: background, in: context)
                    drawImages(grid, in: context, within: pane.inner)
                }
                drawSelection(grid, in: context)
                drawCopyModeCursor(in: context)
                drawCursor(grid, in: context)
                drawPaneBorders(in: context)
            }
            context.restoreGState()
            return
        }

        guard let placeholder else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: theme.foreground.withAlphaComponent(0.45),
        ]
        let text = NSAttributedString(string: placeholder, attributes: attributes)
        let size = text.size()
        text.draw(
            at: CGPoint(
                x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    /// Drops images the scene no longer refers to.
    ///
    /// Done on every surface rather than while drawing, because a scene that
    /// has lost all its placements never draws and would otherwise hold its
    /// images for the life of the session.
    private func pruneImageCache(keeping placements: [Placement]) {
        guard !imageCache.isEmpty else { return }
        let live = Set(placements.map(\.assetID))
        imageCache = imageCache.filter { live.contains($0.key) }
    }

    /// Draws the images the server placed in this pane.
    ///
    /// Placements come already clipped and in surface cell coordinates, and the
    /// server sends the complete desired scene each frame, so there is no
    /// placement state to reconcile — just draw what is there, back to front.
    private func drawImages(_ grid: GridView, in context: CGContext, within region: CellRect) {
        let inRegion = grid.placements.filter { placement in
            placement.x >= region.x && placement.x < region.x + region.width
                && placement.y >= region.y && placement.y < region.y + region.height
        }
        guard !inRegion.isEmpty else { return }

        for placement in inRegion.sorted(by: { $0.z < $1.z }) {
            let image: CGImage?
            if let cached = imageCache[placement.assetID] {
                image = cached
            } else {
                image = session?.image(for: placement.assetID)
                if let image { imageCache[placement.assetID] = image }
            }
            guard let image else { continue }

            let cropped: CGImage
            if placement.sourceWidth > 0, placement.sourceHeight > 0,
                placement.sourceX + placement.sourceWidth <= image.width,
                placement.sourceY + placement.sourceHeight <= image.height,
                let crop = image.cropping(
                    to: CGRect(
                        x: placement.sourceX, y: placement.sourceY,
                        width: placement.sourceWidth, height: placement.sourceHeight))
            {
                cropped = crop
            } else {
                cropped = image
            }

            let rect = CGRect(
                x: CGFloat(placement.x) * cellSize.width + CGFloat(placement.xOffset),
                y: CGFloat(placement.y) * cellSize.height + CGFloat(placement.yOffset),
                width: CGFloat(placement.cols) * cellSize.width,
                height: CGFloat(placement.rows) * cellSize.height)

            // The view is flipped; images are not, so flip back around the
            // placement or they draw upside down.
            context.saveGState()
            context.translateBy(x: 0, y: rect.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -rect.midY)
            context.draw(cropped, in: rect)
            context.restoreGState()
        }
    }

    /// The copy-mode cursor, outlined so it reads as a position you are moving
    /// rather than where output will appear.
    private func drawCopyModeCursor(in context: CGContext) {
        guard let copyMode,
            let pane = panes.first(where: { $0.id == copyMode.paneID })
        else { return }

        let viewportRow = Int(copyMode.cursor.row) - Int(pane.viewportTopRow)
        guard viewportRow >= 0, viewportRow < pane.inner.height else { return }

        let rect = CGRect(
            x: CGFloat(pane.inner.x + copyMode.cursor.column) * cellSize.width,
            y: CGFloat(pane.inner.y + viewportRow) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height)
        context.setStrokeColor(theme.cursor.cgColor)
        context.setLineWidth(1.5)
        context.stroke(rect.insetBy(dx: 0.75, dy: 0.75))
    }

    /// One border per pane, drawn only when there is more than one.
    ///
    /// The focused pane gets the accent colour and the others a faint line, so
    /// which pane takes your keystrokes is obvious without a second outline
    /// competing with it.
    /// Frames the terminal region, and the focused pane within it.
    ///
    /// One outer frame rather than a box per pane: boxing each one gave a split
    /// tab a stack of nested outlines. Unfocused panes get nothing at all —
    /// the frame already says where the terminal ends, and the only edge worth
    /// drawing inside it is the one around the pane taking your keystrokes.
    private func drawPaneBorders(in context: CGContext) {
        guard !panes.isEmpty else { return }
        let rects = panes.map { (pane: $0, rect: paddedRect(of: $0)) }
        let outer = rects.dropFirst().reduce(rects[0].rect) { $0.union($1.rect) }

        // The frame is quiet when it is only a frame, and the accent when the
        // focused pane is the whole of it.
        let focusedIsEverything = rects.count == 1
        context.addPath(
            CGPath(roundedRect: outer, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.setStrokeColor(
            (focusedIsEverything ? chrome.accent : chrome.separator).cgColor)
        context.setLineWidth(focusedIsEverything ? 1.5 : 1)
        context.strokePath()

        if !focusedIsEverything, let focused = rects.first(where: { $0.pane.id == focusedPane }) {
            context.addPath(
                CGPath(
                    roundedRect: focused.rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.setStrokeColor(chrome.accent.cgColor)
            context.setLineWidth(1.5)
            context.strokePath()
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

        context.setFillColor(theme.selection.withAlphaComponent(0.45).cgColor)
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

    private func drawRegion(
        _ grid: GridView, _ region: CellRect, over base: NSColor, in context: CGContext
    ) {
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
                    flushBackground(
                        runColor, from: runStart, to: col, row: row, over: base, in: context)
                    runStart = col
                    runColor = bg
                }
            }
            flushBackground(runColor, from: runStart, to: maxX, row: row, over: base, in: context)

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
        _ color: NSColor?, from startCol: Int, to endCol: Int, row: Int, over base: NSColor,
        in context: CGContext
    ) {
        // Cells matching what the pane was laid down on are already painted.
        guard let color, endCol > startCol, color != base else { return }
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
        theme.cursor.withAlphaComponent(0.75).setFill()
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
        // Copy mode owns the keyboard while it is up.
        if copyMode != nil, handleCopyModeKey(event) { return }

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
        let origin = panePadding
        let column = Int((point.x - origin) / cellSize.width)
        let row = Int((point.y - origin) / cellSize.height)

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
            pixel_x: UInt32(max(point.x - panePadding, 0)),
            pixel_y: UInt32(max(point.y - panePadding, 0)),
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
            anchor: Selection.Point(row: absolute, column: bounds.start),
            cursor: Selection.Point(row: absolute, column: bounds.end))
    }

    private func selectLine(in pane: PaneView, row: Int) {
        let localRow = (row - pane.inner.y).clamped(to: 0...max(pane.inner.height - 1, 0))
        let absolute = pane.viewportTopRow + UInt64(localRow)
        selection = Selection(
            paneID: pane.id,
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
