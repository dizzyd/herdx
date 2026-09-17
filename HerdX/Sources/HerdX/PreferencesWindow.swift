import AppKit

/// A small settings sheet for the font and appearance.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private var onChange: (Preferences) -> Void
    private let familyPopUp = NSPopUpButton()
    private let sizeField = NSTextField()
    private let appearancePopUp = NSPopUpButton()
    private let terminalPopUp = NSPopUpButton()

    init(onChange: @escaping (Preferences) -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "HerdX Settings"
        super.init(window: window)

        let preferences = Preferences.current

        familyPopUp.addItem(withTitle: "System Monospace")
        familyPopUp.addItems(withTitles: Preferences.monospacedFamilies)
        familyPopUp.selectItem(withTitle: preferences.fontName.isEmpty
            ? "System Monospace" : preferences.fontName)
        familyPopUp.target = self
        familyPopUp.action = #selector(changed)

        sizeField.stringValue = String(format: "%.0f", preferences.fontSize)
        sizeField.target = self
        sizeField.action = #selector(changed)
        sizeField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        for option in Preferences.Appearance.allCases {
            appearancePopUp.addItem(withTitle: option.title)
            appearancePopUp.lastItem?.representedObject = option.rawValue
        }
        appearancePopUp.selectItem(withTitle: preferences.appearance.title)
        appearancePopUp.target = self
        appearancePopUp.action = #selector(changed)

        // Separate from the window's appearance: herdr applies the foreground
        // client's host theme to every pane, so when a herdr TUI is attached to
        // the same session the two have to agree, or the pane re-themes each
        // time focus moves between them.
        terminalPopUp.addItem(withTitle: "Match Window")
        terminalPopUp.lastItem?.representedObject = Preferences.Appearance.system.rawValue
        for option in [Preferences.Appearance.dark, .light] {
            terminalPopUp.addItem(withTitle: option.title)
            terminalPopUp.lastItem?.representedObject = option.rawValue
        }
        terminalPopUp.selectItem(
            withTitle: preferences.terminalAppearance == .system
                ? "Match Window" : preferences.terminalAppearance.title)
        terminalPopUp.target = self
        terminalPopUp.action = #selector(changed)

        let grid = NSGridView(views: [
            [label("Font"), familyPopUp],
            [label("Size"), sizeField],
            [label("Appearance"), appearancePopUp],
            [label("Terminal"), terminalPopUp],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.contentView = content
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    @objc private func changed() {
        let family = familyPopUp.titleOfSelectedItem ?? "System Monospace"
        // Sizes outside this range stop being a terminal.
        let size = max(6, min(CGFloat(sizeField.doubleValue), 48))
        sizeField.stringValue = String(format: "%.0f", size)

        let appearance =
            (appearancePopUp.selectedItem?.representedObject as? String)
            .flatMap(Preferences.Appearance.init(rawValue:)) ?? .system

        let terminal =
            (terminalPopUp.selectedItem?.representedObject as? String)
            .flatMap(Preferences.Appearance.init(rawValue:)) ?? .system

        let preferences = Preferences(
            fontName: family == "System Monospace" ? "" : family,
            fontSize: size,
            appearance: appearance,
            terminalAppearance: terminal)
        Preferences.current = preferences
        onChange(preferences)
    }
}
