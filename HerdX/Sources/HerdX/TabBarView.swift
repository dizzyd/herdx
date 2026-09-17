import AppKit

/// The focused workspace's tabs, across the top of the terminal.
///
/// Tabs live here rather than in the sidebar because they are a different kind
/// of thing: the sidebar answers "which machine and project", which is a list
/// you scan, while tabs are the thing you flick between constantly. Nesting
/// them made every level of the tree look selected at once.
final class TabBarView: NSView {
    static let height: CGFloat = 30

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?

    private let stack = NSStackView()
    private var theme: Theme = .dark
    private var lastSignature: String?

    /// Drawn rather than set on the layer: a layer background is not part of
    /// the view's own drawing, which makes it invisible to anything that
    /// renders the hierarchy through `draw`, including the offscreen capture.
    override func draw(_ dirtyRect: NSRect) {
        let tint: NSColor = theme.background.isDarkish ? .white : .black
        (theme.background.blended(withFraction: 0.05, of: tint) ?? theme.background).setFill()
        dirtyRect.fill()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(theme: Theme) {
        self.theme = theme
        needsDisplay = true
        lastSignature = nil
    }

    /// Shows the tabs of whichever workspace is focused.
    func update(with snapshot: Snapshot?) {
        let tabs = snapshot.map { snapshot in
            snapshot.tabs.filter { $0.workspaceID == snapshot.focusedWorkspaceID }
        } ?? []

        let signature = tabs.map { "\($0.tabID):\($0.label):\($0.focused):\($0.agentStatus)" }
            .joined(separator: "|")
        guard lastSignature != signature else { return }
        lastSignature = signature
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tab in tabs {
            stack.addArrangedSubview(
                TabChip(
                    tab: tab, onDark: theme.background.isDarkish,
                    onSelect: { [weak self] in self?.onSelectTab?(tab.tabID) },
                    onClose: { [weak self] in self?.onCloseTab?(tab.tabID) }))
        }

        let add = NSButton(title: "+", target: self, action: #selector(newTab))
        add.bezelStyle = .inline
        add.isBordered = false
        add.font = .systemFont(ofSize: 14)
        add.contentTintColor = .secondaryLabelColor
        stack.addArrangedSubview(add)
    }

    @objc private func newTab() { onNewTab?() }
}

/// One tab.
private final class TabChip: NSView {
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let focused: Bool
    private let onDark: Bool
    private var hovered = false
    private var trackingArea: NSTrackingArea?
    private let close = NSButton(title: "×", target: nil, action: nil)

    init(
        tab: Snapshot.Tab, onDark: Bool, onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onClose = onClose
        focused = tab.focused
        self.onDark = onDark
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5

        let dot = NSTextField(labelWithString: "●")
        dot.font = .systemFont(ofSize: 7)
        dot.textColor = SidebarRow.color(for: tab.agentStatus, onDark: onDark)

        // herdr's label is what the TUI shows; the number is internal and
        // usually the same, which read as "1 1".
        let title = tab.label.isEmpty ? "\(tab.number)" : tab.label
        let label = NSTextField(labelWithString: tab.zoomed ? "\(title) ⤢" : title)
        label.font = .systemFont(ofSize: 11, weight: focused ? .semibold : .regular)
        label.textColor = focused ? .labelColor : .secondaryLabelColor

        close.isBordered = false
        close.font = .systemFont(ofSize: 10)
        close.contentTintColor = .tertiaryLabelColor
        close.target = self
        close.action = #selector(closeTab)
        // Only shown on hover, so a row of tabs is not a row of buttons.
        close.isHidden = true

        let row = NSStackView(views: [dot, label, close])
        row.orientation = .horizontal
        row.spacing = 5
        row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        close.isHidden = false
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        close.isHidden = true
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) { onSelect() }

    @objc private func closeTab() { onClose() }

    private func updateBackground() {
        let alpha: CGFloat = focused ? 0.16 : (hovered ? 0.08 : 0)
        layer?.backgroundColor = (onDark ? NSColor.white : NSColor.black)
            .withAlphaComponent(alpha).cgColor
    }
}
