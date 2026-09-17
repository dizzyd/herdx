import AppKit

/// The colours the window chrome is drawn from.
///
/// Derived from the terminal palette rather than the system's, so the sidebar,
/// header and tab strip read as one surface with the terminal instead of a grey
/// Mac window wrapped around a dark one. The text colours are explicit for the
/// same reason: `labelColor` and friends follow the window's appearance, which
/// is a separate preference here and can leave dark text on a dark sidebar.
struct Chrome {
    /// Behind the sidebar, which sits a shade back from the terminal.
    var surface: NSColor
    /// Behind the header, tab strip and terminal: the terminal's own colour.
    var content: NSColor
    /// A selected sidebar row.
    var raised: NSColor
    var hover: NSColor
    var accent: NSColor
    /// The active tab, tinted toward the accent rather than filled with it.
    var accentFill: NSColor
    var primary: NSColor
    var secondary: NSColor
    var tertiary: NSColor
    var separator: NSColor
    var isDark: Bool

    init(theme: Theme) {
        let dark = theme.background.isDarkish
        let base = theme.background.usingColorSpace(.sRGB) ?? theme.background
        let text = theme.foreground.usingColorSpace(.sRGB) ?? theme.foreground
        // sRGB first: `controlAccentColor` is dynamic, and blending a dynamic
        // colour with a static one returns nil rather than a colour.
        let accentColor = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let tint: NSColor = dark ? .white : .black

        isDark = dark
        content = base
        // The sidebar is darker than the terminal, not lighter. A lighter one
        // makes the chrome the brightest thing on screen, which is exactly
        // backwards for a window whose content is a terminal.
        surface = base.blended(withFraction: dark ? 0.35 : 0.07, of: .black) ?? base
        raised = surface.blended(withFraction: 0.10, of: tint) ?? surface
        hover = surface.blended(withFraction: 0.05, of: tint) ?? surface
        accent = accentColor
        accentFill = base.blended(withFraction: 0.22, of: accentColor) ?? base
        primary = text
        secondary = text.withAlphaComponent(0.62)
        tertiary = text.withAlphaComponent(0.38)
        separator = tint.withAlphaComponent(dark ? 0.10 : 0.14)
    }

    /// herdr's whole point is knowing which agents need you, so blocked has to
    /// be the one that catches the eye.
    func color(for status: Snapshot.AgentStatus) -> NSColor {
        switch status {
        case .working: return isDark ? Theme.rgb(102, 178, 242) : Theme.rgb(20, 110, 200)
        case .blocked: return isDark ? Theme.rgb(242, 166, 64) : Theme.rgb(186, 106, 10)
        case .done: return isDark ? Theme.rgb(115, 204, 128) : Theme.rgb(30, 140, 60)
        case .idle, .unknown: return tertiary
        }
    }

    /// Idle agents get a ring and busy ones a disc, so a glance at the sidebar
    /// separates "there is something here" from "something is happening".
    func isFilled(_ status: Snapshot.AgentStatus) -> Bool {
        switch status {
        case .working, .blocked, .done: return true
        case .idle, .unknown: return false
        }
    }
}

/// A dot that is either a disc or a ring.
final class StatusDot: NSView {
    private var color: NSColor = .gray
    private var filled = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 8),
            heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(status: Snapshot.AgentStatus, chrome: Chrome) {
        color = chrome.color(for: status)
        filled = chrome.isFilled(status)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        if filled {
            color.setFill()
            circle.fill()
        } else {
            color.setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }
    }
}

/// A split view whose dividers take the chrome's colours.
///
/// `NSSplitView` otherwise draws a system grey line, which is the one seam that
/// gives away that the window is two surfaces rather than one.
final class ChromeSplitView: NSSplitView {
    /// Panels stacked inside one region want no visible seam at all.
    var seamless = false
    private var chrome = Chrome(theme: .dark)

    func apply(chrome: Chrome) {
        self.chrome = chrome
        needsDisplay = true
    }

    override var dividerColor: NSColor { seamless ? chrome.content : chrome.separator }
    override var dividerThickness: CGFloat { seamless ? 0 : 1 }
}
