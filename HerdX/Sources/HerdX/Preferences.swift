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
    /// Exact terminal colours, when the built-in palettes are not what the
    /// session uses.
    ///
    /// herdr compares actual RGB when deciding whether a client's host theme
    /// changed, so "dark" is not close enough to match another terminal's
    /// particular background — it has to be the same colour.
    var background: NSColor?
    var foreground: NSColor?
    /// Space between the terminal and the window edge, in points.
    var margin: CGFloat
    /// Space between a pane's border and its text, in points.
    var panePadding: CGFloat

    private enum Key {
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let appearance = "appearance"
        static let terminalAppearance = "terminalAppearance"
        static let background = "terminalBackground"
        static let foreground = "terminalForeground"
        static let margin = "terminalMargin"
        static let panePadding = "panePadding"
    }

    /// Colours round-trip through `#rrggbb`, so they stay readable in defaults
    /// and survive a colour-space change.
    private static func decode(_ hex: String?) -> NSColor? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"),
            let value = Int(hex.dropFirst(), radix: 16)
        else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
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
        get {
            let defaults = UserDefaults.standard
            return Preferences(
                fontName: defaults.string(forKey: Key.fontName) ?? "",
                fontSize: defaults.object(forKey: Key.fontSize) as? CGFloat ?? 13,
                appearance: defaults.string(forKey: Key.appearance)
                    .flatMap(Appearance.init(rawValue:)) ?? .system,
                terminalAppearance: defaults.string(forKey: Key.terminalAppearance)
                    .flatMap(Appearance.init(rawValue:)) ?? .system,
                background: decode(defaults.string(forKey: Key.background)),
                foreground: decode(defaults.string(forKey: Key.foreground)),
                margin: defaults.object(forKey: Key.margin) as? CGFloat ?? 4,
                panePadding: defaults.object(forKey: Key.panePadding) as? CGFloat ?? 6)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.fontName, forKey: Key.fontName)
            defaults.set(newValue.fontSize, forKey: Key.fontSize)
            defaults.set(newValue.appearance.rawValue, forKey: Key.appearance)
            defaults.set(newValue.terminalAppearance.rawValue, forKey: Key.terminalAppearance)
            defaults.set(encode(newValue.background), forKey: Key.background)
            defaults.set(encode(newValue.foreground), forKey: Key.foreground)
            defaults.set(newValue.margin, forKey: Key.margin)
            defaults.set(newValue.panePadding, forKey: Key.panePadding)
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
        var theme: Theme
        switch terminalAppearance {
        case .system: theme = self.theme(matching: systemIsDark)
        default: theme = resolve(terminalAppearance, systemIsDark: systemIsDark)
        }
        // The palette still comes from the chosen appearance; only the default
        // colours are overridden, which is what a terminal's "background" and
        // "text" settings mean.
        if let background {
            theme.background = background
            theme.cursor = foreground ?? theme.cursor
        }
        if let foreground {
            theme.foreground = foreground
            theme.cursor = foreground
        }
        return theme
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
