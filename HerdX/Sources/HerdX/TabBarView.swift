import AppKit

/// The focused workspace's tabs, across the top of the terminal.
///
/// Tabs live here rather than in the sidebar because they are a different kind
/// of thing: the sidebar answers "which machine and project", which is a list
/// you scan, while tabs are the thing you flick between constantly. Nesting
/// them made every level of the tree look selected at once.
final class TabBarView: NSView {
    static let height: CGFloat = 34

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?

    private let stack = NSStackView()
    private var chrome = Chrome(theme: .dark)
    private var lastSignature: String?

    /// Drawn rather than set on the layer: a layer background is not part of
    /// the view's own drawing, which makes it invisible to anything that
    /// renders the hierarchy through `draw`, including the offscreen capture.
    override func draw(_ dirtyRect: NSRect) {
        chrome.content.setFill()
        dirtyRect.fill()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 8)
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

    func apply(chrome: Chrome) {
        self.chrome = chrome
        needsDisplay = true
        lastSignature = nil
    }

    /// Shows the tabs of whichever workspace is focused.
    ///
    /// `priority` carries this client's own idea of which finishes have been
    /// seen, so a tab's dot says the same thing the sidebar's does.
    func update(with snapshot: Snapshot?, priority: AgentPriority, endpoint: Int) {
        let tabs = snapshot.map { snapshot in
            snapshot.tabs.filter { $0.workspaceID == snapshot.focusedWorkspaceID }
        } ?? []
        let agents = snapshot?.agents ?? []
        let status = { (tab: Snapshot.Tab) in
            priority.status(
                of: agents.filter { $0.tabID == tab.tabID }, on: endpoint,
                fallback: tab.agentStatus)
        }

        let signature =
            tabs
            .map { "\($0.tabID):\($0.label):\($0.focused):\(status($0))" }
            .joined(separator: "|")
        guard lastSignature != signature else { return }
        lastSignature = signature
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tab in tabs {
            stack.addArrangedSubview(
                TabChip(
                    tab: tab, status: status(tab), chrome: chrome,
                    onSelect: { [weak self] in self?.onSelectTab?(tab.tabID) },
                    onClose: { [weak self] in self?.onCloseTab?(tab.tabID) }))
        }

        let add = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
                ?? NSImage(), target: self, action: #selector(newTab))
        add.isBordered = false
        add.contentTintColor = chrome.secondary
        stack.addArrangedSubview(add)
    }

    @objc private func newTab() { onNewTab?() }
}

/// One tab.
private final class TabChip: NSView {
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let focused: Bool
    private let chrome: Chrome
    private var hovered = false
    private var trackingArea: NSTrackingArea?
    private let close = NSButton()

    init(
        tab: Snapshot.Tab, status: Snapshot.AgentStatus, chrome: Chrome,
        onSelect: @escaping () -> Void, onClose: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onClose = onClose
        focused = tab.focused
        self.chrome = chrome
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6

        let dot = StatusDot()
        dot.set(status: status, chrome: chrome)

        // herdr's label is what the TUI shows; the number is internal and
        // usually the same, which read as "1 1".
        let title = tab.label.isEmpty ? "\(tab.number)" : tab.label
        let label = NSTextField(labelWithString: tab.zoomed ? "\(title) ⤢" : title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = focused ? chrome.primary : chrome.secondary

        var views: [NSView] = [dot, label]

        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        close.isBordered = false
        close.contentTintColor = chrome.tertiary
        close.target = self
        close.action = #selector(closeTab)
        // Only shown on hover, so a row of tabs is not a row of buttons.
        close.isHidden = true
        views.append(close)

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 7)
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
        // The active tab is tinted toward the accent rather than filled with
        // it: a saturated chip beside a terminal pulls the eye away from the
        // output, which is the thing actually worth looking at.
        let fill: NSColor? = focused ? chrome.accentFill : (hovered ? chrome.hover : nil)
        layer?.backgroundColor = fill?.cgColor
    }
}
