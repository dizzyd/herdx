import AppKit

/// A small settings sheet for the font and appearance.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private var onChange: (Preferences) -> Void
    private let familyPopUp = NSPopUpButton()
    private let sizeField = NSTextField()
    private let appearancePopUp = NSPopUpButton()
    private let terminalPopUp = NSPopUpButton()
    private let backgroundWell = NSColorWell()
    private let foregroundWell = NSColorWell()
    private var customColours: Bool

    init(onChange: @escaping (Preferences) -> Void) {
        self.onChange = onChange
        customColours = Preferences.current.background != nil
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
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

        // Exact colours, because herdr compares actual RGB when deciding
        // whether a client's host theme changed: "dark" will not match another
        // terminal's particular background, only the same colour will.
        let resolved = preferences.terminalTheme(
            matching: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        backgroundWell.color = preferences.background ?? resolved.background
        backgroundWell.target = self
        backgroundWell.action = #selector(colourChanged)
        foregroundWell.color = preferences.foreground ?? resolved.foreground
        foregroundWell.target = self
        foregroundWell.action = #selector(colourChanged)

        let reset = NSButton(title: "Use Preset", target: self, action: #selector(resetColours))
        reset.bezelStyle = .rounded
        let colours = NSStackView(views: [backgroundWell, foregroundWell, reset])
        colours.orientation = .horizontal
        colours.spacing = 8

        let grid = NSGridView(views: [
            [label("Font"), familyPopUp],
            [label("Size"), sizeField],
            [label("Appearance"), appearancePopUp],
            [label("Terminal"), terminalPopUp],
            [label("Colours"), colours],
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

    /// Picking a colour switches the terminal off its preset.
    @objc private func colourChanged() {
        customColours = true
        changed()
    }

    @objc private func resetColours() {
        customColours = false
        changed()
        let resolved = Preferences.current.terminalTheme(
            matching: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        backgroundWell.color = resolved.background
        foregroundWell.color = resolved.foreground
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
            terminalAppearance: terminal,
            background: customColours ? backgroundWell.color : nil,
            foreground: customColours ? foregroundWell.color : nil)
        Preferences.current = preferences
        onChange(preferences)
    }
}
