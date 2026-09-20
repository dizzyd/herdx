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
    private let paddingField = NSTextField()
    private let paddingStepper = NSStepper()
    private let labelField = NSTextField()
    private let labelStepper = NSStepper()
    private let lineField = NSTextField()
    private let lineStepper = NSStepper()
    private let themeLabel = NSTextField(labelWithString: "")
    private let soundsCheck = NSButton()
    private let hibernatePopUp = NSPopUpButton()
    private let hibernateNote = NSTextField(labelWithString: "")
    private let matchButton = NSButton()
    private let matchNote = NSTextField(labelWithString: "")
    /// Colours another client attached to the same session is using, when there
    /// is one. Supplied by the app, which is what watches the surface.
    var attachedTerminal: (background: NSColor, foreground: NSColor)?
    private let backgroundWell = NSColorWell()
    private let foregroundWell = NSColorWell()

    /// Read and written straight through, rather than kept as a copy.
    ///
    /// The window outlives being closed, so a copy taken when it was built goes
    /// stale the moment anything else writes a setting — the theme picker does
    /// — and the next control touched here wrote that whole stale struct back.
    /// That is how choosing a theme and then nudging line spacing put the
    /// colours back to built-in.
    private var preferences: Preferences {
        get { Preferences.current }
        set { Preferences.current = newValue }
    }
    /// Hidden unless there is something to say, so it leaves no gap.
    private var noteRow: NSGridRow?

    init(onChange: @escaping (Preferences) -> Void) {
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 356),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "HerdX Settings"
        // Settings windows are kept, not rebuilt, so ⌘, reopens the same one.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)

        let content = buildContent()
        window.contentView = content
        refresh()
        // Sized to what it holds rather than to a number kept in step by hand:
        // every row added so far has needed that number changing, and the last
        // one was noticed only because a control fell off the bottom.
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
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

        paddingField.alignment = .right
        paddingField.target = self
        paddingField.action = #selector(paddingChanged)
        paddingField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        paddingStepper.minValue = 0
        paddingStepper.maxValue = 32
        paddingStepper.increment = 1
        paddingStepper.valueWraps = false
        paddingStepper.target = self
        paddingStepper.action = #selector(paddingStepped)

        let padding = NSStackView(views: [paddingField, paddingStepper, caption("points")])
        padding.orientation = .horizontal
        padding.spacing = 4

        labelField.alignment = .right
        labelField.target = self
        labelField.action = #selector(labelSizeChanged)
        labelField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        labelStepper.minValue = 8
        labelStepper.maxValue = 18
        labelStepper.increment = 1
        labelStepper.valueWraps = false
        labelStepper.target = self
        labelStepper.action = #selector(labelSizeStepped)

        let labelSize = NSStackView(views: [labelField, labelStepper, caption("points")])
        labelSize.orientation = .horizontal
        labelSize.spacing = 4

        lineField.alignment = .right
        lineField.target = self
        lineField.action = #selector(lineHeightChanged)
        lineField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        // Percent rather than a multiplier: nobody thinks in 1.2.
        lineStepper.minValue = 100
        lineStepper.maxValue = 200
        lineStepper.increment = 5
        lineStepper.valueWraps = false
        lineStepper.target = self
        lineStepper.action = #selector(lineHeightStepped)

        let lineHeight = NSStackView(views: [lineField, lineStepper, caption("%")])
        lineHeight.orientation = .horizontal
        lineHeight.spacing = 4

        for well in [backgroundWell, foregroundWell] {
            well.target = self
            well.action = #selector(colourChanged)
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        let preset = NSButton(title: "Use Preset", target: self, action: #selector(usePreset))
        preset.bezelStyle = .rounded

        themeLabel.font = .systemFont(ofSize: 13)
        themeLabel.lineBreakMode = .byTruncatingTail
        let loadTheme = NSButton(
            title: "Load…", target: self, action: #selector(loadTheme))
        loadTheme.bezelStyle = .rounded
        let clearTheme = NSButton(
            title: "Clear", target: self, action: #selector(clearTheme))
        clearTheme.bezelStyle = .rounded

        let themeRow = NSStackView(views: [themeLabel, loadTheme, clearTheme])
        themeRow.orientation = .horizontal
        themeRow.spacing = 6

        matchButton.title = "Match Attached Terminal"
        matchButton.bezelStyle = .rounded
        matchButton.target = self
        matchButton.action = #selector(matchAttached)

        let colours = NSStackView(views: [
            backgroundWell, caption("background"), foregroundWell, caption("text"), preset,
        ])
        colours.orientation = .horizontal
        colours.spacing = 6

        matchNote.font = .systemFont(ofSize: 11)
        matchNote.textColor = .secondaryLabelColor
        matchNote.lineBreakMode = .byWordWrapping
        matchNote.maximumNumberOfLines = 3
        matchNote.preferredMaxLayoutWidth = 300

        let match = NSStackView(views: [matchButton, matchNote])
        match.orientation = .vertical
        match.alignment = .leading
        match.spacing = 4

        // herdr's own two sounds, played on the same state changes its client
        // plays them on. The switch is HerdX's: herdr's `[ui.sound]` config is
        // read by herdr's client, not published to this one.
        // Hours, and "Never" rather than a switch beside a number: off is the
        // default and belongs in the same control as the choice, not beside it.
        hibernatePopUp.removeAllItems()
        for (title, hours) in [
            ("Never", 0), ("After 4 hours", 4), ("After 8 hours", 8),
            ("After 12 hours", 12), ("After 24 hours", 24),
        ] {
            hibernatePopUp.addItem(withTitle: title)
            hibernatePopUp.lastItem?.tag = hours
        }
        hibernatePopUp.target = self
        hibernatePopUp.action = #selector(hibernateChanged)

        hibernateNote.font = .systemFont(ofSize: 11)
        hibernateNote.textColor = .secondaryLabelColor
        hibernateNote.stringValue =
            "Ends the processes of a local workspace left idle this long, keeping what its "
            + "agents were talking about. It stays in the sidebar; click it to bring it back."
        hibernateNote.lineBreakMode = .byWordWrapping
        hibernateNote.preferredMaxLayoutWidth = 380

        soundsCheck.setButtonType(.switch)
        soundsCheck.title = "Play a sound when an agent finishes or needs you"
        soundsCheck.target = self
        soundsCheck.action = #selector(soundsChanged)

        let grid = NSGridView(views: [
            [label("Font:"), font],
            [NSGridCell.emptyContentView, fontNote],
            [label("Appearance:"), appearancePopUp],
            [label("Terminal:"), terminalPopUp],
            [label("Theme:"), themeRow],
            [label("Colours:"), colours],
            [NSGridCell.emptyContentView, match],
            [label("Pane padding:"), padding],
            [label("Pane label:"), labelSize],
            [label("Line height:"), lineHeight],
            [label("Sounds:"), soundsCheck],
            [label("Hibernate:"), hibernatePopUp],
            [NSGridCell.emptyContentView, hibernateNote],
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
            // Pinned at the bottom too, so the content view has a height to
            // report. Without it the window sized itself to nothing and every
            // row had to be paid for by hand in the frame above.
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
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
    func refresh() {
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

        paddingField.stringValue = String(format: "%.0f", preferences.panePadding)
        paddingStepper.doubleValue = Double(preferences.panePadding)
        labelField.stringValue = String(format: "%.0f", preferences.paneLabelSize)
        labelStepper.doubleValue = Double(preferences.paneLabelSize)
        themeLabel.stringValue = preferences.themeName ?? "Built-in"
        if let attached = attachedTerminal {
            matchButton.isEnabled = true
            matchNote.stringValue =
                "Another terminal is attached to this session. herdr gives the whole "
                + "session one theme and applies whichever client you used last, so the "
                + "colours change as you switch. Matching it stops that."
            backgroundWell.toolTip = Preferences.encode(attached.background)
        } else {
            matchButton.isEnabled = false
            matchNote.stringValue =
                "These colours are published to the herdr session, so they apply to "
                + "every client attached to it — including a herdr terminal showing the "
                + "same session."
        }

        soundsCheck.state = preferences.agentSounds ? .on : .off
        hibernatePopUp.selectItem(withTag: preferences.hibernateAfterHours ?? 0)
        lineField.stringValue = String(format: "%.0f", preferences.lineHeight * 100)
        lineStepper.doubleValue = Double(preferences.lineHeight * 100)
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

    @objc private func hibernateChanged() {
        let hours = hibernatePopUp.selectedTag()
        preferences.hibernateAfterHours = hours > 0 ? hours : nil
        apply()
    }

    @objc private func soundsChanged() {
        preferences.agentSounds = soundsCheck.state == .on
        apply()
    }

    @objc private func lineHeightStepped() {
        preferences.lineHeight = CGFloat(lineStepper.doubleValue) / 100
        apply()
    }

    @objc private func lineHeightChanged() {
        preferences.lineHeight = CGFloat(lineField.doubleValue).clamped(to: 100...200) / 100
        apply()
    }

    @objc private func labelSizeStepped() {
        preferences.paneLabelSize = CGFloat(labelStepper.doubleValue)
        apply()
    }

    @objc private func labelSizeChanged() {
        preferences.paneLabelSize = CGFloat(labelField.doubleValue).clamped(to: 8...18)
        apply()
    }

    @objc private func paddingStepped() {
        preferences.panePadding = CGFloat(paddingStepper.doubleValue)
        apply()
    }

    @objc private func paddingChanged() {
        preferences.panePadding = CGFloat(paddingField.doubleValue).clamped(to: 0...32)
        apply()
    }

    @objc private func colourChanged() {
        preferences.background = backgroundWell.color
        preferences.foreground = foregroundWell.color
        apply()
    }

    /// Loads a kitty theme file.
    ///
    /// A file rather than a list: kitty's themes are published as files, in
    /// their hundreds, and reading one is a great deal less work for everybody
    /// than picking twenty colours out of a panel.
    @objc private func loadTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "conf") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a kitty theme (.conf)"
        guard panel.runModal() == .OK, let url = panel.url,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }

        guard let theme = Theme(kittyConfiguration: text) else {
            let alert = NSAlert()
            alert.messageText = "That file is not a colour theme"
            alert.informativeText =
                "A kitty theme sets background, foreground and color0 through "
                + "color15. This one does not."
            alert.runModal()
            return
        }
        preferences.themeName = url.deletingPathExtension().lastPathComponent
        preferences.themeColors = theme.hexComponents
        // The wells override the theme, so a leftover pair would silently
        // repaint two of the twenty colours just loaded.
        preferences.background = nil
        preferences.foreground = nil
        apply()
    }

    @objc private func clearTheme() {
        preferences.themeName = nil
        preferences.themeColors = nil
        apply()
    }

    /// Adopts the other client's colours, which is the only thing that stops
    /// the terminal changing colour as you switch between them.
    @objc private func matchAttached() {
        guard let attached = attachedTerminal else { return }
        preferences.background = attached.background
        preferences.foreground = attached.foreground
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
        // Each handler has already written its one field through; the whole
        // struct is deliberately not written back.
        refresh()
        onChange(preferences)
    }
}
