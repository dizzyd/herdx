import AppKit

/// One pane, as a view that holds its place and nothing else.
///
/// Worth being plain about what this does today, because the name suggests
/// more. It draws nothing: the server composes one grid for the whole tab and
/// `TerminalGridView` paints all of it in a single pass. It takes no keyboard
/// input, and every mouse event it receives is handed straight back to the
/// container, which works out which pane the point is in by itself. So it
/// provides neither the hit-testing nor the focus ring an earlier version of
/// this comment claimed.
///
/// What it is, is a correctly positioned subview per pane — which is the part
/// that is awkward to add later. Per-pane scrollers, context menus and
/// accessibility all need somewhere to hang, and with these in place that is
/// a change of behaviour rather than a change of structure.
final class PaneContentView: NSView {
    private(set) var paneID: String

    private unowned let owner: TerminalGridView

    override var isFlipped: Bool { true }
    /// Input stays with the container, which owns the keymap and selection.
    override var acceptsFirstResponder: Bool { false }

    init(paneID: String, owner: TerminalGridView) {
        self.paneID = paneID
        self.owner = owner
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Moves the view to match the pane's cells.
    ///
    /// It returned whether anything had moved, and the one caller ignored it;
    /// it also kept the pane's cell rect and focus, which nothing read. Both
    /// are gone rather than left looking load-bearing.
    func place(_ pane: PaneView, cellSize: CGSize) {
        let frame = NSRect(
            x: CGFloat(pane.rect.x) * cellSize.width,
            y: CGFloat(pane.rect.y) * cellSize.height,
            width: CGFloat(pane.rect.width) * cellSize.width,
            height: CGFloat(pane.rect.height) * cellSize.height)
        if frame != self.frame { self.frame = frame }
    }

    // Deliberately no `draw`. Relying on each child view to draw itself put
    // the terminal at the mercy of per-view invalidation and left panes blank,
    // so the grid view paints the whole surface in one pass.
    override var isOpaque: Bool { false }

    // Mouse handling stays in the container: selection, click-to-focus and
    // scroll all need the surface as a whole, and splitting them across views
    // would just mean passing the same state back and forth.
    override func mouseDown(with event: NSEvent) { owner.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { owner.mouseUp(with: event) }
    override func mouseDragged(with event: NSEvent) { owner.mouseDragged(with: event) }
    override func rightMouseDown(with event: NSEvent) { owner.rightMouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { owner.rightMouseUp(with: event) }
    override func rightMouseDragged(with event: NSEvent) { owner.rightMouseDragged(with: event) }
    override func otherMouseDown(with event: NSEvent) { owner.otherMouseDown(with: event) }
    override func otherMouseUp(with event: NSEvent) { owner.otherMouseUp(with: event) }
    override func otherMouseDragged(with event: NSEvent) { owner.otherMouseDragged(with: event) }
    override func scrollWheel(with event: NSEvent) { owner.scrollWheel(with: event) }
    override func mouseMoved(with event: NSEvent) { owner.mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { owner.mouseEntered(with: event) }
    override func mouseExited(with event: NSEvent) { owner.mouseExited(with: event) }
}
