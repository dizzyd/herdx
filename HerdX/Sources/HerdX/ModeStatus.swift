import AppKit

/// The mode strip, in a window of its own above the terminal.
///
/// It began as a sibling of the split view, which is where it kept going
/// wrong: both are layer-backed, subview order alone does not settle which
/// layer composites on top, and every offscreen render said it was visible
/// because `cacheDisplay` draws subviews in order rather than compositing
/// layers. A child window is above its parent by definition, so there is no
/// ordering left to get wrong.
@MainActor
final class ModeStatus {
    /// How far in from the terminal's bottom-left corner it sits.
    private let inset = CGPoint(x: SidebarView.width + 12, y: 12)

    private let panel: NSPanel
    private let view = CopyModeStatusView()
    private weak var parent: NSWindow?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // It reports on the keyboard; it must never take it.
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true

        view.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }

    /// Remembers the window to sit above. The panel itself is not added until
    /// there is something to show, because ordering a child window out detaches
    /// it again and leaves it to be re-added anyway.
    func attach(to parent: NSWindow) {
        self.parent = parent
    }

    func apply(chrome: Chrome) { view.apply(chrome: chrome) }

    /// Whether the strip is actually on screen, which is the only question
    /// worth asking about it.
    var isVisible: Bool { panel.isVisible }

    /// Where it ended up, which is the other question worth asking: a panel
    /// that is visible but off the window's edge looks the same from inside.
    func describeFrame() -> String {
        "visible=\(panel.isVisible) frame=\(panel.frame) child=\(panel.parent != nil)"
    }

    /// Shows the strip, or hides it when there is nothing to say.
    func update(_ status: String?) {
        guard let status, !status.isEmpty else {
            panel.orderOut(nil)
            return
        }
        view.update(status)
        // Sized to the text before it is placed, or the first frame lands at
        // whatever the previous message measured.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.setContentSize(view.fittingSize)
        reposition()
        // Adding it as a child orders it in as well, so this is both the
        // attach and the show.
        parent?.addChildWindow(panel, ordered: .above)
    }

    /// Keeps it pinned to the terminal's corner as the window moves.
    ///
    /// Unconditional: guarding on the panel already being visible meant it was
    /// never placed at the one moment that matters, the frame before it is
    /// first shown, so it appeared in the corner of the display instead.
    func reposition() {
        guard let parent else { return }
        let frame = parent.frame
        panel.setFrameOrigin(
            NSPoint(x: frame.minX + inset.x, y: frame.minY + inset.y))
    }
}
