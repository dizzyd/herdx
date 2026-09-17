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

    var fontName: String
    var fontSize: CGFloat
    var appearance: Appearance
    /// The palette the terminal draws with, and the one published to the
    /// server as the host background.
    ///
    /// Separate from the window's appearance because herdr applies the
    /// *foreground* client's host theme to every pane. With another client
    /// attached — a herdr TUI in a terminal — the two must agree or the pane
    /// re-themes every time focus moves between them. Following the window is
    /// right when this is the only client; matching the other terminal is right
    /// when it is not.
    var terminalAppearance: Appearance

    private enum Key {
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let appearance = "appearance"
        static let terminalAppearance = "terminalAppearance"
    }

    static var current: Preferences {
        get {
            let defaults = UserDefaults.standard
            return Preferences(
                fontName: defaults.string(forKey: Key.fontName) ?? "",
                fontSize: defaults.object(forKey: Key.fontSize) as? CGFloat ?? 13,
                appearance: defaults.string(forKey: Key.appearance)
                    .flatMap(Appearance.init(rawValue:)) ?? .system,
                terminalAppearance: defaults.string(forKey: Key.terminalAppearance)
                    .flatMap(Appearance.init(rawValue:)) ?? .system)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.fontName, forKey: Key.fontName)
            defaults.set(newValue.fontSize, forKey: Key.fontSize)
            defaults.set(newValue.appearance.rawValue, forKey: Key.appearance)
            defaults.set(newValue.terminalAppearance.rawValue, forKey: Key.terminalAppearance)
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

    func theme(matching systemIsDark: Bool) -> Theme {
        resolve(appearance, systemIsDark: systemIsDark)
    }

    /// The palette panes are drawn with, which follows the window unless
    /// pinned.
    func terminalTheme(matching systemIsDark: Bool) -> Theme {
        switch terminalAppearance {
        case .system: return theme(matching: systemIsDark)
        default: return resolve(terminalAppearance, systemIsDark: systemIsDark)
        }
    }

    private func resolve(_ appearance: Appearance, systemIsDark: Bool) -> Theme {
        switch appearance {
        case .system: return systemIsDark ? .dark : .light
        case .dark: return .dark
        case .light: return .light
        }
    }

    /// Fixed-pitch font families, for the preferences picker.
    static var monospacedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
    }
}
