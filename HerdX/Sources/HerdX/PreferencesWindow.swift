import AppKit

/// The Settings window.
///
/// Standard macOS shape: opened from the app menu with ⌘,, one non-resizable
/// pane, changes applied immediately rather than behind an OK button, and the
/// font chosen through the system font panel rather than a bespoke picker.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let onChange: (Preferences) -> Void
    /// Opens the theme list for one slot. The app's, since the list previews
    /// on the terminal window and not on this one.
    private let onChooseTheme: (Preferences.Slot) -> Void

    private let fontLabel = NSTextField(labelWithString: "")
    private let fontNote = NSTextField(labelWithString: "")
    private let appearancePopUp = NSPopUpButton()
    private let lightThemeLabel = NSTextField(labelWithString: "")
    private let lightThemeName = NSTextField(labelWithString: "")
    private let darkThemeLabel = NSTextField(labelWithString: "")
    private let darkThemeName = NSTextField(labelWithString: "")
    private let paddingField = NSTextField()
    private let paddingStepper = NSStepper()
    private let labelField = NSTextField()
    private let labelStepper = NSStepper()
    private let lineField = NSTextField()
    private let lineStepper = NSStepper()
    private let soundsCheck = NSButton()
    private let hibernatePopUp = NSPopUpButton()
    private let hibernateNote = NSTextField(labelWithString: "")
    private let awakePopUp = NSPopUpButton()
    private let awakeNote = NSTextField(labelWithString: "")

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
    /// One of these is hidden when the appearance is pinned.
    private var lightThemeRow: NSGridRow?
    private var darkThemeRow: NSGridRow?

    init(
        onChange: @escaping (Preferences) -> Void,
        onChooseTheme: @escaping (Preferences.Slot) -> Void
    ) {
        self.onChange = onChange
        self.onChooseTheme = onChooseTheme

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
        window.center()
    }

    /// Sized to what it holds rather than to a number kept in step by hand:
    /// every row added so far has needed that number changing, and the last one
    /// was noticed only because a control fell off the bottom. Again whenever
    /// a row is shown or hidden, keeping the top edge where it was, which is
    /// where the eye is.
    private func fitToContent() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let top = window.frame.maxY
        window.setContentSize(content.fittingSize)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let change = NSButton(title: "Change…", target: self, action: #selector(chooseFont))
        change.bezelStyle = .rounded

        fontLabel.font = .systemFont(ofSize: 12)
        note(fontNote)

        let font = NSStackView(views: [fontLabel, change])
        font.orientation = .horizontal
        font.alignment = .firstBaseline
        font.spacing = 8

        for option in Preferences.Appearance.allCases {
            appearancePopUp.addItem(withTitle: option.title)
            appearancePopUp.lastItem?.representedObject = option.rawValue
        }
        appearancePopUp.target = self
        appearancePopUp.action = #selector(changed)

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
        padding.alignment = .firstBaseline
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
        labelSize.alignment = .firstBaseline
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
        lineHeight.alignment = .firstBaseline
        lineHeight.spacing = 4

        let lightTheme = themeRow(lightThemeName, choose: #selector(chooseLightTheme))
        let darkTheme = themeRow(darkThemeName, choose: #selector(chooseDarkTheme))

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

        note(hibernateNote)
        hibernateNote.stringValue =
            "Ends the processes of a local workspace left idle this long, keeping what its "
            + "agents were talking about. It stays in the sidebar; click it to bring it back."

        // Stacked with its note rather than given a grid row of its own: a
        // pop-up's frame runs well below the part you can see, so a row under
        // it leaves the note stranded.
        let hibernate = NSStackView(views: [hibernatePopUp, hibernateNote])
        hibernate.orientation = .vertical
        hibernate.alignment = .leading
        hibernate.spacing = 4

        // The same shape as Hibernate above: off is the default and belongs in
        // the control with the choices, not as a switch beside them.
        awakePopUp.removeAllItems()
        for mode in StayAwake.Mode.allCases {
            awakePopUp.addItem(withTitle: mode.title)
            awakePopUp.lastItem?.representedObject = mode.rawValue
        }
        awakePopUp.target = self
        awakePopUp.action = #selector(awakeChanged)

        note(awakeNote)
        awakeNote.stringValue =
            "Stops the display going dark on its own, the way  caffeinate -d  does. Closing "
            + "the lid still sleeps. While an agent is working covers one that is waiting on "
            + "you too, since a dark screen locks and a locked screen is also what silences "
            + "the sounds above."

        let awake = NSStackView(views: [awakePopUp, awakeNote])
        awake.orientation = .vertical
        awake.alignment = .leading
        awake.spacing = 4

        soundsCheck.setButtonType(.switch)
        soundsCheck.title = "Play a sound when an agent finishes or needs you"
        soundsCheck.target = self
        soundsCheck.action = #selector(soundsChanged)

        // One grid for every section rather than a grid each, so labels and
        // controls line up down the whole window instead of per section.
        let sections: [(title: String, rows: [[NSView]])] = [
            ("Text", [
                [label("Font:"), font],
                [NSGridCell.emptyContentView, fontNote],
                [label("Line height:"), lineHeight],
            ]),
            ("Appearance", [
                [label("Mode:"), appearancePopUp],
                [lightThemeLabel, lightTheme],
                [darkThemeLabel, darkTheme],
            ]),
            ("Panes", [
                [label("Padding:"), padding],
                [label("Label size:"), labelSize],
            ]),
            ("Agents", [
                [label("Sounds:"), soundsCheck],
                [label("Keep awake:"), awake],
                [label("Hibernate:"), hibernate],
            ]),
        ]
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        // On the text, not the frames: a label is shorter than the control
        // beside it, and top-aligned it sits visibly above that control's text.
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        for (index, section) in sections.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                let row = spanning(line, in: grid)
                row.topPadding = 10
                row.bottomPadding = 4
                row.cell(at: 0).xPlacement = .fill
            }
            spanning(heading(section.title), in: grid).bottomPadding = 2
            for row in section.rows {
                grid.addRow(with: row)
            }
        }
        noteRow = grid.cell(for: fontNote)?.row
        lightThemeRow = grid.cell(for: lightTheme)?.row
        darkThemeRow = grid.cell(for: darkTheme)?.row
        // A note belongs to the control above it, so it sits closer to that
        // than to the next row.
        noteRow?.topPadding = -4

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

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    /// A row that runs the width of the grid, from the leading edge.
    @discardableResult
    private func spanning(_ view: NSView, in grid: NSGridView) -> NSGridRow {
        let row = grid.addRow(with: [view, NSGridCell.emptyContentView])
        let index = grid.index(of: row)
        grid.mergeCells(
            inHorizontalRange: NSRange(location: 0, length: 2),
            verticalRange: NSRange(location: index, length: 1))
        row.cell(at: 0).xPlacement = .leading
        return row
    }

    /// A theme's name and the button that changes it.
    private func themeRow(_ name: NSTextField, choose: Selector) -> NSView {
        name.lineBreakMode = .byTruncatingTail
        // Capped, and allowed to give way: the window is sized to what it
        // holds, so an imported file's long name would otherwise widen it.
        name.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = NSButton(title: "Choose…", target: self, action: choose)
        button.bezelStyle = .rounded
        let row = NSStackView(views: [name, button])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// Explanatory text under a control, all wrapped to one width so the notes
    /// make one column rather than three ragged ones.
    private func note(_ field: NSTextField) {
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byWordWrapping
        field.preferredMaxLayoutWidth = 340
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
        // Following the system uses both, so both are shown and named; pinned,
        // only one is ever used, and "Dark theme" beside "Dark" says it twice.
        let following = preferences.appearance == .system
        lightThemeRow?.isHidden = preferences.appearance == .dark
        darkThemeRow?.isHidden = preferences.appearance == .light
        lightThemeLabel.stringValue = following ? "Light theme:" : "Theme:"
        darkThemeLabel.stringValue = following ? "Dark theme:" : "Theme:"
        lightThemeName.stringValue = preferences.lightTheme?.name ?? "Built-in"
        darkThemeName.stringValue = preferences.darkTheme?.name ?? "Built-in"
        // The whole name, for when the row has cut it short.
        lightThemeName.toolTip = lightThemeName.stringValue
        darkThemeName.toolTip = darkThemeName.stringValue

        paddingField.stringValue = String(format: "%.0f", preferences.panePadding)
        paddingStepper.doubleValue = Double(preferences.panePadding)
        labelField.stringValue = String(format: "%.0f", preferences.paneLabelSize)
        labelStepper.doubleValue = Double(preferences.paneLabelSize)

        soundsCheck.state = preferences.agentSounds ? .on : .off
        hibernatePopUp.selectItem(withTag: preferences.hibernateAfterHours ?? 0)
        awakePopUp.selectItem(
            at: StayAwake.Mode.allCases.firstIndex(of: preferences.stayAwake) ?? 0)
        lineField.stringValue = String(format: "%.0f", preferences.lineHeight * 100)
        lineStepper.doubleValue = Double(preferences.lineHeight * 100)
        fitToContent()
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

    @objc private func awakeChanged() {
        guard let raw = awakePopUp.selectedItem?.representedObject as? String,
            let mode = StayAwake.Mode(rawValue: raw)
        else { return }
        preferences.stayAwake = mode
        changed()
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

    @objc private func chooseLightTheme() {
        onChooseTheme(.light)
    }

    @objc private func chooseDarkTheme() {
        onChooseTheme(.dark)
    }

    @objc private func changed() {
        preferences.appearance =
            (appearancePopUp.selectedItem?.representedObject as? String)
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
