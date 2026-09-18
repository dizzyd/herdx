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

        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
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

    /// Coloured from the chrome, not from the window's appearance.
    ///
    /// It floats over the terminal, so the terminal is what it has to be
    /// legible against. Taking the Mac light/dark theme instead put dark text
    /// on a dark pane whenever the two did not agree.
    func apply(chrome: Chrome) {
        layer?.backgroundColor = chrome.accentFill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = chrome.accent.withAlphaComponent(0.6).cgColor
        label.textColor = chrome.primary
    }
}
