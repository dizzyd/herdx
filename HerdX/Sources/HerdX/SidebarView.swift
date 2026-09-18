import AppKit

/// One clickable row in the sidebar.
///
/// Two lines, like herdr's own list: the name you are looking for on top and
/// the context that distinguishes two rows with the same name underneath. A
/// single line forced "paperless-go" and "paperless-go" to be told apart by a
/// truncated suffix.
final class SidebarRow: NSView {
    enum Target {
        case endpoint(Int)
        case workspace(String, endpoint: Int)
        case tab(String)
        case pane(String)
    }

    let target: Target
    private let onSelect: (Target) -> Void
    /// Raised by the disclosure triangle, which acts on the row without
    /// selecting it.
    private let onToggle: (() -> Void)?
    private var hovered = false
    private let selected: Bool
    private let chrome: Chrome
    private var trackingArea: NSTrackingArea?

    init(
        title: String,
        subtitle: String?,
        status: Snapshot.AgentStatus,
        symbol: String?,
        collapsed: Bool?,
        selected: Bool,
        chrome: Chrome,
        target: Target,
        onSelect: @escaping (Target) -> Void,
        onToggle: (() -> Void)? = nil
    ) {
        self.target = target
        self.selected = selected
        self.chrome = chrome
        self.onSelect = onSelect
        self.onToggle = onToggle
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6

        // Both kinds of row use the same two columns, so a workspace's dot
        // sits under its machine's glyph and their names start at the same x.
        // Indenting the workspaces instead left their names starting to the
        // *left* of the machine's, which read as the wrong way round.
        var leading: [NSView] = []

        let chevron = NSButton(
            image: collapsed.flatMap {
                Self.symbol($0 ? "chevron.right" : "chevron.down", size: 9)
            } ?? NSImage(), target: self, action: #selector(toggle))
        chevron.isBordered = false
        chevron.contentTintColor = chrome.tertiary
        chevron.isEnabled = collapsed != nil
        chevron.widthAnchor.constraint(equalToConstant: 12).isActive = true
        leading.append(chevron)

        let marker: NSView
        if let symbol, let image = Self.symbol(symbol, size: 11) {
            let glyph = NSImageView(image: image)
            glyph.contentTintColor = chrome.secondary
            marker = glyph
        } else {
            let dot = StatusDot()
            dot.set(status: status, chrome: chrome)
            let box = NSView()
            box.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                dot.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                box.heightAnchor.constraint(equalTo: dot.heightAnchor),
            ])
            marker = box
        }
        marker.widthAnchor.constraint(equalToConstant: 15).isActive = true
        leading.append(marker)

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = chrome.primary
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let caption = NSTextField(labelWithString: subtitle ?? "")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = chrome.tertiary
        caption.lineBreakMode = .byTruncatingTail
        caption.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        caption.isHidden = (subtitle ?? "").isEmpty

        let lines = NSStackView(views: [name, caption])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1

        let row = NSStackView(views: leading + [lines])
        row.orientation = .horizontal
        // The glyph sits beside the pair of lines, aligned with the first of
        // them rather than floating in the middle of both.
        row.alignment = .top
        row.spacing = 6

        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        // The glyph column aligns with the name, not the top of the row's box.
        for view in leading {
            view.centerYAnchor.constraint(equalTo: name.centerYAnchor).isActive = true
        }
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }

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

    @objc private func toggle() { onToggle?() }

    private func updateBackground() {
        let fill: NSColor? = selected ? chrome.raised : (hovered ? chrome.hover : nil)
        layer?.backgroundColor = fill?.cgColor
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
    /// The width it opens at. Not a constraint: pinning it meant the split
    /// view offered a drag handle it could never honour.
    static let width: CGFloat = 240
    static let minimumWidth: CGFloat = 170
    static let maximumWidth: CGFloat = 420

    /// Raised when a row is clicked, with the method needed to focus it.
    var onSelect: ((Command) -> Void)?
    /// Raised when a machine is clicked.
    var onSelectEndpoint: ((Int) -> Void)?
    /// Raised when a workspace is clicked, with the machine it belongs to.
    var onSelectWorkspace: ((String, Int) -> Void)?

    private let stack = NSStackView()
    /// What the rows were last built from, so they are not rebuilt needlessly.
    private var lastSignature: String?
    private var chrome = Chrome(theme: .dark)
    /// Machines whose workspaces are hidden, by endpoint id.
    private var collapsed: Set<String> = []
    /// The last list built, so a collapse can rebuild without waiting for a
    /// snapshot to change.
    private var endpoints: [EndpointInfo] = []
    private var active = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 6, bottom: 12, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Sets the sidebar a shade back from the terminal, so the two halves of
    /// the window read as one surface rather than two apps.
    func apply(chrome: Chrome) {
        self.chrome = chrome
        layer?.backgroundColor = chrome.surface.cgColor
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
        }.joined(separator: "|") + "@\(active)+\(collapsed.sorted().joined(separator: ","))"
        guard lastSignature != signature else { return }
        lastSignature = signature
        self.endpoints = endpoints
        self.active = active

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for endpoint in endpoints {
            let isActive = endpoint.index == active
            addMachine(endpoint, isActive: isActive)
            guard !collapsed.contains(endpoint.id), let snapshot = endpoint.snapshot else {
                continue
            }
            for workspace in snapshot.workspaces {
                add(
                    title: workspace.label,
                    subtitle: [endpoint.label, workspace.branch]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    status: workspace.agentStatus,
                    symbol: nil,
                    collapsed: nil,
                    // Only the machine you are looking at has a selected
                    // workspace; the others are focused on their own server,
                    // which is not the same as being what you are looking at.
                    selected: isActive && workspace.focused,
                    target: .workspace(workspace.workspaceID, endpoint: endpoint.index))
            }
        }
    }

    private func addMachine(_ endpoint: EndpointInfo, isActive: Bool) {
        // A machine is highlighted only when none of its workspaces is, or the
        // sidebar shows two selections stacked on top of each other for what is
        // really one choice.
        let ownsSelection =
            isActive && !(endpoint.snapshot?.workspaces.contains { $0.focused } ?? false)

        let subtitle: String
        switch endpoint.status {
        case .connecting: subtitle = "connecting…"
        case .offline: subtitle = "not connected"
        case .online:
            let count = endpoint.snapshot?.workspaces.count ?? 0
            let spaces = count == 1 ? "1 space" : "\(count) spaces"
            // A machine you are not looking at can still say it needs you.
            let blocked = endpoint.snapshot?.agents.contains { $0.agentStatus == .blocked } ?? false
            subtitle = blocked ? "\(spaces) · needs attention" : spaces
        }

        add(
            title: endpoint.label,
            subtitle: subtitle,
            status: Self.machineStatus(endpoint),
            symbol: endpoint.isRemote ? "server.rack" : "desktopcomputer",
            collapsed: collapsed.contains(endpoint.id),
            selected: ownsSelection,
            target: .endpoint(endpoint.index),
            onToggle: { [weak self] in
                guard let self else { return }
                if self.collapsed.contains(endpoint.id) {
                    self.collapsed.remove(endpoint.id)
                } else {
                    self.collapsed.insert(endpoint.id)
                }
                self.update(endpoints: self.endpoints, active: self.active)
            })
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
        title: String,
        subtitle: String?,
        status: Snapshot.AgentStatus,
        symbol: String?,
        collapsed: Bool?,
        selected: Bool,
        target: SidebarRow.Target,
        onToggle: (() -> Void)? = nil
    ) {
        let row = SidebarRow(
            title: title, subtitle: subtitle, status: status, symbol: symbol,
            collapsed: collapsed, selected: selected, chrome: chrome, target: target,
            onSelect: { [weak self] target in
                switch target {
                case .endpoint(let index): self?.onSelectEndpoint?(index)
                case .workspace(let id, let endpoint):
                    // Clicking a workspace on another machine switches to it
                    // first, otherwise the command goes to the wrong server.
                    self?.onSelectWorkspace?(id, endpoint)
                case .tab(let id): self?.onSelect?(.focusTab(id))
                case .pane(let id): self?.onSelect?(.focusPane(id))
                }
            },
            onToggle: onToggle)
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
    }
}
