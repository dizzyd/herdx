import AppKit

/// A one-field sheet, for the actions that only need a name.
///
/// Three renames and a worktree branch all want the same thing, so they share
/// one sheet rather than each growing their own window.
@MainActor
final class Prompt {
    private var window: NSWindow?
    private let field = NSTextField()
    private var onCommit: ((String) -> Void)?

    func ask(
        over parent: NSWindow, title: String, value: String, placeholder: String = "",
        commit: @escaping (String) -> Void
    ) {
        guard window == nil else { return }
        onCommit = commit

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        field.stringValue = value
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.target = self
        field.action = #selector(accept)
        // Return in the field is the same as pressing OK, which is what a sheet
        // with one field should do.
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(dismiss))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(accept))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"

        // A spacer rather than a trailing-aligned column: the heading and the
        // field read from the left, and only the buttons belong on the right.
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [heading, field, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // Activated here, not where the row is built: the two views share
            // no ancestor until the stack is in the content view, and a
            // constraint across separate hierarchies throws.
            buttons.widthAnchor.constraint(equalTo: field.widthAnchor),
        ])

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = content
        content.layoutSubtreeIfNeeded()
        sheet.setContentSize(content.fittingSize)
        window = sheet

        parent.beginSheet(sheet) { [weak self] _ in self?.window = nil }
        sheet.makeFirstResponder(field)
    }

    @objc private func accept() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        close()
        guard !value.isEmpty else { return }
        onCommit?(value)
    }

    @objc private func dismiss() { close() }

    private func close() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
