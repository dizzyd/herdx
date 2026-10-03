import AppKit
import CHerdrCore

/// Draws the pane surface herdr sends us.
///
/// The server composes one grid for the whole active tab and reports where each
/// pane sits inside it. This view owns that single grid and the input for it;
/// every span is routed through its owning pane first, which is what let the
/// panes become real `NSView`s — `syncPaneViews` keeps a `PaneContentView` per
/// pane — without changing how surfaces or patches are delivered.
final class TerminalGridView: NSView {
    var session: HerdrSession?
    var theme: Theme = .dark
    /// The chrome the frame and rules are drawn from, so the terminal's edges
    /// match the sidebar and tabs rather than the system's accent alone.
    var chrome = Chrome(theme: .dark)
    var onResize: ((Int, Int) -> Void)?
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

    /// Space between the view's edge and a pane's frame.
    ///
    /// Not a preference: each frame carries a label riding its top border, and
    /// without a gap above the topmost frame there is nowhere for that label to
    /// sit. It is the design's, not the reader's, so it is fixed.
    private let frameInset: CGFloat = 8

    private var labelSize: CGFloat = 11

    private var labelFont: NSFont { .systemFont(ofSize: labelSize, weight: .semibold) }

    /// Clearance between a pane's top border and its first row of text.
    ///
    /// The label rides that border, so half of it hangs into the pane. Without
    /// a band of its own it hangs over the first row instead, which at a small
    /// pane padding puts it on top of the text. Taken from the label's own font
    /// so a bigger label makes its own room rather than growing into the text.
    private var labelClearance: CGFloat {
        (labelFont.boundingRectForFont.height / 2).rounded(.up) + 4
    }

    /// True while `ctrl+b` has been pressed and the next key completes a chord.
    ///
    /// Shown on the focused pane's frame: an armed prefix silently eats the
    /// next keystroke, and a mode you cannot see is indistinguishable from a
    /// keyboard that has stopped working.
    var prefixArmed = false {
        didSet { if prefixArmed != oldValue { needsDisplay = true } }
    }

    /// What the prefix is called, which the user may have changed.
    var prefixLabel = "⌃B"

    /// What to write on each pane's frame, by pane id.
    var paneLabels: [String: String] = [:] {
        didSet { if paneLabels != oldValue { needsDisplay = true } }
    }

    /// Both change how many cells fit, so the server has to be told.
    func apply(panePadding padding: CGFloat, labelSize size: CGFloat) {
        guard padding != panePadding || size != labelSize else { return }
        panePadding = padding
        labelSize = size
        refreshLinkHover()
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

    /// Cells the server keeps around the outside for its own pane borders.
    ///
    /// herdr draws a box around every pane and reports each pane's `inner`
    /// rect inside it. We frame panes ourselves and never draw those cells, so
    /// left alone they are a dead ring: a whole row of nothing between the tabs
    /// and the first line of output. `offset` is where the content actually
    /// starts, and `ring` is what the surface has to grow by for the content to
    /// still fill the window.
    private struct DeadCells: Equatable {
        /// Where the content starts, in cells from the surface's corner.
        var offsetX = 0
        var offsetY = 0
        /// How many cells the whole ring costs.
        var ringCols = 0
        var ringRows = 0
    }
    private var dead = DeadCells()

    /// Where cell (0, 0) lands, chosen so the *content* sits against the frame
    /// inset rather than the surface's top-left corner.
    var contentOrigin: CGPoint {
        CGPoint(
            x: panePadding + frameInset - CGFloat(dead.offsetX) * cellSize.width,
            y: panePadding + frameInset + labelClearance
                - CGFloat(dead.offsetY) * cellSize.height)
    }

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

    /// Decoded images for the machine currently being shown; see `ImageCache`.
    var imageCache = ImageCache()

    /// Text an input method is still composing; see `NSTextInputClient`.
    ///
    /// Held here rather than sent: the server knows nothing about a
    /// composition, and a pane handed each candidate keystroke would run them
    /// as input.
    var markedText: String?

    /// Whether every keystroke is this view's, whatever the keymap says.
    ///
    /// Asked before a chord is resolved, because a chord resolved first eats
    /// the key and the view never hears about it.
    ///
    /// Two states qualify, and copy mode at large is deliberately not one of
    /// them. herdr hands the prefix priority over copy mode — see
    /// `route_copy_mode_key`, which arms the prefix from inside it — so a
    /// client that kept copy mode's own `⌃b` would disagree with the TUI about
    /// a key the user shares between them.
    ///
    /// An input method composing is the first: return commits a candidate, the
    /// arrows move through the list, escape abandons it, and a chord that ate
    /// one of those leaves the composition stuck with no way to finish it.
    ///
    /// A copy-mode search query is the second, and it is herdr's own
    /// exception: while a prompt is open the prefix belongs to the query,
    /// because a query is text and the prefix is a character in it like any
    /// other.
    var ownsEveryKey: Bool {
        if hasMarkedText() { return true }
        if case .search = copyMode?.field { return true }
        return false
    }

    /// Active copy mode, if any.
    var copyMode: CopyMode?
    /// Numbers each copy-mode session, so a reply that arrives after the
    /// session that asked for it has ended can be told apart from one that
    /// belongs to the session now on screen.
    var copyModeGeneration = 0
    // What copy mode is waiting on lives in `CopyMode.pending`, with the
    // session it belongs to: the generation below is the only part of it whose
    // lifetime is the view's.
    /// Raised with the status text when copy mode starts, changes or ends.
    var onCopyModeChanged: ((String?) -> Void)?
    /// Raised to run a copy-mode request that needs a reply.
    var onCopyModeRequest: ((String, String, @escaping (String) -> Void) -> Void)?

    /// The active drag selection, if any.
    var selection: Selection?
    /// Raised when a selection is copied, with the request to read its text.
    var onReadSelection: ((String) -> Void)?

    var openLink: (URL) -> Void = { url in _ = NSWorkspace.shared.open(url) }
    // Allows AppKit gesture tests to exercise delivery without a live server.
    var linkResolverForTesting: ((CGPoint) -> TerminalLink?)?
    // And to see what reached the program, which otherwise needs a live server
    // to observe at all. The event as well as the pane, because the
    // coordinates in it are the thing most worth checking and the thing least
    // visible from outside: a report with the right kind at the wrong column
    // is a click in the wrong place.
    var mouseReportForTesting: ((UInt16, String, HxMouseEvent) -> Void)?
    /// Everything the hover drives hangs off this setter, and only fires on a
    /// real change: hover is re-resolved on every surface revision, and the
    /// underline, tooltip and cursor rects must not be redone per frame.
    /// The pointing hand comes from a cursor rect rather than `NSCursor.set`,
    /// so AppKit owns restoring it and nothing here fights another cursor.
    private var hoveredLink: TerminalLink? {
        didSet {
            guard hoveredLink != oldValue else { return }
            toolTip = hoveredLink?.url.absoluteString
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private var pressedLink: TerminalLink?
    /// What the press now under way is doing, decided when it went down.
    ///
    /// Inferring it afterwards from whatever state happened to be lying around
    /// is how a click into a mouse-reporting program got its drag and its
    /// release swallowed by a selection made somewhere else a minute earlier:
    /// the program saw a button go down and never come up.
    private enum MouseGesture {
        case selecting(paneID: String)
        /// A press that went to the program in a pane rather than starting a
        /// selection. Which pane is `reportOwners`' business, not this one's;
        /// what this records is that there was a press at all, so a release
        /// is not invented from nothing.
        case reporting(paneID: String)
        case link
    }
    private var gesture: MouseGesture?

    /// Which pane each held button was pressed in, and on which machine.
    ///
    /// A press and its release are one thing to the program receiving them,
    /// and the program is chosen when the button goes down. Hit-testing the
    /// release instead sends the pair to two different programs: one is left
    /// holding a button that never comes up, the other gets a release it never
    /// asked for. Per button, because the right button can be held while the
    /// left is clicked and they are not the same gesture.
    ///
    /// The session and endpoint ride along because a pane id means something
    /// different on another server. If the machine changes under a held
    /// button, the release belongs to nobody that is still here — and is
    /// dropped rather than aimed at whatever now occupies that part of the
    /// screen.
    private struct MouseReportOwner {
        let paneID: String
        /// Absent only with no session at all, which is the tests driving the
        /// view directly. Compared either way, so a session appearing or
        /// going during a held button is a mismatch like any other.
        let session: UUID?
        let endpoint: Int?
    }
    private var reportOwners: [UInt8: MouseReportOwner] = [:]
    private var ownsLinkGesture: Bool {
        if case .link = gesture { return true }
        return false
    }
    private var linkPressCancelled = false
    private var pressedRevision: UInt64?
    private var pressedEndpoint: Int?
    private weak var pressedSession: HerdrSession?
    private var linkTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let linkTrackingArea { removeTrackingArea(linkTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        linkTrackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    private func link(at location: CGPoint) -> TerminalLink? {
        if let linkResolverForTesting { return linkResolverForTesting(location) }
        guard cellSize.width > 0, cellSize.height > 0 else { return nil }
        let column = Int(floor((location.x - contentOrigin.x) / cellSize.width))
        let row = Int(floor((location.y - contentOrigin.y) / cellSize.height))
        guard let pane = panes.first(where: {
            column >= $0.inner.x && column < $0.inner.x + $0.inner.width
                && row >= $0.inner.y && row < $0.inner.y + $0.inner.height
        }) else { return nil }
        return session?.withGrid {
            TerminalLinks.resolve($0, pane: pane, column: column, row: row)
        } ?? nil
    }

    private func updateLinkHover(at location: CGPoint, command: Bool) {
        hoveredLink = command && bounds.contains(location) ? link(at: location) : nil
    }

    func refreshLinkHover() {
        guard let window else { return }
        let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(pointer) else {
            hoveredLink = nil
            return
        }
        updateLinkHover(at: pointer,
            command: window.isKeyWindow && NSEvent.modifierFlags.contains(.command))
    }

    func clearLinkHover() {
        hoveredLink = nil
        if ownsLinkGesture { linkPressCancelled = true }
    }

    override func mouseMoved(with event: NSEvent) {
        guard window?.isKeyWindow == true else { clearLinkHover(); return }
        updateLinkHover(at: convert(event.locationInWindow, from: nil),
            command: event.modifierFlags.contains(.command))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredLink = nil
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshLinkHover()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let hoveredLink else { return }
        for span in hoveredLink.spans {
            addCursorRect(CGRect(x: contentOrigin.x + CGFloat(span.columns.lowerBound) * cellSize.width,
                y: contentOrigin.y + CGFloat(span.row) * cellSize.height,
                width: CGFloat(span.columns.count) * cellSize.width, height: cellSize.height),
                cursor: .pointingHand)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if let window {
            guard window.isKeyWindow else { clearLinkHover(); return }
            if ownsLinkGesture && !event.modifierFlags.contains(.command) {
                linkPressCancelled = true
            }
            updateLinkHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil),
                command: event.modifierFlags.contains(.command))
        }
        super.flagsChanged(with: event)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Kept whole for the composition overlay, which is drawn as text rather
    /// than cell by cell so an input method's candidates get font fallback.
    private(set) var baseFont: NSFont

    init(font: NSFont, lineHeight: CGFloat) {
        baseFont = font
        glyphs = GlyphRunDrawer(base: font, lineHeight: lineHeight)
        cellSize = glyphs.cellSize
        super.init(frame: .zero)
        // Layer-backed because its pane views are, and with the redraw policy
        // that actually redraws on invalidation rather than only on resize.
    }

    /// Swaps the font, which changes the cell size and therefore the grid.
    func apply(font: NSFont, lineHeight: CGFloat) {
        baseFont = font
        glyphs = GlyphRunDrawer(base: font, lineHeight: lineHeight)
        cellSize = glyphs.cellSize
        syncPaneViews()
        refreshLinkHover()
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
        // last column and row would be pushed under the border. Height loses
        // the label's band as well; a pane below this one takes its own out of
        // the gutter the server leaves between them.
        let reserved = (panePadding + frameInset) * 2
        let usable = CGSize(
            width: bounds.width - reserved, height: bounds.height - reserved - labelClearance)
        // Plus the server's own border ring: those cells are not ours to draw
        // in, so asking only for what fits leaves the content a ring short of
        // the window.
        return (
            max(Int(usable.width / cellSize.width), 1) + dead.ringCols,
            max(Int(usable.height / cellSize.height), 1) + dead.ringRows
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshLinkHover()
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

    /// Sets the panes directly, with no surface to read them from.
    ///
    /// `refreshIfNeeded` is how this happens for real, out of the core's grid.
    /// This is for the tests, which have no server on the other side to compose
    /// one — named so that nothing mistakes it for the real path.
    func setPanesForTesting(_ panes: [PaneView]) {
        self.panes = panes
    }

    /// Tells the server the current size, whatever it last heard.
    func reportGridSize() {
        let size = gridSize
        reportedGridSize = size
        onResize?(size.cols, size.rows)
    }

    /// Discards the current surface, for when the machine underneath changes.
    ///
    /// Everything keyed by something the old machine named has to go, not only
    /// what is drawn. Pane ids are unique within a server and no further, so a
    /// focused pane left over from the machine just left is not a stale
    /// reference on the new one — it is a live pane belonging to other work,
    /// and typing would go to it.
    func forgetSurface() {
        pressedLink = nil
        pressedRevision = nil
        pressedEndpoint = nil
        pressedSession = nil
        // Keep ownership through mouse-up even when switching machines;
        // otherwise the new pane receives a release without a press.
        linkPressCancelled = true
        // Held buttons belonged to panes on the machine being left. `send`
        // checks the session and endpoint and would refuse them anyway;
        // dropping them here is the same answer said once rather than per
        // event, and it is the answer — a release is consumed, never aimed at
        // whatever has taken that pane's place.
        reportOwners.removeAll()
        hoveredLink = nil
        lastRevision = .max
        panes = []
        selection = nil
        copyMode = nil
        focusedPaneFromSnapshot = nil
        markedText = nil
        imageCache.empty()
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
        if ownsLinkGesture { linkPressCancelled = true }
        panes = latest.panes
        measureDeadCells(session)
        // Pruned on every surface rather than while drawing: a scene that has
        // lost all its placements never draws, and would otherwise hold its
        // images for the life of the session.
        imageCache.prune(keeping: latest.placements)
        syncPaneViews()
        refreshLinkHover()
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

    /// Works out the ring of border cells the surface spends on itself.
    private func measureDeadCells(_ session: HerdrSession) {
        let inners = panes.map(\.inner)
        guard !inners.isEmpty,
            let size = session.withGrid({ (width: $0.width, height: $0.height) })
        else {
            dead = DeadCells()
            return
        }
        let minX = inners.map(\.x).min() ?? 0
        let minY = inners.map(\.y).min() ?? 0
        let maxX = inners.map { $0.x + $0.width }.max() ?? size.width
        let maxY = inners.map { $0.y + $0.height }.max() ?? size.height

        // Clamped: a surface that reported something strange must not be able
        // to drive an ever-growing resize, since the size we ask for is
        // computed from the size we were given.
        let measured = DeadCells(
            offsetX: min(max(minX, 0), 4),
            offsetY: min(max(minY, 0), 4),
            ringCols: min(max(size.width - (maxX - minX), 0), 8),
            ringRows: min(max(size.height - (maxY - minY), 0), 8))
        guard measured != dead else { return }
        dead = measured
        // The ring is only known once a surface has arrived, and it changes
        // what will fit — so the size the server was told at startup is now
        // wrong by exactly this much. It settles on the next surface, because
        // the ring a server draws does not depend on how big the surface is.
        reportGridSize()
    }

    /// A pane's text area grown by the padding: what the pane visually covers.
    private func paddedRect(of pane: PaneView) -> CGRect {
        CGRect(
            x: CGFloat(pane.inner.x) * cellSize.width - panePadding,
            y: CGFloat(pane.inner.y) * cellSize.height - panePadding - labelClearance,
            width: CGFloat(pane.inner.width) * cellSize.width + panePadding * 2,
            height: CGFloat(pane.inner.height) * cellSize.height + panePadding * 2
                + labelClearance)
    }

    /// Draws the whole surface: the background, then every pane's content.
    ///
    /// The pane views deliberately have no `draw` of their own — see
    /// `PaneContentView`, where relying on each child to draw itself left
    /// panes blank at the mercy of per-view invalidation. They exist for
    /// hit-testing and for what will hang off them later.
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
            context.translateBy(x: contentOrigin.x, y: contentOrigin.y)
            session.withGrid { grid in
                for pane in panes {
                    // Clipped so the cells that run out into the padding keep
                    // the frame's rounded corners.
                    context.saveGState()
                    context.addPath(
                        CGPath(
                            roundedRect: paddedRect(of: pane), cornerWidth: 4,
                            cornerHeight: 4, transform: nil))
                    context.clip()
                    // The pane's *inner* rect: the margin between it and `rect`
                    // is where the server drew its own border, and drawing both
                    // that and ours gave every pane a double outline.
                    drawRegion(grid, pane.inner, in: context)
                    context.restoreGState()
                    drawImages(grid, in: context, within: pane.inner)
                }
                drawSelection(grid, in: context)
                drawLinkHover(in: context)
                drawCopyModeCursor(in: context)
                drawCursor(grid, in: context)
                drawMarkedText(grid, in: context)
                drawPaneBorders(in: context)
            }
            context.restoreGState()
            return
        }

        guard let placeholder else { return }
        // Centred per line and drawn into a rect: what goes here is sometimes
        // several lines of explanation, and `draw(at:)` would range them down
        // the left of a single centred block.
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: chrome.secondary,
            .paragraphStyle: style,
        ]
        let text = NSAttributedString(string: placeholder, attributes: attributes)
        let width = min(bounds.width - 80, 460)
        let height = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).height
        text.draw(
            with: CGRect(
                x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
                width: width, height: height),
            options: [.usesLineFragmentOrigin])
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

    /// Frames each pane and writes what it is on its own border.
    ///
    /// One frame per pane rather than a frame around the lot with a second one
    /// inside it: the earlier arrangement gave a split tab nested outlines for
    /// one selection. Where a tab is split, the focused pane's frame is the
    /// accent and heavier and the rest are hairlines. Where it is not, the
    /// accent would be answering a question nobody asked — there is only one
    /// pane it could mean — so the lone frame stays quiet.
    ///
    /// The label rides the top border because what it says — the working
    /// directory, the agent and its state — belongs to that pane and not to the
    /// window. A single line above the tabs had to silently change meaning as
    /// focus moved between panes, with nothing on screen to show that it had.
    private func drawPaneBorders(in context: CGContext) {
        // Which pane has focus only needs saying when there is a choice.
        let split = panes.count > 1

        for pane in panes {
            let rect = paddedRect(of: pane)
            let focused = pane.id == focusedPane
            let highlighted = focused && split

            let label = paneLabel(pane, on: rect, focused: focused)

            context.saveGState()
            // A gap left in the border for the label, rather than the border
            // painted over: under the gap is the window above the edge and the
            // pane's own top row below it, and no one fill is both.
            if let label {
                context.addRect(rect.insetBy(dx: -8, dy: -8))
                context.addRect(label.gap)
                context.clip(using: .evenOdd)
            }
            context.addPath(
                CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
            context.setStrokeColor((highlighted ? chrome.accent : chrome.separator).cgColor)
            context.setLineWidth(highlighted ? 1.5 : 1)
            context.strokePath()
            context.restoreGState()

            label?.text.draw(with: label!.frame, options: [.usesLineFragmentOrigin])
            if focused, prefixArmed {
                drawPrefixIndicator(on: rect, in: context)
            }
        }
    }

    /// Marks the focused pane's frame while a chord is half-entered.
    ///
    /// Filled rather than cleared like the label: this is a transient mode, and
    /// it should read as something switched on rather than as another caption.
    private func drawPrefixIndicator(on rect: CGRect, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: labelSize, weight: .semibold),
            .foregroundColor: chrome.accent.isDarkish ? NSColor.white : NSColor.black,
        ]
        let text = NSAttributedString(string: prefixLabel, attributes: attributes)
        let size = text.size()

        let pill = CGRect(
            x: rect.minX + 12, y: rect.minY - (size.height + 2) / 2,
            width: size.width + 14, height: size.height + 2)
        context.addPath(
            CGPath(
                roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2,
                transform: nil))
        context.setFillColor(chrome.accent.cgColor)
        context.fillPath()

        text.draw(
            at: CGPoint(x: pill.minX + 7, y: pill.minY + 1))
    }

    /// A pane's label, where it sits on its top border, and the gap the border
    /// leaves for it.
    private func paneLabel(
        _ pane: PaneView, on rect: CGRect, focused: Bool
    ) -> (text: NSAttributedString, frame: CGRect, gap: CGRect)? {
        guard let label = paneLabels[pane.id], !label.isEmpty else { return nil }

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: focused ? labelFont : .systemFont(ofSize: labelSize, weight: .medium),
            .foregroundColor: focused ? chrome.primary : chrome.secondary,
            .paragraphStyle: style,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)

        // Truncation needs a width to truncate to, so the label is given what
        // is left of the frame; a pane too narrow to say anything useful says
        // nothing instead of an ellipsis.
        let inset: CGFloat = 12
        let available = rect.width - inset * 2
        guard available > 40 else { return nil }
        let size = text.size()
        let width = min(size.width, available)
        let height = size.height

        // Right-justified: terminal output is left-heavy, so the far end of the
        // top border is the quietest place on the frame to put it.
        let textRect = CGRect(
            x: rect.maxX - inset - width, y: rect.minY - height / 2,
            width: width, height: height)

        return (text, textRect, textRect.insetBy(dx: -5, dy: 0))
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

    private func drawLinkHover(in context: CGContext) {
        guard let hoveredLink else { return }
        context.setFillColor(chrome.accent.cgColor)
        for span in hoveredLink.spans {
            context.fill(CGRect(x: CGFloat(span.columns.lowerBound) * cellSize.width,
                y: CGFloat(span.row + 1) * cellSize.height - 1,
                width: CGFloat(span.columns.count) * cellSize.width, height: 1))
        }
    }

    /// Draws a pane's cells, letting those along its edges run out into the
    /// padding.
    ///
    /// The padding belongs to the pane, and a pane has no background of its own
    /// to fill it with — only cells, each with its own. So each edge cell
    /// carries on to the frame: a program that paints every cell fills the
    /// padding, a block of highlighted lines runs to the edge, and plain text
    /// leaves the theme showing. Deciding instead which colour was the pane's
    /// meant guessing from how much of it each colour covered, and a tool's
    /// output block scrolled to fill the pane won that guess and recoloured the
    /// frame and the window with it.
    private func drawRegion(_ grid: GridView, _ region: CellRect, in context: CGContext) {
        let maxY = min(region.y + region.height, grid.height)
        let maxX = min(region.x + region.width, grid.width)
        guard maxX > region.x, maxY > region.y else { return }
        let edges = Bleed(
            region: region.x..<maxX, top: region.y, bottom: maxY - 1,
            padding: panePadding, above: panePadding + labelClearance)

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
                        runColor, from: runStart, to: col, row: row, bleeding: edges,
                        in: context)
                    runStart = col
                    runColor = bg
                }
            }
            flushBackground(
                runColor, from: runStart, to: maxX, row: row, bleeding: edges, in: context)

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

    /// How far a pane's edge cells reach past the grid, in points.
    private struct Bleed {
        let region: Range<Int>
        let top: Int
        let bottom: Int
        /// Left, right and below.
        let padding: CGFloat
        /// Above is more: the label rides the top border and has room of its
        /// own there.
        let above: CGFloat
    }

    private func flushBackground(
        _ color: NSColor?, from startCol: Int, to endCol: Int, row: Int, bleeding edges: Bleed,
        in context: CGContext
    ) {
        // The same colour as the ground is already painted, padding included.
        guard let color, endCol > startCol, color != chrome.content else { return }
        var rect = CGRect(
            x: CGFloat(startCol) * cellSize.width,
            y: CGFloat(row) * cellSize.height,
            width: CGFloat(endCol - startCol) * cellSize.width,
            height: cellSize.height)
        if startCol == edges.region.lowerBound {
            rect.origin.x -= edges.padding
            rect.size.width += edges.padding
        }
        if endCol == edges.region.upperBound { rect.size.width += edges.padding }
        if row == edges.top {
            rect.origin.y -= edges.above
            rect.size.height += edges.above
        }
        if row == edges.bottom { rect.size.height += edges.padding }
        color.setFill()
        context.fill(rect)
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

            // Segmented on every cell, including the blank ones. A space has
            // no glyph but it still has a style, and skipping it before this
            // comparison got both ends of that wrong: an underlined space drew
            // no underline, and an underlined word, a plain gap and another
            // underlined word became a single run — with the gap underlined
            // too, because `decorate` fills from the first column to the last.
            let key = (fg: cell.fg, bg: cell.bg, modifier: cell.modifier)
            if runStyle == nil || runStyle! != key {
                flush()
                runStyle = key
            }
            // Blank rather than absent: it belongs to the run for the
            // decoration's sake, and `GlyphRun` draws nothing for it.
            let text = grid.glyph(cell)
            runCells.append((column: col, text: text == " " ? "" : text))
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

    /// Draws the composition in progress, at the cursor.
    ///
    /// It is not in the surface — the server has never been told about it — so
    /// it is painted over whatever cells it covers, and underlined the way
    /// every other Mac text view marks text that is not committed yet.
    ///
    /// Drawn as text rather than through the cell path: a candidate is usually
    /// exactly the kind of script the base font does not carry, and it is one
    /// short string once a frame rather than a grid.
    private func drawMarkedText(_ grid: GridView, in context: CGContext) {
        guard let markedText, !markedText.isEmpty else { return }
        let origin = CGPoint(
            x: CGFloat(grid.cursor.x) * cellSize.width,
            y: CGFloat(grid.cursor.y) * cellSize.height)
        let text = NSAttributedString(
            string: markedText,
            attributes: [
                .font: baseFont,
                .foregroundColor: theme.foreground,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        // Cleared first: the cells underneath still hold whatever the pane
        // last drew there, and a composition over the top of it is unreadable.
        let size = text.size()
        context.setFillColor(theme.background.cgColor)
        context.fill(
            CGRect(x: origin.x, y: origin.y, width: size.width, height: cellSize.height))
        text.draw(at: origin)
    }

    /// Where the cursor is in this view, for placing a candidate window.
    ///
    /// The first cell when there is no surface to ask: a candidate list has to
    /// go somewhere, and the corner of the terminal is a better guess than the
    /// corner of the screen, which is where AppKit puts it otherwise.
    func cursorRect() -> NSRect {
        let cell = session?.withGrid { grid in
            CGPoint(x: CGFloat(grid.cursor.x), y: CGFloat(grid.cursor.y))
        } ?? .zero
        return NSRect(
            x: contentOrigin.x + cell.x * cellSize.width,
            y: contentOrigin.y + cell.y * cellSize.height,
            width: cellSize.width, height: cellSize.height)
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

        // While an input method is composing, every key is its business:
        // return commits a candidate, the arrows move through the list, escape
        // abandons it. None of that is the pane's until it is committed.
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }

        guard let mapped = KeyMapper.map(event) else {
            // Not a key with a semantic name, so it is text — and text an
            // input method may still be building towards. `event.characters`
            // here is the keystroke, not what it is composing, so it goes to
            // the input context and only `insertText` reaches the pane.
            interpretKeyEvents([event])
            return
        }
        dismissSelectionAndCopyMode()
        session.send(
            key: mapped.kind, codepoint: mapped.codepoint, modifiers: mapped.modifiers, to: pane)
    }

    /// Dismisses the local selection, and copy mode with it, before input is
    /// forwarded to a program.
    ///
    /// A plain click in a pane that is not reporting the mouse used to be the
    /// only way out, so a select-all over an editor or an agent — whose clicks
    /// belong to the program — stayed grey for good. Keys, committed text,
    /// paste and a left press the program receives all dismiss it. Right and
    /// middle presses and the scroll wheel do not: scrolling through history
    /// to extend or check a selection is the ordinary thing to do. This is a
    /// local decision, made before the send, whether or not delivery succeeds.
    ///
    /// Copy mode is left rather than only having its highlight cleared: its
    /// anchor would otherwise still be yanked by `y`, and the next motion or a
    /// late reply would paint the highlight straight back.
    func dismissSelectionAndCopyMode() {
        if copyMode != nil { return exitCopyMode() }
        guard selection != nil else { return }
        selection = nil
        needsDisplay = true
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
        let origin = contentOrigin
        let column = Int((point.x - origin.x) / cellSize.width)
        let row = Int((point.y - origin.y) / cellSize.height)

        let pane = panes.first {
            column >= $0.rect.x && column < $0.rect.x + $0.rect.width
                && row >= $0.rect.y && row < $0.rect.y + $0.rect.height
        }
        guard let pane else { return nil }
        return (pane, column, row)
    }

    /// One mouse report, in the coordinates the program in the pane expects.
    ///
    /// Pane-local, not surface-local. The server hands the position straight to
    /// the addressed pane's emulator without subtracting anything, so a pane
    /// twenty columns across the surface was telling its program every click
    /// was twenty columns further right than it was — which is every click in
    /// the wrong place for anything that reads the mouse. herdr's own client
    /// subtracts `inner_rect` here, and this follows it, including the clamp:
    /// a press on a pane's border belongs to the nearest cell inside it rather
    /// than to a cell that is not there.
    ///
    /// The geometry is the pane's too. A program using SGR pixel mouse sizes
    /// its own coordinate space from it, and the whole surface's dimensions
    /// describe a pane that does not exist.
    private func mouseEvent(
        _ event: NSEvent, kind: UInt16, button: UInt8, in pane: PaneView, column: Int, row: Int,
        lines: Int = 0
    ) -> HxMouseEvent {
        let inner = pane.inner
        let localColumn = min(max(column - Int(inner.x), 0), max(Int(inner.width) - 1, 0))
        let localRow = min(max(row - Int(inner.y), 0), max(Int(inner.height) - 1, 0))

        // Pixels against the pane's own origin, clamped to its own box, so the
        // two spaces agree about which pane they are describing.
        let point = convert(event.locationInWindow, from: nil)
        let paneOriginX = contentOrigin.x + CGFloat(inner.x) * cellSize.width
        let paneOriginY = contentOrigin.y + CGFloat(inner.y) * cellSize.height
        let paneWidth = CGFloat(inner.width) * cellSize.width
        let paneHeight = CGFloat(inner.height) * cellSize.height
        let localX = min(max(point.x - paneOriginX, 0), max(paneWidth - 1, 0))
        let localY = min(max(point.y - paneOriginY, 0), max(paneHeight - 1, 0))

        return HxMouseEvent(
            kind: kind,
            button: button,
            column: UInt16(localColumn),
            row: UInt16(localRow),
            pixel_x: UInt32(localX),
            pixel_y: UInt32(localY),
            cols: UInt16(max(inner.width, 0)),
            rows: UInt16(max(inner.height, 0)),
            width_px: UInt32(paneWidth),
            height_px: UInt32(paneHeight),
            modifiers: KeyMapper.modifiers(event.modifierFlags),
            lines: UInt16(max(lines, 0)))
    }

    /// Sends one report to the pane a gesture belongs to.
    ///
    /// `owner` is the pane the press went down in. Given one, the whole
    /// gesture goes there whatever the pointer is now over — a drag that
    /// leaves its pane is still that pane's drag, and the button it put down
    /// has to come back up in the same place. Hit-testing each event instead
    /// handed the neighbour a drag it never started and left the first pane
    /// waiting for a release that went somewhere else; a release outside every
    /// pane was dropped entirely, which is a button held down for good.
    ///
    /// Without an owner — a press, or a scroll, which is not a gesture — the
    /// pane under the pointer is the right answer.
    private func send(_ event: NSEvent, kind: UInt16, button: UInt8) {
        let owner: MouseReportOwner?
        if kind == UInt16(HX_MOUSE_DOWN) {
            // The press chooses the pane, and everything until the release
            // goes there.
            guard let hit = hit(event) else { return }
            owner = MouseReportOwner(
                paneID: hit.pane.id, session: session?.token,
                endpoint: session?.activeEndpoint)
            reportOwners[button] = owner
        } else {
            // A drag or a release with no press is not this view's to invent.
            // It happens — a click that only brought the window forward, a
            // button already down when the surface was replaced — and
            // hit-testing it sends a program a release it never asked for.
            owner = reportOwners[button]
            if kind == UInt16(HX_MOUSE_UP) { reportOwners[button] = nil }
        }
        guard let owner else { return }
        // The machine must still be the one the button went down on, and the
        // pane must still exist. Neither is true after a surface swap, and the
        // old behaviour then fell back to hit-testing — which aimed the
        // release at whatever replaced it.
        guard session?.token == owner.session, session?.activeEndpoint == owner.endpoint,
            let pane = panes.first(where: { $0.id == owner.paneID })
        else { return }
        // Still measured from the pointer; `mouseEvent` clamps it into the
        // owner, which is what makes a drag past the edge report the edge
        // rather than a cell in somebody else's pane.
        let cell = cellLocation(of: event)
        let target = (
            pane: pane, column: cell?.column ?? Int(pane.inner.x),
            row: cell?.row ?? Int(pane.inner.y)
        )
        let report = mouseEvent(
            event, kind: kind, button: button, in: target.pane, column: target.column,
            row: target.row)
        mouseReportForTesting?(kind, target.pane.id, report)
        // Clicking an unfocused pane focuses it. herdr leaves this to the
        // client shell, which is us.
        if kind == UInt16(HX_MOUSE_DOWN), !target.pane.focused {
            onFocusPane?(target.pane.id)
        }
        session?.send(mouse: report, to: target.pane.id)
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

    /// Where the pointer is in surface cells, whichever pane that lands in.
    private func cellLocation(of event: NSEvent) -> (column: Int, row: Int)? {
        guard cellSize.width > 0, cellSize.height > 0 else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        let origin = contentOrigin
        return (
            Int(floor((location.x - origin.x) / cellSize.width)),
            Int(floor((location.y - origin.y) / cellSize.height))
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if gesture != nil { return }
        if event.modifierFlags.contains(.command), event.clickCount == 1,
            let target = link(at: convert(event.locationInWindow, from: nil)) {
            pressedLink = target
            gesture = .link
            pressedRevision = lastRevision
            pressedEndpoint = session?.activeEndpoint
            pressedSession = session
            linkPressCancelled = false
            return
        }
        guard let hit = hit(event) else { return }

        if dragSelectsText(event, pane: hit.pane) {
            // Copy mode is a way of making a selection, and so is this, so
            // only one of them can be the selection. Leaving copy mode up
            // left two: the highlight followed the mouse while `y` still
            // copied copy mode's own anchor and cursor, and a motion reply
            // arriving afterwards repainted the span the mouse had replaced.
            // Ending it here also makes that reply stale, so it does nothing.
            if copyMode != nil { exitCopyMode() }
            gesture = .selecting(paneID: hit.pane.id)
            switch event.clickCount {
            case 2: selectWord(in: hit.pane, column: hit.column, row: hit.row)
            case 3...: selectLine(in: hit.pane, row: hit.row)
            default:
                let start = point(in: hit.pane, column: hit.column, row: hit.row)
                selection = Selection(
                    paneID: hit.pane.id,
                    anchor: start,
                    cursor: start,
                    origin: .click)
            }
            needsDisplay = true
            if !hit.pane.focused { onFocusPane?(hit.pane.id) }
            return
        }
        gesture = .reporting(paneID: hit.pane.id)
        dismissSelectionAndCopyMode()
        send(event, kind: UInt16(HX_MOUSE_DOWN), button: UInt8(HX_BUTTON_LEFT))
    }

    override func mouseUp(with event: NSEvent) {
        let finished = gesture
        gesture = nil
        switch finished {
        case .link:
            defer {
                pressedRevision = nil
                pressedLink = nil
                pressedEndpoint = nil
                pressedSession = nil
                linkPressCancelled = false
            }
            guard let pressedLink else { return }
            if !linkPressCancelled,
                pressedRevision == lastRevision,
                pressedEndpoint == session?.activeEndpoint,
                (session == nil ? pressedEndpoint == nil : pressedSession === session),
                event.modifierFlags.contains(.command),
                let current = link(at: convert(event.locationInWindow, from: nil)),
                current == pressedLink {
                openLink(current.url)
            }
        case .selecting:
            // An empty selection is just a click; clear it so a stray highlight
            // does not linger.
            if selection?.isEmpty == true { selection = nil; needsDisplay = true }
        case .reporting:
            send(event, kind: UInt16(HX_MOUSE_UP), button: UInt8(HX_BUTTON_LEFT))
        case nil:
            // No press of ours, so no release of ours. `send` would refuse it
            // anyway for want of an owner; saying so here is cheaper than
            // finding out there.
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch gesture {
        case .link:
            linkPressCancelled = true
        case .selecting(let paneID):
            // Measured against the pane the press began in rather than
            // whatever is under the pointer now. Dragging into a neighbour
            // used to take that pane's rect and scrollback offset and store
            // the result in this pane's selection, so a copy asked for rows
            // that were never highlighted.
            guard selection != nil, let owner = panes.first(where: { $0.id == paneID }),
                let cell = cellLocation(of: event)
            else { return }
            selection?.extend(to: point(in: owner, column: cell.column, row: cell.row))
            needsDisplay = true
        case .reporting:
            send(event, kind: UInt16(HX_MOUSE_DRAG), button: UInt8(HX_BUTTON_LEFT))
        case nil:
            break
        }
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
        dismissSelectionAndCopyMode()
        session.send(paste: text, to: pane)
    }

    override func selectAll(_ sender: Any?) {
        guard let pane = panes.first(where: { $0.id == focusedPane }) else { return }
        // The same handover a mouse selection makes. Copy mode is a way of
        // making a selection and so is this, so leaving it up left two: the
        // whole pane lit while `y` copied copy mode's own anchor and cursor,
        // and a motion still in flight repainting over it afterwards.
        if copyMode != nil { exitCopyMode() }
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

    // Without these a program using button-motion reporting saw the press and
    // the release and nothing in between, so a right- or middle-drag did
    // whatever a click does. `send` routes them to the pane the button went
    // down in, like the left one.
    override func rightMouseDragged(with event: NSEvent) {
        send(event, kind: UInt16(HX_MOUSE_DRAG), button: UInt8(HX_BUTTON_RIGHT))
    }

    override func otherMouseDown(with event: NSEvent) {
        send(event, kind: UInt16(HX_MOUSE_DOWN), button: UInt8(HX_BUTTON_MIDDLE))
    }

    override func otherMouseUp(with event: NSEvent) {
        send(event, kind: UInt16(HX_MOUSE_UP), button: UInt8(HX_BUTTON_MIDDLE))
    }

    override func otherMouseDragged(with event: NSEvent) {
        send(event, kind: UInt16(HX_MOUSE_DRAG), button: UInt8(HX_BUTTON_MIDDLE))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let session, let hit = hit(event) else { return }
        hoveredLink = nil
        if ownsLinkGesture { linkPressCancelled = true }

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
                event, kind: UInt16(kind), button: UInt8(HX_BUTTON_LEFT), in: hit.pane,
                column: hit.column, row: hit.row, lines: Int(abs(delta))),
            to: hit.pane.id)
    }
}
