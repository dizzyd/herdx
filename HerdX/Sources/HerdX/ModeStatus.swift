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
    private let panel: NSPanel
    private let view = CopyModeStatusView()
    private weak var parent: NSWindow?
    /// The terminal, which is what the strip is centred over.
    ///
    /// Measured rather than assumed: a fixed offset from the window's corner
    /// does not know that the sidebar can be collapsed or the split dragged.
    private weak var target: NSView?

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

    /// Remembers the window to sit above and the view to centre over. The
    /// panel itself is not added until there is something to show, because
    /// ordering a child window out detaches it again and leaves it to be
    /// re-added anyway.
    func attach(to parent: NSWindow, over target: NSView) {
        self.parent = parent
        self.target = target
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

    /// Centres it over the terminal as the window moves and resizes.
    ///
    /// Unconditional: guarding on the panel already being visible meant it was
    /// never placed at the one moment that matters, the frame before it is
    /// first shown, so it appeared in the corner of the display instead.
    func reposition() {
        guard let parent, let target else { return }
        let inWindow = target.convert(target.bounds, to: nil)
        let onScreen = parent.convertToScreen(inWindow)
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: (onScreen.midX - size.width / 2).rounded(),
                y: (onScreen.midY - size.height / 2).rounded()))
    }
}
