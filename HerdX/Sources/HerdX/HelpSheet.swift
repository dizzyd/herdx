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
    func show(over parent: NSWindow) {
        // Already up: a second ⌃B ? should not stack sheets.
        guard window == nil else { return }

        let content = NSView()
        let columns = NSStackView(views: [
            Self.column(
                title: "Prefix  ⌃B",
                rows: ChordResolver.prefixBindings.map { ($0.label, $0.title) }),
            Self.column(
                title: "Menu",
                rows: Command.menuLayout.compactMap { title, key, _ in
                    title.isEmpty ? nil : (Self.describe(key), title)
                }),
        ])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 40
        columns.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(
            labelWithString:
                "⌃B arms the prefix; the next key completes the chord. "
                + "The focused pane shows a mark while it is armed.")
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

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Keyboard Shortcuts"
        sheet.contentView = content
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
