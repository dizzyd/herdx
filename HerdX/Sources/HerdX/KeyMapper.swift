import AppKit
import CHerdrCore

/// Translates `NSEvent` into herdr's semantic key vocabulary.
///
/// herdr's endpoint takes *semantic* keys, not VT bytes: the server encodes
/// them for whatever keyboard protocol the pane's program negotiated. That
/// means we never synthesise escape sequences here.
enum KeyMapper {
    struct Mapped {
        var kind: UInt16
        var codepoint: UInt32
        var modifiers: UInt8
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        var bits: UInt8 = 0
        if flags.contains(.shift) { bits |= UInt8(HX_MOD_SHIFT) }
        if flags.contains(.control) { bits |= UInt8(HX_MOD_CONTROL) }
        if flags.contains(.option) { bits |= UInt8(HX_MOD_ALT) }
        if flags.contains(.command) { bits |= UInt8(HX_MOD_SUPER) }
        return bits
    }

    static func map(_ event: NSEvent) -> Mapped? {
        let mods = modifiers(event.modifierFlags)

        if let special = specialKey(event) {
            return Mapped(kind: special, codepoint: 0, modifiers: mods)
        }

        // `charactersIgnoringModifiers` gives the unmodified key, which is what
        // a binding means by "ctrl+b" regardless of what the layout produced.
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return nil
        }

        // Printable input with no control-ish modifier is better delivered as
        // committed text, so IME and dead keys compose correctly.
        let controlish = event.modifierFlags.intersection([.control, .command, .option])
        if controlish.isEmpty && scalar.value >= 0x20 && scalar.value != 0x7F {
            return nil
        }

        return Mapped(kind: UInt16(HX_KEY_CHAR), codepoint: scalar.value, modifiers: mods)
    }

    private static func specialKey(_ event: NSEvent) -> UInt16? {
        switch Int(event.keyCode) {
        case 36, 76: return UInt16(HX_KEY_ENTER)
        case 48:
            return event.modifierFlags.contains(.shift)
                ? UInt16(HX_KEY_BACKTAB) : UInt16(HX_KEY_TAB)
        case 51: return UInt16(HX_KEY_BACKSPACE)
        case 53: return UInt16(HX_KEY_ESC)
        case 117: return UInt16(HX_KEY_DELETE)
        case 115: return UInt16(HX_KEY_HOME)
        case 119: return UInt16(HX_KEY_END)
        case 116: return UInt16(HX_KEY_PAGEUP)
        case 121: return UInt16(HX_KEY_PAGEDOWN)
        case 123: return UInt16(HX_KEY_LEFT)
        case 124: return UInt16(HX_KEY_RIGHT)
        case 125: return UInt16(HX_KEY_DOWN)
        case 126: return UInt16(HX_KEY_UP)
        case 122: return UInt16(HX_KEY_F1)       // F1
        case 120: return UInt16(HX_KEY_F1) + 1   // F2
        case 99: return UInt16(HX_KEY_F1) + 2    // F3
        case 118: return UInt16(HX_KEY_F1) + 3   // F4
        case 96: return UInt16(HX_KEY_F1) + 4    // F5
        case 97: return UInt16(HX_KEY_F1) + 5    // F6
        case 98: return UInt16(HX_KEY_F1) + 6    // F7
        case 100: return UInt16(HX_KEY_F1) + 7   // F8
        case 101: return UInt16(HX_KEY_F1) + 8   // F9
        case 109: return UInt16(HX_KEY_F1) + 9   // F10
        case 103: return UInt16(HX_KEY_F1) + 10  // F11
        case 111: return UInt16(HX_KEY_F1) + 11  // F12
        default: return nil
        }
    }
}
