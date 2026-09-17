import AppKit

/// What you are looking at, above the tabs.
///
/// The window title can only hold one line and is easy to miss at the top of a
/// large screen. Machine, workspace, agent state and working directory are the
/// four things that tell two identical-looking terminals apart, so they belong
/// over the terminal itself.
final class HeaderView: NSView {
    static let height: CGFloat = 46

    private let name = NSTextField(labelWithString: "")
    private let breadcrumb = NSTextField(labelWithString: "")
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

        name.font = .systemFont(ofSize: 13, weight: .bold)
        name.lineBreakMode = .byTruncatingTail
        breadcrumb.font = .systemFont(ofSize: 11)
        breadcrumb.lineBreakMode = .byTruncatingMiddle

        let lines = NSStackView(views: [name, breadcrumb])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            lines.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(chrome: Chrome) {
        self.chrome = chrome
        name.textColor = chrome.primary
        breadcrumb.textColor = chrome.tertiary
        needsDisplay = true
        lastSignature = nil
    }

    /// The focused tab, and the trail that locates it.
    func update(snapshot: Snapshot?, machine: String?) {
        let tab = snapshot?.tabs.first { $0.tabID == snapshot?.focusedTabID }
        let workspace = snapshot?.workspaces.first { $0.focused }
        let pane = snapshot?.panes.first { $0.paneID == snapshot?.focusedPaneID }
        let agent = snapshot?.agents.first { $0.paneID == snapshot?.focusedPaneID }

        let title = tab.map { $0.label.isEmpty ? "tab \($0.number)" : $0.label }
            ?? workspace?.label ?? ""
        let trail = [
            machine,
            workspace?.label,
            agent?.displayAgent,
            agent.map { String(describing: $0.agentStatus) },
            pane?.cwd.map(Self.abbreviated),
        ].compactMap { $0 }.filter { !$0.isEmpty }

        let signature = title + "|" + trail.joined(separator: "·")
        guard lastSignature != signature else { return }
        lastSignature = signature
        name.stringValue = title
        breadcrumb.stringValue = trail.joined(separator: "  ·  ")
    }

    /// Home is where most work happens, so spelling it out wastes the width
    /// that the interesting end of the path needs.
    private static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
