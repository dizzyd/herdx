import AppKit

/// One clickable row in the sidebar.
final class SidebarRow: NSView {
    enum Target {
        case workspace(String)
        case tab(String)
        case pane(String)
    }

    let target: Target
    private let onSelect: (Target) -> Void
    private var hovered = false
    private let selected: Bool
    private let onDark: Bool
    private var trackingArea: NSTrackingArea?

    init(
        text: String,
        detail: String?,
        status: Snapshot.AgentStatus,
        selected: Bool,
        indent: CGFloat,
        onDark: Bool,
        target: Target,
        onSelect: @escaping (Target) -> Void
    ) {
        self.target = target
        self.selected = selected
        self.onDark = onDark
        self.onSelect = onSelect
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5

        let dot = NSTextField(labelWithString: "●")
        dot.font = .systemFont(ofSize: 8)
        dot.textColor = Self.color(for: status, onDark: onDark)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.spacing = 6

        if let detail, !detail.isEmpty {
            let branch = NSTextField(labelWithString: detail)
            branch.font = .systemFont(ofSize: 10)
            branch.textColor = .tertiaryLabelColor
            branch.lineBreakMode = .byTruncatingTail
            branch.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            stack.addArrangedSubview(branch)
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6 + indent),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
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
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect(target)
    }

    private func updateBackground() {
        let alpha: CGFloat = selected ? 0.16 : (hovered ? 0.08 : 0)
        // Lightening works on a dark sidebar and darkening on a light one;
        // using white for both makes the highlight vanish in light mode.
        let tint: NSColor = onDark ? .white : .black
        layer?.backgroundColor = tint.withAlphaComponent(alpha).cgColor
    }

    /// herdr's whole point is knowing which agents need you, so blocked has to
    /// be the one that catches the eye.
    static func color(for status: Snapshot.AgentStatus, onDark: Bool) -> NSColor {
        switch status {
        case .working:
            return onDark ? Theme.rgb(102, 178, 242) : Theme.rgb(20, 110, 200)
        case .blocked:
            return onDark ? Theme.rgb(242, 166, 64) : Theme.rgb(186, 106, 10)
        case .done:
            return onDark ? Theme.rgb(115, 204, 128) : Theme.rgb(30, 140, 60)
        case .idle, .unknown:
            return onDark ? NSColor(white: 0.38, alpha: 1) : NSColor(white: 0.66, alpha: 1)
        }
    }
}

/// Native chrome driven by `ClientShellSnapshot`.
///
/// This is what a full-surface renderer cannot give you: the server sends
/// workspaces, tabs and agent status as structured JSON, so these are real rows
/// with real hit-testing and hover, not characters in a grid.
final class SidebarView: NSView {
    static let width: CGFloat = 220

    /// Raised when a row is clicked, with the method needed to focus it.
    var onSelect: ((Command) -> Void)?

    private let stack = NSStackView()
    private var lastRevision: UInt64?
    private var theme: Theme = .dark

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 6, bottom: 12, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Tints the sidebar to sit just off the terminal background, so the two
    /// panes of the window read as one surface rather than two apps.
    func apply(theme: Theme) {
        self.theme = theme
        layer?.backgroundColor = theme.background.blended(
            withFraction: 0.06,
            of: theme.background.isDarkish ? .white : .black)?.cgColor
        lastRevision = nil
    }

    func update(with snapshot: Snapshot) {
        // Snapshots are republished on every revision, most of which change
        // nothing the sidebar shows. Rebuilding the row views each time would
        // throw away hover state mid-gesture.
        guard lastRevision != snapshot.revision else { return }
        lastRevision = snapshot.revision

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for workspace in snapshot.workspaces {
            add(
                text: "\(workspace.number)  \(workspace.label)",
                detail: workspace.branch,
                status: workspace.agentStatus,
                selected: workspace.focused,
                indent: 0,
                target: .workspace(workspace.workspaceID))

            for tab in snapshot.tabs where tab.workspaceID == workspace.workspaceID {
                add(
                    text: tab.label.isEmpty ? "tab \(tab.number)" : tab.label,
                    detail: tab.zoomed ? "zoom" : nil,
                    status: tab.agentStatus,
                    selected: tab.focused,
                    indent: 14,
                    target: .tab(tab.tabID))

                let panesInTab = Set(
                    snapshot.panes.filter { $0.tabID == tab.tabID }.map(\.paneID))
                for agent in snapshot.agents where panesInTab.contains(agent.paneID) {
                    add(
                        text: agent.displayAgent ?? agent.title ?? "agent",
                        detail: nil,
                        status: agent.agentStatus,
                        selected: agent.focused,
                        indent: 28,
                        target: .pane(agent.paneID))
                }
            }
        }
    }

    private func add(
        text: String,
        detail: String?,
        status: Snapshot.AgentStatus,
        selected: Bool,
        indent: CGFloat,
        target: SidebarRow.Target
    ) {
        let row = SidebarRow(
            text: text, detail: detail, status: status, selected: selected,
            indent: indent, onDark: theme.background.isDarkish, target: target
        ) { [weak self] target in
            switch target {
            case .workspace(let id): self?.onSelect?(.focusWorkspace(id))
            case .tab(let id): self?.onSelect?(.focusTab(id))
            case .pane(let id): self?.onSelect?(.focusPane(id))
            }
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
    }
}
