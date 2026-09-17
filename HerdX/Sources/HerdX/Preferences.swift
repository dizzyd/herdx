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

    private enum Key {
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let appearance = "appearance"
    }

    static var current: Preferences {
        get {
            let defaults = UserDefaults.standard
            return Preferences(
                fontName: defaults.string(forKey: Key.fontName) ?? "",
                fontSize: defaults.object(forKey: Key.fontSize) as? CGFloat ?? 13,
                appearance: defaults.string(forKey: Key.appearance)
                    .flatMap(Appearance.init(rawValue:)) ?? .system)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.fontName, forKey: Key.fontName)
            defaults.set(newValue.fontSize, forKey: Key.fontSize)
            defaults.set(newValue.appearance.rawValue, forKey: Key.appearance)
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
