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
        case pane(String, endpoint: Int)
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
        /// The whole of a message the subtitle only summarises.
        detail: String? = nil,
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
        toolTip = detail

        // Both kinds of row use the same two columns, so a workspace's dot
        // sits under its machine's glyph and their names start at the same x.
        // Indenting the workspaces instead left their names starting to the
        // *left* of the machine's, which read as the wrong way round.
        var leading: [NSView] = []

        // Only a machine has anything to disclose, so only a machine spends a
        // column on saying so.
        if let collapsed {
            let chevron = NSButton(
                image: Self.symbol(collapsed ? "chevron.right" : "chevron.down", size: 9)
                    ?? NSImage(), target: self, action: #selector(toggle))
            chevron.isBordered = false
            chevron.contentTintColor = chrome.tertiary
            chevron.widthAnchor.constraint(equalToConstant: 12).isActive = true
            leading.append(chevron)
        }

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
        // A machine is a heading over the rows that matter, not one of them.
        // Weighting both the same made the sidebar read as a flat list of
        // equals, with the machines shouting loudest — so a workspace keeps
        // the weight and a machine is set in italic instead, which separates
        // the two kinds of row without competing for attention.
        if collapsed == nil {
            name.font = .systemFont(ofSize: 12, weight: .semibold)
        } else {
            name.font = NSFontManager.shared.convert(
                .systemFont(ofSize: 12, weight: .regular), toHaveTrait: .italicFontMask)
        }
        name.textColor = chrome.primary
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Beside the name, not beneath it. A branch is a qualifier on the
        // workspace rather than a second thing to read, and stacking the two
        // made every row twice as tall as it needed to be.
        let caption = NSTextField(labelWithString: subtitle ?? "")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = chrome.tertiary
        caption.lineBreakMode = .byTruncatingTail
        caption.alignment = .right
        caption.isHidden = (subtitle ?? "").isEmpty
        // The name keeps its width and the qualifier gives way, because a
        // truncated name is the one thing that makes a row useless.
        caption.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        caption.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let row = NSStackView(views: leading + [name, caption])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6

        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            // A workspace starts where its machine's glyph does, so its dot
            // sits under that glyph and the two names line up. Letting the row
            // start at the margin instead put every workspace to the left of
            // the machine it belongs to, which reads as the wrong way round.
            row.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: collapsed == nil ? 26 : 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
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

/// A band heading in the agents list, with the rule that sets it off from the
/// band above it.
///
/// A heading and not just a gap: "these three are idle" is a fact about the
/// rows, and a blank line leaves the reader to infer it. The rule is what makes
/// the split read as a division rather than as loose spacing.
final class SidebarSection: NSView {
    let tier: AgentPriority.Tier

    init(tier: AgentPriority.Tier, rule: Bool, chrome: Chrome) {
        self.tier = tier
        super.init(frame: .zero)

        let label = NSTextField(labelWithString: tier.title.uppercased())
        // Small, faint and letterspaced, which is how a Mac sidebar says
        // "heading" without competing with the rows underneath it.
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = chrome.tertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        var top = topAnchor
        var gap: CGFloat = 4
        if rule {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = chrome.separator.cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            addSubview(line)
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                line.heightAnchor.constraint(equalToConstant: 1),
                line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            ])
            top = line.bottomAnchor
            gap = 6
        }

        NSLayoutConstraint.activate([
            // Lined up with the status dots rather than with the margin, so the
            // heading sits over the column it describes.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            label.topAnchor.constraint(equalTo: top, constant: gap),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Headings are scenery: a click belongs to whatever is under them, and
    /// letting one swallow it made the top row of a band unselectable.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    /// Raised when an agent is clicked, with the machine it belongs to.
    var onSelectPane: ((String, Int) -> Void)?

    /// How the list is arranged, as herdr's own panel puts it.
    enum Arrangement: String {
        /// Machines, and the workspaces under them.
        case spaces
        /// Every agent across every machine, most in need of you first.
        case priority
    }
    var arrangement: Arrangement = .spaces {
        didSet { if arrangement != oldValue { lastSignature = nil } }
    }
    /// Supplied by the app, which is what watches snapshots go by.
    /// Compared before invalidating, not merely assigned: a struct set every
    /// tick fires `didSet` every tick whether or not it changed, and throwing
    /// the signature away rebuilt every row sixty times a second. Rows built
    /// that often cannot be hovered or clicked — the one under the pointer is
    /// destroyed before the mouse comes back up.
    var priority = AgentPriority() {
        didSet { if priority != oldValue { lastSignature = nil } }
    }

    private let stack = NSStackView()
    private(set) var rebuilds = 0
    private let modes = NSSegmentedControl()
    /// Raised when the arrangement is switched, so it can be remembered.
    var onArrangementChanged: ((Arrangement) -> Void)?
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

        modes.segmentCount = 2
        modes.setLabel("Spaces", forSegment: 0)
        modes.setLabel("Agents", forSegment: 1)
        modes.segmentStyle = .rounded
        modes.trackingMode = .selectOne
        modes.selectedSegment = 0
        modes.target = self
        modes.action = #selector(modeChanged)
        modes.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 6, bottom: 12, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modes)
        addSubview(stack)
        NSLayoutConstraint.activate([
            // Centred in a band the height of the tab strip, so the switch and
            // the tabs sit on the same line by construction rather than by a
            // constant that has to be re-guessed whenever either moves.
            modes.centerYAnchor.constraint(
                equalTo: topAnchor, constant: TabBarView.height / 2),
            modes.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            modes.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: TabBarView.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func modeChanged() {
        arrangement = modes.selectedSegment == 1 ? .priority : .spaces
        onArrangementChanged?(arrangement)
        update(endpoints: endpoints, active: active)
    }

    /// Restores a remembered arrangement without announcing it back.
    func show(arrangement: Arrangement) {
        self.arrangement = arrangement
        modes.selectedSegment = arrangement == .priority ? 1 : 0
    }

    /// Sets the sidebar a shade back from the terminal, so the two halves of
    /// the window read as one surface rather than two apps.
    func apply(chrome: Chrome) {
        self.chrome = chrome
        layer?.backgroundColor = chrome.surface.cgColor
        // A system control draws itself for the appearance it is told it is
        // in, not for whatever is behind it — so on a dark sidebar under a
        // light system appearance the unselected segment was dark on dark.
        modes.appearance = NSAppearance(named: chrome.isDark ? .darkAqua : .aqua)
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
        let machines = endpoints.map { endpoint -> String in
            let workspaces = endpoint.snapshot?.workspaces
                .map { "\($0.workspaceID):\($0.label):\($0.branch ?? ""):\($0.focused):\($0.agentStatus)" }
                .joined(separator: ",") ?? ""
            return "\(endpoint.id):\(endpoint.status):\(endpoint.error ?? ""):\(workspaces)"
        }.joined(separator: "|")

        // The priority list is ordered by things the machine list does not
        // show, so it needs its own reasons to be rebuilt.
        var agents = ""
        if arrangement == .priority {
            let rows: [String] = endpoints.flatMap { endpoint -> [String] in
                let list = endpoint.snapshot?.agents ?? []
                return list.map { agent -> String in
                    let seen = priority.hasSeen(agent, on: endpoint.index)
                    // The band and the age are the reasons a row moves without
                    // anything on the wire changing — an agent crosses into
                    // "long idle" purely because time passed, and nothing else
                    // here would notice. Both are coarse, so including them
                    // costs a rebuild an hour rather than one a tick.
                    let tier = priority.tier(agent, on: endpoint.index).rawValue
                    let quiet = priority.quietFor(agent, on: endpoint.index) ?? ""
                    return "\(agent.paneID):\(agent.agentStatus):\(agent.stateChangeSeq):\(seen)"
                        + ":\(tier):\(quiet)"
                }
            }
            agents = rows.joined(separator: ",")
        }
        let collapsedKey = collapsed.sorted().joined(separator: ",")
        let signature =
            machines + "@\(active)+\(collapsedKey)+\(arrangement.rawValue)+" + agents
        guard lastSignature != signature else { return }
        lastSignature = signature
        self.endpoints = endpoints
        self.active = active

        rebuilds += 1
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if arrangement == .priority {
            addAgentsByPriority(endpoints)
            return
        }

        for endpoint in endpoints {
            let isActive = endpoint.index == active
            addMachine(endpoint, isActive: isActive)
            guard !collapsed.contains(endpoint.id), let snapshot = endpoint.snapshot else {
                continue
            }
            for workspace in snapshot.workspaces {
                add(
                    title: workspace.label,
                    // Not the machine: the row it sits under is the machine.
                    subtitle: workspace.branch,
                    status: priority.status(
                        of: snapshot.agents.filter { $0.workspaceID == workspace.workspaceID },
                        on: endpoint.index, fallback: workspace.agentStatus),
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

    /// Every agent on every machine, most in need of you first.
    ///
    /// Flat rather than grouped: the question this arrangement answers is
    /// "what needs me", and an answer sorted by where things live is the one
    /// the other arrangement already gives.
    ///
    /// Flat by *machine*, that is — the list is still banded by how recently
    /// each agent did anything, because on a machine that has been up a week
    /// everything finished collapses into one undifferentiated tail and the two
    /// agents from this morning are lost in it.
    private func addAgentsByPriority(_ endpoints: [EndpointInfo]) {
        let all = endpoints.flatMap { endpoint in
            (endpoint.snapshot?.agents ?? []).map { (endpoint, $0) }
        }
        guard !all.isEmpty else {
            add(
                title: "No agents", subtitle: nil, status: .unknown, symbol: nil,
                collapsed: nil, selected: false, target: .endpoint(0))
            return
        }

        let ordered = priority.ordered(all, agent: { $0.1 }, endpoint: { $0.0.index })
        // Headings only when there is more than one band to tell apart. A lone
        // "Active" over every row labels nothing and costs a line of the list.
        let tiers = ordered.map { priority.tier($0.1, on: $0.0.index) }
        let banded = Set(tiers).count > 1
        var band: AgentPriority.Tier?

        for (index, (endpoint, agent)) in ordered.enumerated() {
            if banded, tiers[index] != band {
                let section = SidebarSection(
                    tier: tiers[index], rule: band != nil, chrome: chrome)
                section.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(section)
                section.widthAnchor.constraint(
                    equalTo: stack.widthAnchor, constant: -12
                ).isActive = true
                band = tiers[index]
            }

            let workspace = endpoint.snapshot?.workspaces
                .first { $0.workspaceID == agent.workspaceID }?.label
            // "idle 3h" rather than "idle · 3h": how long it has been quiet is
            // part of what state it is in, not a second fact about it.
            let reason = [
                priority.reason(agent, on: endpoint.index),
                priority.quietFor(agent, on: endpoint.index),
            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            // Falls back to the workspace rather than to the pane id: an agent
            // that has not named itself is still identified by the work it is
            // doing, and "w2:p1" identifies nothing to anybody.
            let named = [agent.name, agent.displayAgent, agent.title]
                .compactMap { $0 }.first { !$0.isEmpty }
            add(
                title: named ?? workspace ?? agent.paneID,
                subtitle: [reason, named == nil ? nil : workspace, endpoint.label]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                status: priority.displayStatus(agent, on: endpoint.index),
                symbol: nil,
                collapsed: nil,
                selected: agent.focused && endpoint.index == active,
                target: .pane(agent.paneID, endpoint: endpoint.index))
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
        case .offline:
            // The reason, not just the fact. ssh explains itself perfectly
            // well — an unknown host key, a refused key, no herdr on the far
            // side — and throwing that away left every failure looking the
            // same.
            subtitle = endpoint.error.map(Self.reason) ?? "not connected"
        case .online:
            let count = endpoint.snapshot?.workspaces.count ?? 0
            // Not "needs attention" as well: the dot is already amber when an
            // agent is blocked, and saying it twice costs the width the count
            // is sitting in.
            subtitle = count == 1 ? "1 space" : "\(count) spaces"
        }

        add(
            title: endpoint.label,
            subtitle: subtitle,
            detail: endpoint.error,
            status: machineStatus(endpoint),
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

    /// The part of a failure worth putting in a row.
    ///
    /// ssh writes several lines and the last is the one that says what
    /// happened; our own wrapper adds a prefix that describes the symptom
    /// rather than the cause. The whole text goes in the tooltip.
    private static func reason(_ message: String) -> String {
        let last =
            message.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? message
        // Looped, not a single pass: the wrappers nest, and stopping after the
        // first left "ssh: " still on the front.
        var trimmed = Substring(last)
        var stripping = true
        while stripping {
            stripping = false
            for prefix in ["unexpected end of stream: ", "ssh: "]
            where trimmed.hasPrefix(prefix) {
                trimmed = trimmed.dropFirst(prefix.count)
                stripping = true
            }
        }
        return String(trimmed)
    }

    /// A machine's dot reflects its agents, falling back to its connection.
    private func machineStatus(_ endpoint: EndpointInfo) -> Snapshot.AgentStatus {
        guard endpoint.status == .online else { return .unknown }
        return priority.status(
            of: endpoint.snapshot?.agents ?? [], on: endpoint.index, fallback: .idle)
    }

    private func add(
        title: String,
        subtitle: String?,
        detail: String? = nil,
        status: Snapshot.AgentStatus,
        symbol: String?,
        collapsed: Bool?,
        selected: Bool,
        target: SidebarRow.Target,
        onToggle: (() -> Void)? = nil
    ) {
        let row = SidebarRow(
            title: title, subtitle: subtitle, detail: detail, status: status,
            symbol: symbol, collapsed: collapsed, selected: selected, chrome: chrome,
            target: target,
            onSelect: { [weak self] target in
                switch target {
                case .endpoint(let index): self?.onSelectEndpoint?(index)
                case .workspace(let id, let endpoint):
                    // Clicking a workspace on another machine switches to it
                    // first, otherwise the command goes to the wrong server.
                    self?.onSelectWorkspace?(id, endpoint)
                case .tab(let id): self?.onSelect?(.focusTab(id))
                case .pane(let id, let endpoint): self?.onSelectPane?(id, endpoint)
                }
            },
            onToggle: onToggle)
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
    }
}
