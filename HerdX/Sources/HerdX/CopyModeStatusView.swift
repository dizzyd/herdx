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

    func apply(theme: Theme) {
        let onDark = theme.background.isDarkish
        layer?.backgroundColor = (onDark ? NSColor.white : NSColor.black)
            .withAlphaComponent(0.14).cgColor
        label.textColor = theme.foreground
    }
}
