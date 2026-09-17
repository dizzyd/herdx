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
    var ansi: [NSColor]

    static let `default` = Theme(
        background: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1),
        foreground: NSColor(srgbRed: 0.85, green: 0.86, blue: 0.88, alpha: 1),
        ansi: [
            // 0-7 normal
            NSColor(srgbRed: 0.18, green: 0.19, blue: 0.22, alpha: 1),
            NSColor(srgbRed: 0.90, green: 0.38, blue: 0.42, alpha: 1),
            NSColor(srgbRed: 0.45, green: 0.78, blue: 0.48, alpha: 1),
            NSColor(srgbRed: 0.90, green: 0.73, blue: 0.40, alpha: 1),
            NSColor(srgbRed: 0.40, green: 0.64, blue: 0.92, alpha: 1),
            NSColor(srgbRed: 0.76, green: 0.55, blue: 0.92, alpha: 1),
            NSColor(srgbRed: 0.35, green: 0.77, blue: 0.79, alpha: 1),
            NSColor(srgbRed: 0.78, green: 0.79, blue: 0.82, alpha: 1),
            // 8-15 bright
            NSColor(srgbRed: 0.35, green: 0.37, blue: 0.41, alpha: 1),
            NSColor(srgbRed: 0.97, green: 0.50, blue: 0.53, alpha: 1),
            NSColor(srgbRed: 0.58, green: 0.87, blue: 0.60, alpha: 1),
            NSColor(srgbRed: 0.97, green: 0.83, blue: 0.53, alpha: 1),
            NSColor(srgbRed: 0.53, green: 0.74, blue: 0.97, alpha: 1),
            NSColor(srgbRed: 0.85, green: 0.67, blue: 0.97, alpha: 1),
            NSColor(srgbRed: 0.48, green: 0.86, blue: 0.88, alpha: 1),
            NSColor(srgbRed: 0.94, green: 0.95, blue: 0.96, alpha: 1),
        ])

    /// ratatui's named colors, in wire order (1...16).
    func named(_ index: Int) -> NSColor {
        // 1=Black … 8=Gray, 9=DarkGray, 10=LightRed … 16=White
        switch index {
        case 1...8: return ansi[index - 1]
        case 9...16: return ansi[index - 1]
        default: return foreground
        }
    }

    /// xterm 256-color palette.
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
        let gray = CGFloat(8 + (index - 232) * 10) / 255
        return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
    }
}
