import AppKit

/// Native chrome driven by `ClientShellSnapshot`.
///
/// This is the part that a full-surface renderer cannot give you: the server
/// sends workspaces, tabs and agent status as structured JSON, so these are
/// real rows with real selection, not characters in a grid.
final class SidebarView: NSView {
    static let width: CGFloat = 220

    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 12, bottom: 12, right: 12)
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

    func update(with snapshot: Snapshot) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for workspace in snapshot.workspaces {
            stack.addArrangedSubview(
                row(
                    text: "\(workspace.number)  \(workspace.label)",
                    detail: workspace.branch,
                    status: workspace.agentStatus,
                    emphasis: workspace.focused,
                    indent: 0))

            for tab in snapshot.tabs where tab.workspaceID == workspace.workspaceID {
                stack.addArrangedSubview(
                    row(
                        text: tab.label.isEmpty ? "tab \(tab.number)" : tab.label,
                        detail: nil,
                        status: tab.agentStatus,
                        emphasis: tab.focused,
                        indent: 1))

                for agent in snapshot.agents where agent.paneID.hasPrefix("") {
                    guard snapshot.panes.contains(where: {
                        $0.paneID == agent.paneID && $0.tabID == tab.tabID
                    }) else { continue }
                    stack.addArrangedSubview(
                        row(
                            text: agent.displayAgent ?? agent.title ?? "agent",
                            detail: nil,
                            status: agent.agentStatus,
                            emphasis: agent.focused,
                            indent: 2))
                }
            }
        }
    }

    private func row(
        text: String, detail: String?, status: Snapshot.AgentStatus, emphasis: Bool, indent: Int
    ) -> NSView {
        let line = NSStackView()
        line.orientation = .horizontal
        line.spacing = 6
        line.edgeInsets = NSEdgeInsets(
            top: 2, left: CGFloat(indent) * 12, bottom: 2, right: 0)

        let dot = NSTextField(labelWithString: "●")
        dot.font = .systemFont(ofSize: 8)
        dot.textColor = color(for: status)
        line.addArrangedSubview(dot)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: emphasis ? .semibold : .regular)
        label.textColor = emphasis ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        line.addArrangedSubview(label)

        if let detail, !detail.isEmpty {
            let branch = NSTextField(labelWithString: detail)
            branch.font = .systemFont(ofSize: 10)
            branch.textColor = .tertiaryLabelColor
            line.addArrangedSubview(branch)
        }
        return line
    }

    /// herdr's whole point is knowing which agents need you; the colours carry
    /// that, so blocked has to be the one that catches the eye.
    private func color(for status: Snapshot.AgentStatus) -> NSColor {
        switch status {
        case .working: return NSColor(srgbRed: 0.40, green: 0.70, blue: 0.95, alpha: 1)
        case .blocked: return NSColor(srgbRed: 0.95, green: 0.65, blue: 0.25, alpha: 1)
        case .done: return NSColor(srgbRed: 0.45, green: 0.80, blue: 0.50, alpha: 1)
        case .idle, .unknown: return NSColor(white: 0.35, alpha: 1)
        }
    }
}
