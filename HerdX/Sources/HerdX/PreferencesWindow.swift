import AppKit

/// The Settings window.
///
/// Standard macOS shape: opened from the app menu with ⌘,, one non-resizable
/// pane, changes applied immediately rather than behind an OK button, and the
/// font chosen through the system font panel rather than a bespoke picker.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let onChange: (Preferences) -> Void

    private let fontLabel = NSTextField(labelWithString: "")
    private let fontNote = NSTextField(labelWithString: "")
    private let appearancePopUp = NSPopUpButton()
    private let terminalPopUp = NSPopUpButton()
    private let marginField = NSTextField()
    private let marginStepper = NSStepper()
    private let backgroundWell = NSColorWell()
    private let foregroundWell = NSColorWell()

    private var preferences = Preferences.current
    /// Hidden unless there is something to say, so it leaves no gap.
    private var noteRow: NSGridRow?

    init(onChange: @escaping (Preferences) -> Void) {
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "HerdX Settings"
        // Settings windows are kept, not rebuilt, so ⌘, reopens the same one.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)

        window.contentView = buildContent()
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let change = NSButton(title: "Change…", target: self, action: #selector(chooseFont))
        change.bezelStyle = .rounded

        fontLabel.font = .systemFont(ofSize: 12)
        fontNote.font = .systemFont(ofSize: 10)
        fontNote.textColor = .secondaryLabelColor

        let font = NSStackView(views: [fontLabel, change])
        font.orientation = .horizontal
        font.spacing = 8

        for option in Preferences.Appearance.allCases {
            appearancePopUp.addItem(withTitle: option.title)
            appearancePopUp.lastItem?.representedObject = option.rawValue
        }
        appearancePopUp.target = self
        appearancePopUp.action = #selector(changed)

        // Separate from the window's appearance: herdr applies the foreground
        // client's host theme to every pane, so when another client is attached
        // to the same session the two have to agree, or the pane re-themes each
        // time focus moves between them.
        terminalPopUp.addItem(withTitle: "Match Window")
        terminalPopUp.lastItem?.representedObject = Preferences.Appearance.system.rawValue
        for option in [Preferences.Appearance.dark, .light] {
            terminalPopUp.addItem(withTitle: option.title)
            terminalPopUp.lastItem?.representedObject = option.rawValue
        }
        terminalPopUp.target = self
        terminalPopUp.action = #selector(changed)

        marginField.alignment = .right
        marginField.target = self
        marginField.action = #selector(marginChanged)
        marginField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        marginStepper.minValue = 0
        marginStepper.maxValue = 32
        marginStepper.increment = 1
        marginStepper.valueWraps = false
        marginStepper.target = self
        marginStepper.action = #selector(marginStepped)

        let margin = NSStackView(views: [marginField, marginStepper, caption("points")])
        margin.orientation = .horizontal
        margin.spacing = 4

        for well in [backgroundWell, foregroundWell] {
            well.target = self
            well.action = #selector(colourChanged)
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        let preset = NSButton(title: "Use Preset", target: self, action: #selector(usePreset))
        preset.bezelStyle = .rounded

        let colours = NSStackView(views: [
            backgroundWell, caption("background"), foregroundWell, caption("text"), preset,
        ])
        colours.orientation = .horizontal
        colours.spacing = 6

        let grid = NSGridView(views: [
            [label("Font:"), font],
            [NSGridCell.emptyContentView, fontNote],
            [label("Appearance:"), appearancePopUp],
            [label("Terminal:"), terminalPopUp],
            [label("Colours:"), colours],
            [label("Margin:"), margin],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        noteRow = grid.row(at: 1)

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
        return content
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 10)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// Reflects the stored preferences in the controls.
    private func refresh() {
        let font = preferences.font
        // The system monospace face reports an internal name like
        // ".SF NS Mono Light Regular", which is not what to show someone.
        let name =
            preferences.fontName.isEmpty
            ? "System Monospace" : (font.familyName ?? font.fontName)
        fontLabel.stringValue = "\(name)  \(Int(font.pointSize))"

        // A proportional font would break the grid, so it is refused rather
        // than silently drawn into overlapping columns.
        let chosenIsProportional =
            !preferences.fontName.isEmpty
            && NSFont(name: preferences.fontName, size: preferences.fontSize)?.isFixedPitch != true
        fontNote.stringValue =
            chosenIsProportional
            ? "Not a fixed-width font; using the system monospace face." : ""
        noteRow?.isHidden = fontNote.stringValue.isEmpty

        appearancePopUp.selectItem(withTitle: preferences.appearance.title)
        terminalPopUp.selectItem(
            withTitle: preferences.terminalAppearance == .system
                ? "Match Window" : preferences.terminalAppearance.title)

        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let resolved = preferences.terminalTheme(matching: dark)
        backgroundWell.color = preferences.background ?? resolved.background
        foregroundWell.color = preferences.foreground ?? resolved.foreground

        marginField.stringValue = String(format: "%.0f", preferences.margin)
        marginStepper.doubleValue = Double(preferences.margin)
    }

    // MARK: - Actions

    /// Opens the system font panel, which is where a Mac user expects to pick a
    /// font, instead of a list of families that cannot show weights or preview.
    @objc private func chooseFont() {
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(preferences.font, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let chosen = sender?.convert(preferences.font) else { return }
        preferences.fontName = chosen.fontName
        preferences.fontSize = chosen.pointSize.clamped(to: 6...48)
        apply()
    }

    /// Only the size and family are ours to change; the rest of the font panel
    /// does not apply to a terminal grid.
    @objc func validModesForFontPanel(_ panel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.collection, .face, .size]
    }

    @objc private func marginStepped() {
        preferences.margin = CGFloat(marginStepper.doubleValue)
        apply()
    }

    @objc private func marginChanged() {
        preferences.margin = CGFloat(marginField.doubleValue).clamped(to: 0...32)
        apply()
    }

    @objc private func colourChanged() {
        preferences.background = backgroundWell.color
        preferences.foreground = foregroundWell.color
        apply()
    }

    @objc private func usePreset() {
        preferences.background = nil
        preferences.foreground = nil
        apply()
    }

    @objc private func changed() {
        preferences.appearance =
            (appearancePopUp.selectedItem?.representedObject as? String)
            .flatMap(Preferences.Appearance.init(rawValue:)) ?? .system
        preferences.terminalAppearance =
            (terminalPopUp.selectedItem?.representedObject as? String)
            .flatMap(Preferences.Appearance.init(rawValue:)) ?? .system
        apply()
    }

    private func apply() {
        Preferences.current = preferences
        refresh()
        onChange(preferences)
    }
}
