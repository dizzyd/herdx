import AppKit

/// One pane, as a real view.
///
/// The server composes a single grid for the whole tab and tells us where each
/// pane sits inside it, so these views all draw slices of one surface rather
/// than owning separate ones. Making them views anyway buys native hit-testing,
/// a real focus ring, and somewhere for per-pane scrollers, context menus and
/// accessibility to live later.
final class PaneContentView: NSView {
    private(set) var paneID: String
    /// Placement within the surface, in cells.
    private(set) var cellFrame: CellRect
    private(set) var isFocusedPane: Bool

    private unowned let owner: TerminalGridView

    override var isFlipped: Bool { true }
    /// Input stays with the container, which owns the keymap and selection.
    override var acceptsFirstResponder: Bool { false }

    init(paneID: String, owner: TerminalGridView) {
        self.paneID = paneID
        self.owner = owner
        cellFrame = CellRect(x: 0, y: 0, width: 0, height: 0)
        isFocusedPane = false
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Moves the view to match the pane's cells. Returns true if anything moved.
    @discardableResult
    func place(_ pane: PaneView, cellSize: CGSize) -> Bool {
        let frame = NSRect(
            x: CGFloat(pane.rect.x) * cellSize.width,
            y: CGFloat(pane.rect.y) * cellSize.height,
            width: CGFloat(pane.rect.width) * cellSize.width,
            height: CGFloat(pane.rect.height) * cellSize.height)

        let moved = frame != self.frame || pane.focused != isFocusedPane
        cellFrame = pane.rect
        isFocusedPane = pane.focused
        if frame != self.frame { self.frame = frame }
        return moved
    }

    // Deliberately no `draw`. Pane content is drawn by the grid view in one
    // pass, because relying on each child view to draw itself put the terminal
    // at the mercy of per-view invalidation and left panes blank. These views
    // exist for hit-testing and as somewhere for per-pane scrollers, context
    // menus and accessibility to live.
    override var isOpaque: Bool { false }

    // Mouse handling stays in the container: selection, click-to-focus and
    // scroll all need the surface as a whole, and splitting them across views
    // would just mean passing the same state back and forth.
    override func mouseDown(with event: NSEvent) { owner.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { owner.mouseUp(with: event) }
    override func mouseDragged(with event: NSEvent) { owner.mouseDragged(with: event) }
    override func rightMouseDown(with event: NSEvent) { owner.rightMouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { owner.rightMouseUp(with: event) }
    override func otherMouseDown(with event: NSEvent) { owner.otherMouseDown(with: event) }
    override func otherMouseUp(with event: NSEvent) { owner.otherMouseUp(with: event) }
    override func scrollWheel(with event: NSEvent) { owner.scrollWheel(with: event) }
}
