import AppKit

/// Decodes herdr's packed cell colors.
///
/// herdr packs a `ratatui::style::Color` into a u32: `0x00` is one of the 17
/// named colors, `0x01` is a 256-color palette index, `0x02` is direct RGB.
/// `Reset` means "use the surface default", which the theme resolves.
enum PackedColor {
    case reset
    case rgb(NSColor)

    init(_ value: UInt32, theme: Theme, isForeground: Bool) {
        switch value >> 24 {
        case 0x00:
            let index = value & 0xFF
            if index == 0 {
                self = .reset
            } else {
                self = .rgb(theme.named(Int(index)))
            }
        case 0x01:
            self = .rgb(theme.indexed(Int(value & 0xFF)))
        case 0x02:
            self = .rgb(
                NSColor(
                    srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: 1))
        default:
            self = .reset
        }
    }

    func resolved(theme: Theme, isForeground: Bool) -> NSColor {
        switch self {
        case .reset: return isForeground ? theme.foreground : theme.background
        case .rgb(let color): return color
        }
    }
}

/// ratatui modifier bits, as herdr puts them on the wire.
struct CellStyle: OptionSet {
    let rawValue: UInt16
    static let bold = CellStyle(rawValue: 1 << 0)
    static let dim = CellStyle(rawValue: 1 << 1)
    static let italic = CellStyle(rawValue: 1 << 2)
    static let underlined = CellStyle(rawValue: 1 << 3)
    static let slowBlink = CellStyle(rawValue: 1 << 4)
    static let rapidBlink = CellStyle(rawValue: 1 << 5)
    static let reversed = CellStyle(rawValue: 1 << 6)
    static let hidden = CellStyle(rawValue: 1 << 7)
    static let crossedOut = CellStyle(rawValue: 1 << 8)
}

struct Theme {
    var background: NSColor
    var foreground: NSColor
    var cursor: NSColor
    var selection: NSColor
    /// The 16 ANSI colours, normal then bright.
    var ansi: [NSColor]

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    static let dark = Theme(
        background: rgb(18, 20, 26),
        foreground: rgb(217, 220, 226),
        cursor: rgb(217, 220, 226),
        selection: rgb(60, 82, 122),
        ansi: [
            rgb(46, 49, 56), rgb(230, 97, 107), rgb(115, 199, 122), rgb(230, 186, 102),
            rgb(102, 163, 235), rgb(194, 140, 235), rgb(89, 196, 201), rgb(199, 202, 209),
            rgb(89, 94, 105), rgb(247, 128, 135), rgb(148, 222, 153), rgb(247, 212, 135),
            rgb(135, 189, 247), rgb(217, 171, 247), rgb(122, 219, 224), rgb(240, 242, 245),
        ])

    /// Light mode is not the dark palette inverted: the same hues at dark-mode
    /// luminance are unreadable on white, so these are darkened to hold
    /// contrast against a light background.
    static let light = Theme(
        background: rgb(252, 252, 253),
        foreground: rgb(38, 42, 51),
        cursor: rgb(38, 42, 51),
        selection: rgb(180, 205, 245),
        ansi: [
            rgb(64, 68, 76), rgb(191, 45, 58), rgb(32, 133, 47), rgb(155, 110, 10),
            rgb(30, 100, 190), rgb(133, 62, 176), rgb(20, 130, 135), rgb(120, 125, 133),
            rgb(90, 95, 104), rgb(214, 66, 79), rgb(48, 156, 64), rgb(176, 130, 22),
            rgb(46, 120, 210), rgb(153, 82, 196), rgb(30, 150, 156), rgb(160, 165, 173),
        ])

    /// ratatui's named colours, in wire order (1...16).
    func named(_ index: Int) -> NSColor {
        (1...16).contains(index) ? ansi[index - 1] : foreground
    }

    /// The xterm 256-colour palette: 16 named, a 6x6x6 cube, then greys.
    func indexed(_ index: Int) -> NSColor {
        if index < 16 { return ansi[index] }
        if index < 232 {
            let i = index - 16
            let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(
                srgbRed: levels[(i / 36) % 6] / 255,
                green: levels[(i / 6) % 6] / 255,
                blue: levels[i % 6] / 255,
                alpha: 1)
        }
        let grey = CGFloat(8 + (index - 232) * 10) / 255
        return NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 1)
    }

    /// The palette as `count * 3` RGB bytes, for publishing to the server.
    var paletteBytes: [UInt8] {
        ansi.flatMap { color -> [UInt8] in
            guard let srgb = color.usingColorSpace(.sRGB) else { return [0, 0, 0] }
            return [
                UInt8((srgb.redComponent * 255).rounded()),
                UInt8((srgb.greenComponent * 255).rounded()),
                UInt8((srgb.blueComponent * 255).rounded()),
            ]
        }
    }

    func rgbBytes(of color: NSColor) -> (UInt8, UInt8, UInt8) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (
            UInt8((srgb.redComponent * 255).rounded()),
            UInt8((srgb.greenComponent * 255).rounded()),
            UInt8((srgb.blueComponent * 255).rounded())
        )
    }
}

extension NSColor {
    /// Whether a colour reads as dark, for picking contrasting chrome.
    var isDarkish: Bool {
        guard let srgb = usingColorSpace(.sRGB) else { return true }
        // Rec. 601 luma: close enough for deciding light-on-dark.
        let luma =
            0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
        return luma < 0.5
    }
}

extension NSColor {
    /// Whether two colours would read as different on screen.
    ///
    /// A tolerance rather than equality: the same colour can make the round
    /// trip through a composed surface a shade off, and a comparison that
    /// called that a difference would see one everywhere.
    func isNoticeablyDifferent(from other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else {
            return false
        }
        let distance =
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
        return distance > 0.05
    }
}
