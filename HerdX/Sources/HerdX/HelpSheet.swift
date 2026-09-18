import AppKit

/// The keyboard reference, built from the tables that resolve keystrokes.
///
/// Hand-written help goes stale the moment a binding moves, and stale help is
/// worse than none: it is the one place a reader has no way to check. Both
/// columns are generated from `ChordResolver.prefixBindings` and
/// `Command.menuLayout`, so a binding cannot change without this changing too.
@MainActor
final class HelpSheet {
    private var window: NSWindow?

    /// System colours, not the terminal's: this is an ordinary Mac sheet, and
    /// the chrome palette is built for a surface that is dark because the
    /// terminal is. Painting a light dialog with it left the headings all but
    /// invisible.
    func show(over parent: NSWindow, keymap: Keymap, supported: (Keymap.Action) -> Bool) {
        // Already up: a second prefix-? should not stack sheets.
        guard window == nil else { return }

        // Bindings HerdX cannot carry out are still the user's bindings, and
        // leaving them out would make the list look complete when it is not.
        let prefixed = keymap.bindings.filter(\.binding.usesPrefix).map { entry in
            (
                entry.binding.label,
                supported(entry.action)
                    ? entry.action.title : entry.action.title + "  —  not yet"
            )
        }
        // herdr binds far more than fits in one column at a sensible window
        // height, so the prefix list runs down two.
        let split = (prefixed.count + 1) / 2

        let content = NSView()
        let columns = NSStackView(views: [
            Self.column(
                title: "Prefix  " + keymap.prefixLabel, rows: Array(prefixed.prefix(split))),
            Self.column(title: " ", rows: Array(prefixed.dropFirst(split))),
            Self.column(
                title: "Menu",
                rows: Command.menuLayout.compactMap { title, key, _ in
                    title.isEmpty ? nil : (Self.describe(key), title)
                }),
        ])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 28
        columns.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(
            labelWithString:
                "\(keymap.prefixLabel) arms the prefix; the next key completes the chord. "
                + "These are herdr's own bindings, read from the server.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false

        let done = NSButton(title: "Done", target: self, action: #selector(dismiss))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(columns)
        content.addSubview(note)
        content.addSubview(done)
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            columns.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            columns.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            note.topAnchor.constraint(equalTo: columns.bottomAnchor, constant: 20),
            note.leadingAnchor.constraint(equalTo: columns.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            done.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 16),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        let sheet = DismissableSheet(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Keyboard Shortcuts"
        sheet.contentView = content
        // Sized to what it holds: the list is the server's, so how long it runs
        // is not something this file gets to assume.
        content.layoutSubtreeIfNeeded()
        sheet.setContentSize(content.fittingSize)
        window = sheet

        parent.beginSheet(sheet) { [weak self] _ in self?.window = nil }
    }

    @objc private func dismiss() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }

    /// One titled list of key/description pairs.
    private static func column(title: String, rows: [(String, String)]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        let grid = NSGridView(views: rows.map { key, description in
            let keyLabel = NSTextField(labelWithString: key)
            // Monospaced digits keep the key column from shifting about as the
            // glyphs change width.
            keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            let text = NSTextField(labelWithString: description)
            text.font = .systemFont(ofSize: 12)
            return [keyLabel, text]
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing

        let stack = NSStackView(views: [heading, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    /// A menu key equivalent as a reader sees it on the key caps.
    private static func describe(_ key: Command.Key) -> String {
        var text = ""
        if key.modifiers.contains(.control) { text += "⌃" }
        if key.modifiers.contains(.option) { text += "⌥" }
        if key.modifiers.contains(.shift) { text += "⇧" }
        if key.modifiers.contains(.command) { text += "⌘" }

        switch key.equivalent {
        case "\u{F700}": return text + "↑"
        case "\u{F701}": return text + "↓"
        case "\u{F702}": return text + "←"
        case "\u{F703}": return text + "→"
        case "\r": return text + "↩"
        default: return text + key.equivalent.uppercased()
        }
    }
}

/// A sheet that escape closes.
///
/// Escape travels the responder chain as `cancelOperation`, and with no cancel
/// button to land on it reached the window and stopped. A reference you opened
/// to read should close the way every other transient panel on the Mac does.
private final class DismissableSheet: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        sheetParent?.endSheet(self)
    }
}
