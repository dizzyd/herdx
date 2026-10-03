import AppKit

/// User settings, persisted in `UserDefaults`.
///
/// Deliberately small: a terminal's settings that matter day to day are the
/// font and whether it follows the system appearance.
struct Preferences {
    enum Appearance: String, CaseIterable {
        case system, dark, light

        var title: String {
            switch self {
            case .system: return "Follow System"
            case .dark: return "Dark"
            case .light: return "Light"
            }
        }
    }

    /// Where a theme is kept: one for light, one for dark.
    ///
    /// Storage, not what is on screen: Settings can change the dark theme
    /// while the light one is showing.
    enum Slot: Equatable {
        case light, dark

        var title: String {
            switch self {
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    /// A palette chosen by name.
    ///
    /// A whole palette rather than two default colours: a kitty theme is
    /// twenty colours, and keeping only two of them would throw away the part
    /// that makes one theme look different from another.
    struct ThemeChoice: Equatable {
        var name: String
        var colors: [String]
    }

    var fontName: String
    var fontSize: CGFloat
    var appearance: Appearance
    /// The theme for each appearance, or nil for the built-in one.
    ///
    /// Two rather than one so that following the system means something for
    /// the terminal and not only for the window. Pinned to Light or Dark, only
    /// that one is used; the other is kept for when it is not pinned.
    var lightTheme: ThemeChoice?
    var darkTheme: ThemeChoice?
    /// Space between a pane's border and its text, in points.
    var panePadding: CGFloat
    /// Size of the label on a pane's frame, in points.
    var paneLabelSize: CGFloat
    /// Line height as a multiple of the font's natural one.
    var lineHeight: CGFloat
    /// How the sidebar is arranged, as herdr's own panel puts it.
    var sidebarArrangement: String?
    /// The herdr session to attach to, by name. Nil opens whichever one the
    /// core would pick on its own.
    var sessionName: String?
    /// How many hours a local workspace may sit idle before its processes are
    /// ended, or nil to leave them alone.
    ///
    /// Off unless it is turned on. It ends processes without asking, and the
    /// first time that surprises somebody it should be because they chose it.
    var hibernateAfterHours: Int?
    /// Whether an agent changing state makes a sound.
    var agentSounds: Bool
    /// When to keep the display from sleeping. See `StayAwake`.
    var stayAwake: StayAwake.Mode
    /// Sessions that attach the local server alone.
    ///
    /// Named rather than counted: a session is remembered by the name it is
    /// listed under, so the choice survives being switched away from and
    /// relaunched into. Everything not in here attaches the saved machines,
    /// which is what a machine in herdr's catalog is for.
    var localOnlySessions: [String]

    subscript(theme slot: Slot) -> ThemeChoice? {
        get { slot == .light ? lightTheme : darkTheme }
        set {
            switch slot {
            case .light: lightTheme = newValue
            case .dark: darkTheme = newValue
            }
        }
    }

    /// The slot in use: the pinned one, or the system's.
    func slot(matching systemIsDark: Bool) -> Slot {
        switch appearance {
        case .system: return systemIsDark ? .dark : .light
        case .dark: return .dark
        case .light: return .light
        }
    }

    private enum Key {
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let appearance = "appearance"
        static let stayAwake = "stayAwake"
        static let lightThemeName = "lightThemeName"
        static let lightThemeColors = "lightThemeColors"
        static let darkThemeName = "darkThemeName"
        static let darkThemeColors = "darkThemeColors"
        static let panePadding = "panePadding"
        static let paneLabelSize = "paneLabelSize"
        static let lineHeight = "lineHeight"
        static let sidebarArrangement = "sidebarArrangement"
        static let hibernateAfterHours = "hibernateAfterHours"
        static let sessionName = "sessionName"
        static let localOnlySessions = "localOnlySessions"
        static let agentSounds = "agentSounds"
        /// Before there was a theme per appearance: one loaded palette, used
        /// whatever the appearance, with a separate terminal appearance and two
        /// colour overrides beside it. Read once, to carry what they put on
        /// screen over, and removed on the next save.
        static let legacyThemeName = "themeName"
        static let legacyThemeColors = "themeColors"
        static let legacyTerminalAppearance = "terminalAppearance"
        static let legacyBackground = "terminalBackground"
        static let legacyForeground = "terminalForeground"
        static let legacy = [
            legacyThemeName, legacyThemeColors, legacyTerminalAppearance,
            legacyBackground, legacyForeground,
        ]
    }

    static func encode(_ color: NSColor?) -> String? {
        guard let srgb = color?.usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02x%02x%02x",
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded()))
    }

    static var current: Preferences {
        get { load(from: .standard) }
        set { newValue.save(to: .standard) }
    }

    static func load(from defaults: UserDefaults) -> Preferences {
        func choice(_ name: String, _ colors: String) -> ThemeChoice? {
            guard let name = defaults.string(forKey: name),
                let colors = defaults.stringArray(forKey: colors)
            else { return nil }
            return ThemeChoice(name: name, colors: colors)
        }
        let appearance =
            defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:))
            ?? .system
        var lightTheme = choice(Key.lightThemeName, Key.lightThemeColors)
        var darkTheme = choice(Key.darkThemeName, Key.darkThemeColors)
        // Upgrading should not change what is on screen, so each slot starts
        // as whatever the old settings drew in that appearance.
        if lightTheme == nil, darkTheme == nil,
            Key.legacy.contains(where: { defaults.object(forKey: $0) != nil })
        {
            lightTheme = legacyTheme(from: defaults, appearance: appearance, for: .light)
            darkTheme = legacyTheme(from: defaults, appearance: appearance, for: .dark)
        }
        return Preferences(
            fontName: defaults.string(forKey: Key.fontName) ?? "",
            fontSize: defaults.object(forKey: Key.fontSize) as? CGFloat ?? 13,
            appearance: appearance,
            lightTheme: lightTheme,
            darkTheme: darkTheme,
            panePadding: defaults.object(forKey: Key.panePadding) as? CGFloat ?? 6,
            paneLabelSize: defaults.object(forKey: Key.paneLabelSize) as? CGFloat ?? 11,
            lineHeight: defaults.object(forKey: Key.lineHeight) as? CGFloat ?? 1,
            sidebarArrangement: defaults.string(forKey: Key.sidebarArrangement),
            sessionName: defaults.string(forKey: Key.sessionName),
            hibernateAfterHours: defaults.object(forKey: Key.hibernateAfterHours) as? Int,
            agentSounds: defaults.object(forKey: Key.agentSounds) as? Bool ?? true,
            // Off unless it is turned on, like hibernation: holding a Mac's
            // display awake is not something to inherit by upgrading.
            stayAwake: defaults.string(forKey: Key.stayAwake)
                .flatMap(StayAwake.Mode.init(rawValue:)) ?? .never,
            localOnlySessions: defaults.stringArray(forKey: Key.localOnlySessions) ?? [])
    }

    /// What the settings from before there were two themes drew for one slot,
    /// or nil when that was the built-in palette.
    ///
    /// The old rules, kept only here: a loaded palette won whatever the
    /// appearance; without one, the terminal followed its own appearance
    /// setting, or the window's; and a background or text colour overrode
    /// either.
    private static func legacyTheme(
        from defaults: UserDefaults, appearance: Appearance, for slot: Slot
    ) -> ThemeChoice? {
        let background = defaults.string(forKey: Key.legacyBackground).flatMap(Theme.hex)
        let foreground = defaults.string(forKey: Key.legacyForeground).flatMap(Theme.hex)
        let name = defaults.string(forKey: Key.legacyThemeName)
        var theme: Theme
        if let colors = defaults.stringArray(forKey: Key.legacyThemeColors),
            let loaded = Theme(hexComponents: colors)
        {
            theme = loaded
            if let background { theme.background = background }
            if let foreground { theme.foreground = foreground }
        } else {
            // Worked out as if following the system when the window is pinned
            // to the other appearance: that slot was never on screen, and is
            // what following the system will show later.
            let pinnedToTheOther =
                (appearance == .dark && slot == .light) || (appearance == .light && slot == .dark)
            let window = pinnedToTheOther ? .system : appearance
            let terminal =
                defaults.string(forKey: Key.legacyTerminalAppearance)
                .flatMap(Appearance.init(rawValue:)) ?? .system
            let drawn = terminal == .system ? window : terminal
            let dark = drawn == .system ? slot == .dark : drawn == .dark
            theme = dark ? .dark : .light
            if let background {
                theme.background = background
                theme.cursor = foreground ?? theme.cursor
            }
            if let foreground {
                theme.foreground = foreground
                theme.cursor = foreground
            }
        }
        guard theme.hexComponents != Self.theme(nil, for: slot).hexComponents else {
            return nil
        }
        let adjusted = background != nil || foreground != nil
        return ThemeChoice(
            name: name.map { adjusted ? "\($0) (adjusted)" : $0 } ?? "Custom",
            colors: theme.hexComponents)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(fontName, forKey: Key.fontName)
        defaults.set(fontSize, forKey: Key.fontSize)
        defaults.set(appearance.rawValue, forKey: Key.appearance)
        defaults.set(lightTheme?.name, forKey: Key.lightThemeName)
        defaults.set(lightTheme?.colors, forKey: Key.lightThemeColors)
        defaults.set(darkTheme?.name, forKey: Key.darkThemeName)
        defaults.set(darkTheme?.colors, forKey: Key.darkThemeColors)
        defaults.set(panePadding, forKey: Key.panePadding)
        defaults.set(paneLabelSize, forKey: Key.paneLabelSize)
        defaults.set(lineHeight, forKey: Key.lineHeight)
        defaults.set(sidebarArrangement, forKey: Key.sidebarArrangement)
        defaults.set(sessionName, forKey: Key.sessionName)
        defaults.set(hibernateAfterHours, forKey: Key.hibernateAfterHours)
        defaults.set(agentSounds, forKey: Key.agentSounds)
        defaults.set(stayAwake.rawValue, forKey: Key.stayAwake)
        defaults.set(localOnlySessions, forKey: Key.localOnlySessions)
        // Carried over by `load` already, so what they held is in the two
        // slots now; left behind, a cleared slot would bring them back.
        for key in Key.legacy {
            defaults.removeObject(forKey: key)
        }
    }

    /// The configured font, falling back to the system monospace face.
    ///
    /// A proportional font would break the grid, so a named font is only
    /// honoured when it is actually fixed-pitch.
    var font: NSFont {
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: fontSize),
            font.isFixedPitch
        {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// The palette panes are drawn with.
    func terminalTheme(matching systemIsDark: Bool) -> Theme {
        let slot = slot(matching: systemIsDark)
        return Self.theme(self[theme: slot], for: slot)
    }

    /// A choice's palette, or the built-in one for that slot when there is no
    /// choice or it no longer reads.
    static func theme(_ choice: ThemeChoice?, for slot: Slot) -> Theme {
        choice.flatMap { Theme(hexComponents: $0.colors) } ?? (slot == .dark ? .dark : .light)
    }

    /// Fixed-pitch font families, for the preferences picker.
    static var monospacedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
    }
}
