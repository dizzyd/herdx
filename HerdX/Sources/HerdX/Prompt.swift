import AppKit

/// A one-field sheet, for the actions that only need a name.
///
/// Three renames and a worktree branch all want the same thing, so they share
/// one sheet rather than each growing their own window.
@MainActor
final class Prompt: NSObject, NSTextFieldDelegate {
    private var window: NSWindow?
    private let field = NSTextField()
    private let footnote = NSTextField(labelWithString: "")
    private var onCommit: ((String) -> Void)?
    /// What to say under the field about what is typed in it, or nil for the
    /// actions where the name is the whole story.
    private var describe: ((String) -> String)?

    /// - Parameter describe: Recomputed on every keystroke. The worktree sheet
    ///   uses it to show where a branch is about to be checked out, which is
    ///   the one thing about a new worktree that is not obvious from its name
    ///   and cannot be found out afterwards without looking.
    func ask(
        over parent: NSWindow, title: String, value: String, placeholder: String = "",
        describe: ((String) -> String)? = nil,
        commit: @escaping (String) -> Void
    ) {
        guard window == nil else { return }
        onCommit = commit
        self.describe = describe

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        field.stringValue = value
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.target = self
        field.action = #selector(accept)
        field.delegate = self
        // Return in the field is the same as pressing OK, which is what a sheet
        // with one field should do.
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true

        // Secondary and wrapping: it is a path, it can be long, and truncating
        // the middle of one hides the part that differs.
        footnote.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        footnote.textColor = .secondaryLabelColor
        footnote.lineBreakMode = .byCharWrapping
        footnote.maximumNumberOfLines = 3
        footnote.isHidden = describe == nil
        footnote.widthAnchor.constraint(equalToConstant: 320).isActive = true
        redescribe()

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

        let stack = NSStackView(views: [heading, field, footnote, buttons])
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

    /// Keeps the footnote describing what is in the field now.
    func controlTextDidChange(_ notification: Notification) { redescribe() }

    private func redescribe() {
        guard let describe else { return }
        footnote.stringValue = describe(
            field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        // The sheet is sized to its content once, so a footnote that grows a
        // line would otherwise be clipped rather than make room for itself.
        window?.contentView?.layoutSubtreeIfNeeded()
        if let content = window?.contentView { window?.setContentSize(content.fittingSize) }
    }

    @objc private func accept() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        close()
        guard !value.isEmpty else { return }
        onCommit?(value)
    }

    /// Dropped on close so a later sheet without one does not inherit it.
    private func forgetDescription() {
        describe = nil
        footnote.stringValue = ""
        footnote.isHidden = true
    }

    @objc private func dismiss() { close() }

    private func close() {
        forgetDescription()
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
