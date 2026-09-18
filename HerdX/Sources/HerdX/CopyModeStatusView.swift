import AppKit

/// A small floating strip showing copy-mode state.
///
/// It floats over the terminal rather than taking a row from it: entering copy
/// mode should not reflow the grid and push output around.
final class CopyModeStatusView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 6
        isHidden = true

        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ status: String?) {
        guard let status else {
            isHidden = true
            return
        }
        label.stringValue = status
        isHidden = false
    }

    /// Coloured to be legible whatever the palette turns out to be.
    ///
    /// It floats over the terminal, and every previous attempt picked one of
    /// the two palettes and got it wrong for somebody: the Mac light/dark theme
    /// put dark text on a dark pane, and a tint of the terminal's own colours
    /// is only as distinct as those colours happen to be. So the fill is the
    /// accent at full strength and the text is whichever of black or white
    /// stands out against it, which cannot come out the same shade as the
    /// thing behind it.
    func apply(chrome: Chrome) {
        let fill = chrome.accent
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = 0
        label.textColor = fill.isDarkish ? .white : .black
    }
}
