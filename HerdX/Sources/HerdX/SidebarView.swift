import AppKit

/// One clickable row in the sidebar.
///
/// Two lines, like herdr's own list: the name you are looking for on top and
/// the context that distinguishes two rows with the same name underneath. A
/// single line forced "paperless-go" and "paperless-go" to be told apart by a
/// truncated suffix.
final class SidebarRow: NSView {
    enum Target: Equatable {
        case endpoint(Int)
        case workspace(String, endpoint: Int)
        case tab(String)
        case pane(String, endpoint: Int)
        /// A workspace that is not running. Its panes have no ids any more, so
        /// the record is what addresses it.
        case hibernated(UUID, endpoint: Int)
    }

    let target: Target
    private let onSelect: (Target) -> Void
    /// Raised by the disclosure triangle, which acts on the row without
    /// selecting it.
    private let onToggle: (() -> Void)?
    private var hovered = false
    /// Read by the arrow keys, which need to know where the selection is to
    /// move it.
    let selected: Bool
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
    let title: String

    /// Hibernated workspaces are a band here too, and they are not a tier: no
    /// clock puts a row in it, the record does.
    convenience init(tier: AgentPriority.Tier, rule: Bool, chrome: Chrome) {
        self.init(title: tier.title, rule: rule, chrome: chrome)
    }

    init(title: String, rule: Bool, chrome: Chrome) {
        self.title = title
        super.init(frame: .zero)

        let label = NSTextField(labelWithString: title.uppercased())
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
    /// Clicking a hibernated row is how it comes back.
    var onSelectHibernated: ((UUID, Int) -> Void)?
    /// Workspaces that are not running, drawn under the live agents.
    private var hibernated: [Hibernated] = []

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
    /// The headings and rows as built, for tests.
    ///
    /// Like `rebuilds`: what the list decided is not observable through a
    /// window, and the decisions are the part worth pinning down.
    var builtRows: [NSView] { stack.arrangedSubviews }
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
    /// Where the last click or arrow key sent the selection, until the server
    /// agrees.
    ///
    /// A row draws itself selected because the *server* says its workspace or
    /// pane is focused, and that answer is a round trip away. Without somewhere
    /// to note the intent, two presses in quick succession both start from the
    /// row you were on when you pressed the first, and the second goes nowhere
    /// — which on a held arrow key is most of them.
    private var pendingSelection: SidebarRow.Target?

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
    func update(endpoints: [EndpointInfo], active: Int, hibernated: [Hibernated] = []) {
        self.hibernated = hibernated
        // Snapshots are republished constantly and mostly change nothing the
        // sidebar shows; rebuilding every time would throw away hover state
        // mid-gesture.
        let machines = endpoints.map { endpoint -> String in
            let workspaces = endpoint.snapshot.map { snapshot in
                snapshot.workspaces
                    .map {
                        // The tab's name too: renaming a tab changes this row
                        // and nothing else here would notice.
                        "\($0.workspaceID):\($0.label):\($0.branch ?? ""):\($0.focused)"
                            + ":\($0.agentStatus):\(Self.namedTab(of: $0, in: snapshot))"
                    }
                    .joined(separator: ",")
            } ?? ""
            return "\(endpoint.id):\(endpoint.status):\(endpoint.error ?? ""):\(workspaces)"
        }.joined(separator: "|")

        // The priority list is ordered by things the machine list does not
        // show, so it needs its own reasons to be rebuilt.
        var agents = ""
        if arrangement == .priority {
            let rows: [String] = endpoints.flatMap { endpoint -> [String] in
                guard let snapshot = endpoint.snapshot else { return [] }
                return snapshot.agents.map { agent -> String in
                    let seen = priority.hasSeen(agent, on: endpoint.index)
                    // The band and the age are the reasons a row moves without
                    // anything on the wire changing — an agent crosses into
                    // "long idle" purely because time passed, and nothing else
                    // here would notice. Both are coarse, so including them
                    // costs a rebuild an hour rather than one a tick.
                    let tier = priority.tier(agent, on: endpoint.index).rawValue
                    let quiet = priority.quietFor(agent, on: endpoint.index) ?? ""
                    // The tab's name is in the row, and renaming a tab changes
                    // nothing else here.
                    let tab = Self.namedTab(tabID: agent.tabID, in: snapshot)
                    return "\(agent.paneID):\(agent.agentStatus):\(agent.stateChangeSeq):\(seen)"
                        + ":\(tier):\(quiet):\(tab)"
                }
            }
            agents = rows.joined(separator: ",")
        }

        // Hibernated rows come from the store rather than from a snapshot, so
        // nothing else in this signature moves when one appears or is revived —
        // and the list would go on showing the old one until something
        // unrelated changed.
        let dormant = hibernated
            .map { "\($0.id):\($0.endpointID):\($0.label)" }
            .joined(separator: ",")
        let collapsedKey = collapsed.sorted().joined(separator: ",")
        let signature =
            machines + "@\(active)+\(collapsedKey)+\(arrangement.rawValue)+" + agents
            + "+" + dormant
        guard lastSignature != signature else { return }
        lastSignature = signature
        self.endpoints = endpoints
        self.active = active

        rebuilds += 1
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if arrangement == .priority {
            addAgentsByPriority(endpoints)
        } else {
            for endpoint in endpoints {
                let isActive = endpoint.index == active
                addMachine(endpoint, isActive: isActive)
                guard !collapsed.contains(endpoint.id), let snapshot = endpoint.snapshot else {
                    continue
                }
                for workspace in snapshot.workspaces {
                    add(
                        title: workspace.label + Self.namedTab(of: workspace, in: snapshot),
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

        // The server has caught up, so the intent is no longer worth holding on
        // to — and holding it past this point would start the next key from a
        // row the user has since moved off with the mouse.
        if let pendingSelection,
            navigableRows.contains(where: { $0.selected && $0.target == pendingSelection })
        {
            self.pendingSelection = nil
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
        // Only records for machines that are attached: a row whose machine is
        // not here could not be revived by clicking it, and a row that does
        // nothing is worse than one that is missing.
        let dormant =
            hibernated
            .compactMap { record -> (record: Hibernated, endpoint: Int)? in
                guard let endpoint = endpoints.first(where: { $0.id == record.endpointID })
                else { return nil }
                return (record, endpoint.index)
            }
            .sorted { $0.record.number < $1.record.number }

        guard !all.isEmpty || !dormant.isEmpty else {
            add(
                title: "No agents", subtitle: nil, status: .unknown, symbol: nil,
                collapsed: nil, selected: false, target: .endpoint(0))
            return
        }

        let ordered = priority.ordered(all, agent: { $0.1 }, endpoint: { $0.0.index })
        // Headings only when there is more than one band to tell apart. A lone
        // "Active" over every row labels nothing and costs a line of the list.
        let tiers = ordered.map { priority.tier($0.1, on: $0.0.index) }
        // Hibernated rows are a band of their own, so their presence is another
        // reason for the live rows above them to be labelled.
        let banded = Set(tiers).count > 1 || (!dormant.isEmpty && !ordered.isEmpty)
        var band: AgentPriority.Tier?

        for (index, (endpoint, agent)) in ordered.enumerated() {
            if banded, tiers[index] != band {
                addSection(tiers[index].title, rule: band != nil)
                band = tiers[index]
            }

            let workspace = endpoint.snapshot.flatMap { snapshot in
                snapshot.workspaces.first { $0.workspaceID == agent.workspaceID }
                    .map { $0.label + Self.namedTab(tabID: agent.tabID, in: snapshot) }
            }
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

        addHibernated(dormant, under: !ordered.isEmpty)
    }

    /// The workspaces that are not running, under the live ones.
    ///
    /// Below "long idle" because that is where they belong in the same
    /// ordering: the bands above are degrees of not having been touched
    /// lately, and this is the end of that line — not touched lately, and now
    /// not running either. Clicking one brings it back, which is the only
    /// thing that distinguishes it from a row that is merely quiet.
    private func addHibernated(_ dormant: [(record: Hibernated, endpoint: Int)], under: Bool) {
        guard !dormant.isEmpty else { return }
        addSection("Hibernated", rule: under)

        for (record, endpoint) in dormant {
            // Which agents are coming back, so the row says what is being kept
            // rather than only that something is.
            var agents: [String] = []
            for agent in record.agents where !agents.contains(agent.agent) {
                agents.append(agent.agent)
            }
            // Not "hibernated 9h": the heading above has already said that, and
            // repeating it in every row only pushed the age out of a narrow
            // sidebar. The agent rows spell their age the same way.
            let age = AgentPriority.age(Date().timeIntervalSince(record.at))
            add(
                // The first tab is the one a revive lands in, so it is the one
                // worth naming.
                title: record.label + Self.namedTab(stored: record.tabs.first?.label),
                subtitle: [agents.joined(separator: " · "), age]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                // No dot: the status colours say what an agent is doing, and
                // this one is not doing anything.
                status: .unknown,
                symbol: nil,
                collapsed: nil,
                selected: false,
                target: .hibernated(record.id, endpoint: endpoint))
        }
    }

    /// The workspace's active tab, in brackets, when it has been given a name.
    ///
    /// Only when named. herdr calls a tab by its number until somebody renames
    /// it, and "crucibulum (1)" says nothing that "crucibulum" did not — while
    /// "herdx (claude)" is the whole reason to look. In a 240pt sidebar the
    /// width is worth spending only on the difference.
    static func namedTab(of workspace: Snapshot.Workspace, in snapshot: Snapshot) -> String {
        guard let active = workspace.activeTabID else { return "" }
        return namedTab(tabID: active, in: snapshot)
    }

    /// One particular tab, for a row that is about one particular pane.
    ///
    /// The agents list names the tab the agent is *in*, which is not always
    /// the one its workspace would open at — the whole reason to list agents
    /// separately is that they are somewhere you are not.
    static func namedTab(tabID: String, in snapshot: Snapshot) -> String {
        guard let tab = snapshot.tabs.first(where: { $0.tabID == tabID }) else { return "" }
        return named(tab.label, default: String(tab.number))
    }

    /// A stored tab's name, for a workspace that is no longer running.
    ///
    /// The number it would have been called by is not kept, so a label that is
    /// only digits is taken for a default one. That is what herdr's defaults
    /// look like, and the cost of being wrong is a bracket.
    static func namedTab(stored label: String?) -> String {
        guard let label, !label.isEmpty else { return "" }
        return label.allSatisfy(\.isNumber) ? "" : " (\(label))"
    }

    private static func named(_ label: String, default fallback: String) -> String {
        label == fallback ? "" : " (\(label))"
    }

    /// A band heading, with the rule that sets it off from the band above.
    private func addSection(_ title: String, rule: Bool) {
        let section = SidebarSection(title: title, rule: rule, chrome: chrome)
        section.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
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

    /// Goes wherever a row points. Shared by the mouse and the arrow keys so
    /// that a key cannot come to mean something a click does not.
    private func select(_ target: SidebarRow.Target) {
        pendingSelection = target
        switch target {
        case .endpoint(let index): onSelectEndpoint?(index)
        case .workspace(let id, let endpoint):
            // Clicking a workspace on another machine switches to it first,
            // otherwise the command goes to the wrong server.
            onSelectWorkspace?(id, endpoint)
        case .tab(let id): onSelect?(.focusTab(id))
        case .pane(let id, let endpoint): onSelectPane?(id, endpoint)
        case .hibernated(let id, let endpoint): onSelectHibernated?(id, endpoint)
        }
    }

    /// The rows an arrow key moves between, in the order they are drawn.
    ///
    /// Read back off the rows themselves rather than worked out again. The
    /// sidebar already decides this order twice over — machines and their
    /// workspaces in one arrangement, agents by priority in the other — and a
    /// second copy of that decision is a second thing to keep in step. It comes
    /// with the collapsed machines already gone and the band headings already
    /// out, those being a different class of view entirely.
    ///
    /// Machines are left out because an arrow is a move between places to work,
    /// and a machine is the heading over them rather than one of them.
    private var navigableRows: [SidebarRow] {
        stack.arrangedSubviews.compactMap { $0 as? SidebarRow }.filter {
            if case .endpoint = $0.target { return false }
            return true
        }
    }

    /// Where a step lands, or nothing when it would go nowhere.
    ///
    /// Clamped, not wrapped, unlike cycling through agents: this is a spatial
    /// move through a list you can see, and a list that jumps from its last row
    /// to its first is one you can fall off the end of without noticing.
    /// Landing where you already are counts as going nowhere.
    static func step(from current: Int?, by offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return offset > 0 ? 0 : count - 1 }
        let next = min(max(current + offset, 0), count - 1)
        return next == current ? nil : next
    }

    /// Moves the selection one row, exactly as clicking that row would.
    ///
    /// Works while the sidebar is collapsed, which is deliberate: it is put
    /// away by sliding the split to nothing rather than by being torn down, so
    /// the rows are still there and still in order, and a key that stopped
    /// working because a panel was hidden would be a key that stopped working
    /// for no reason the user can see.
    @discardableResult
    func step(by offset: Int) -> Bool {
        let rows = navigableRows
        // The intended selection outranks the drawn one while they disagree,
        // which is the whole window between pressing the key and the snapshot
        // that proves it worked.
        let current = rows.firstIndex { row in
            if let pendingSelection { return row.target == pendingSelection }
            return row.selected
        }
        guard let next = Self.step(from: current, by: offset, count: rows.count) else {
            return false
        }
        select(rows[next].target)
        return true
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
            onSelect: { [weak self] target in self?.select(target) },
            onToggle: onToggle)
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
    }
}
