import AppKit

/// The speaker at the foot of the sidebar, which mutes the agent sounds.
///
/// A shortcut to the switch in Settings rather than a second setting: it
/// reflects the preference and asks for it to be flipped, and nothing else.
/// Holding its own idea of whether sounds are on would be one more copy to
/// drift from the store, which is the mistake the Settings window already
/// stopped making.
///
/// Small and faint on purpose. Sound being on is the ordinary state and
/// deserves no attention; muted is the one worth a glance, since a mute you
/// have forgotten is the one that costs you an agent's question — so that is
/// the state drawn a shade stronger.
final class MuteButton: NSButton {
    /// What the preference says, set from outside. Changing it here changes
    /// the glyph, not the preference; `onToggle` is how the preference moves.
    var isMuted = false {
        didSet { if isMuted != oldValue { render() } }
    }
    /// Raised by a click. Whoever owns the preference flips it and then says
    /// what it became.
    var onToggle: (() -> Void)?

    /// What the glyph means, for anything that cannot see it: the tooltip,
    /// VoiceOver, and a test asking what the button is for.
    var purpose: String { isMuted ? "Unmute agent sounds" : "Mute agent sounds" }

    private var chrome = Chrome(theme: .dark)
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        // The same shape as the tab bar's "+": a bare glyph, no bezel.
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        render()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// None: a button's frame otherwise runs a couple of points past the rect
    /// the constraints place, which puts the hover fill off-centre and the
    /// glyph two points lower than the corner it was given.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    func apply(chrome: Chrome) {
        self.chrome = chrome
        render()
    }

    private func render() {
        let name = isMuted ? "speaker.slash" : "speaker.wave.2"
        image = NSImage(systemSymbolName: name, accessibilityDescription: purpose)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        contentTintColor = isMuted ? chrome.secondary : chrome.tertiary
        toolTip = purpose
        // Hover takes the rows' colour, so the corner reads as part of the
        // list rather than as a control dropped onto it.
        layer?.backgroundColor = hovered ? chrome.hover.cgColor : nil
    }

    @objc private func clicked() { onToggle?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovered = true
        render()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovered = false
        render()
    }
}
