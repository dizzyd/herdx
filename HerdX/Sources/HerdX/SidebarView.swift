import AppKit

/// One clickable row in the sidebar.
final class SidebarRow: NSView {
    enum Target {
        case endpoint(Int)
        case workspace(String, endpoint: Int)
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

/// Machines and their workspaces.
///
/// Deliberately two levels deep. Nesting tabs and agents underneath made the
/// whole chain — workspace, tab, agent — highlight at once, since each is
/// "focused" in the snapshot, which reads as noise rather than as one
/// selection. Tabs live in the tab bar; agents show up as the status of the
/// workspace and tab that contain them.
final class SidebarView: NSView {
    static let width: CGFloat = 220

    /// Raised when a row is clicked, with the method needed to focus it.
    var onSelect: ((Command) -> Void)?
    /// Raised when a machine is clicked.
    var onSelectEndpoint: ((Int) -> Void)?
    /// Raised when a workspace is clicked, with the machine it belongs to.
    var onSelectWorkspace: ((String, Int) -> Void)?

    private let stack = NSStackView()
    /// What the rows were last built from, so they are not rebuilt needlessly.
    private var lastSignature: String?
    private var theme: Theme = .dark

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 6, bottom: 12, right: 6)
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
        lastSignature = nil
    }

    /// Rebuilds the machine list.
    ///
    /// Every attached machine lists its workspaces, like herdr's own sidebar:
    /// seeing what is running elsewhere without switching to it is the point of
    /// attaching to several machines at once.
    func update(endpoints: [EndpointInfo], active: Int) {
        // Snapshots are republished constantly and mostly change nothing the
        // sidebar shows; rebuilding every time would throw away hover state
        // mid-gesture.
        let signature = endpoints.map { endpoint in
            let workspaces = endpoint.snapshot?.workspaces
                .map { "\($0.workspaceID):\($0.label):\($0.branch ?? ""):\($0.focused):\($0.agentStatus)" }
                .joined(separator: ",") ?? ""
            return "\(endpoint.id):\(endpoint.status):\(workspaces)"
        }.joined(separator: "|") + "@\(active)"
        guard lastSignature != signature else { return }
        lastSignature = signature

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for endpoint in endpoints {
            let isActive = endpoint.index == active
            addMachine(endpoint, isActive: isActive)
            guard let snapshot = endpoint.snapshot else { continue }
            for workspace in snapshot.workspaces {
                add(
                    text: workspace.label,
                    detail: workspace.branch,
                    status: workspace.agentStatus,
                    // Only the machine you are looking at has a selected
                    // workspace; the others are focused on their own server,
                    // which is not the same as being what you are looking at.
                    selected: isActive && workspace.focused,
                    indent: 16,
                    target: .workspace(workspace.workspaceID, endpoint: endpoint.index))
            }
        }
    }

    private func addMachine(_ endpoint: EndpointInfo, isActive: Bool) {
        let detail: String?
        switch endpoint.status {
        case .connecting: detail = "connecting…"
        case .offline: detail = "offline"
        case .online:
            // A machine you are not looking at can still say it needs you.
            detail = endpoint.snapshot.flatMap { snapshot in
                snapshot.agents.contains { $0.agentStatus == .blocked }
                    ? "needs attention" : nil
            }
        }

        add(
            text: endpoint.label,
            detail: detail,
            status: Self.machineStatus(endpoint),
            selected: isActive,
            indent: 0,
            target: .endpoint(endpoint.index))
    }

    /// A machine's dot reflects its agents, falling back to its connection.
    private static func machineStatus(_ endpoint: EndpointInfo) -> Snapshot.AgentStatus {
        guard endpoint.status == .online else { return .unknown }
        guard let agents = endpoint.snapshot?.agents, !agents.isEmpty else { return .idle }
        if agents.contains(where: { $0.agentStatus == .blocked }) { return .blocked }
        if agents.contains(where: { $0.agentStatus == .working }) { return .working }
        return .idle
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
            case .endpoint(let index): self?.onSelectEndpoint?(index)
            case .workspace(let id, let endpoint):
                // Clicking a workspace on another machine switches to it first,
                // otherwise the command goes to the wrong server.
                self?.onSelectWorkspace?(id, endpoint)
            case .tab(let id): self?.onSelect?(.focusTab(id))
            case .pane(let id): self?.onSelect?(.focusPane(id))
            }
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
    }
}
