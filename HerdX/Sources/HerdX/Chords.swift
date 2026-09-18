import AppKit

/// herdr's 38 stable endpoint methods, as the UI uses them.
///
/// The payload shape is frozen for generation 1, so these are built as plain
/// JSON rather than through a generated client.
enum Command {
    case newTab, closeTab, nextTab, previousTab
    case splitRight, splitDown
    case focusLeft, focusDown, focusUp, focusRight
    case closePane, zoomPane
    case newWorkspace
    case focusPane(String)
    case focusTab(String)
    case focusWorkspace(String)
    case closeTabWithID(String)
    /// Handled entirely in the client; it has no endpoint method.
    case copyMode
    /// Likewise: the keymap is ours, so the reference to it has to be ours too.
    case help

    var method: String {
        switch self {
        case .newTab: return "tab.create"
        case .closeTab: return "tab.close"
        case .nextTab, .previousTab: return "tab.focus"
        case .splitRight, .splitDown: return "pane.split"
        case .focusLeft, .focusDown, .focusUp, .focusRight: return "pane.focus_direction"
        case .closePane: return "pane.close"
        case .zoomPane: return "pane.zoom"
        case .newWorkspace: return "workspace.create"
        case .focusPane: return "pane.focus"
        case .focusTab: return "tab.focus"
        case .focusWorkspace: return "workspace.focus"
        case .closeTabWithID: return "tab.close"
        case .copyMode, .help: return ""
        }
    }

    var params: [String: Any] {
        switch self {
        case .splitRight: return ["direction": "right"]
        case .splitDown: return ["direction": "down"]
        case .focusLeft: return ["direction": "left"]
        case .focusDown: return ["direction": "down"]
        case .focusUp: return ["direction": "up"]
        case .focusRight: return ["direction": "right"]
        case .nextTab: return ["relative": 1]
        case .previousTab: return ["relative": -1]
        case .focusPane(let id): return ["pane_id": id]
        case .focusTab(let id): return ["tab_id": id]
        case .focusWorkspace(let id): return ["workspace_id": id]
        case .closeTabWithID(let id): return ["tab_id": id]
        default: return [:]
        }
    }

    /// herdr's `Method` is an adjacently tagged enum, so `params` is required
    /// even for methods that take nothing. Omitting it fails to parse.
    func requestJSON(id: String) -> String? {
        let body: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One key of the `ctrl+b` keymap.
struct PrefixBinding {
    let key: String
    /// Whether shift is what distinguishes this from another binding on the
    /// same key. Only meaningful where two bindings share one.
    let shift: Bool
    let command: Command
    let title: String

    /// How the key reads in the help: a shifted letter is the capital, and
    /// punctuation already carries its own shift.
    var label: String { shift && key.count == 1 ? key.uppercased() : key }
}

/// Resolves keystrokes to commands.
///
/// Two schemes run side by side, because both are muscle memory for somebody:
/// macOS ⌘ chords (also surfaced in the menu bar) and herdr's tmux-style
/// `ctrl+b` prefix. The client owns its keymap — we told the server
/// `endpoint_keybindings: false` — so anything not claimed here falls through to
/// the focused pane untouched.
final class ChordResolver {
    /// True while the prefix has been pressed and we are awaiting its partner.
    private(set) var prefixArmed = false

    /// herdr's default prefix is ctrl+b.
    private let prefixKeyCode = 11  // 'b'

    /// The second half of every chord, as a table rather than a switch, so the
    /// help screen and the keymap cannot drift apart: both read this.
    static let prefixBindings: [PrefixBinding] = [
        PrefixBinding(key: "c", shift: false, command: .newTab, title: "New tab"),
        PrefixBinding(key: "n", shift: false, command: .nextTab, title: "Next tab"),
        PrefixBinding(key: "p", shift: false, command: .previousTab, title: "Previous tab"),
        PrefixBinding(key: "x", shift: false, command: .closePane, title: "Close pane"),
        PrefixBinding(key: "x", shift: true, command: .closeTab, title: "Close tab"),
        PrefixBinding(key: "v", shift: false, command: .splitRight, title: "Split right"),
        PrefixBinding(key: "-", shift: false, command: .splitDown, title: "Split down"),
        PrefixBinding(key: "z", shift: false, command: .zoomPane, title: "Zoom pane"),
        PrefixBinding(key: "h", shift: false, command: .focusLeft, title: "Select pane left"),
        PrefixBinding(key: "j", shift: false, command: .focusDown, title: "Select pane down"),
        PrefixBinding(key: "k", shift: false, command: .focusUp, title: "Select pane up"),
        PrefixBinding(key: "l", shift: false, command: .focusRight, title: "Select pane right"),
        PrefixBinding(key: "n", shift: true, command: .newWorkspace, title: "New workspace"),
        PrefixBinding(key: "[", shift: false, command: .copyMode, title: "Copy mode"),
        PrefixBinding(key: "?", shift: false, command: .help, title: "This list"),
    ]

    func reset() { prefixArmed = false }

    /// Returns a command when the event completes a chord, and whether the
    /// event was consumed (armed prefixes consume without producing a command).
    func resolve(_ event: NSEvent) -> (command: Command?, consumed: Bool) {
        let flags = event.modifierFlags

        if prefixArmed {
            prefixArmed = false
            return (prefixCommand(event), true)
        }

        if flags.contains(.control), !flags.contains(.command), Int(event.keyCode) == prefixKeyCode
        {
            prefixArmed = true
            return (nil, true)
        }

        // ⌘ chords are declared in the menu, so AppKit dispatches them before
        // the view ever sees a keyDown. Nothing to do here.
        return (nil, false)
    }

    /// The second key of a `ctrl+b` chord.
    private func prefixCommand(_ event: NSEvent) -> Command? {
        guard let typed = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let candidates = Self.prefixBindings.filter { $0.key == typed }
        // Shift only decides between two bindings on the same key. Asking it to
        // decide a lone binding would lose "?", which cannot be typed without
        // shift on most layouts.
        if candidates.count == 1 { return candidates[0].command }
        return candidates.first { $0.shift == event.modifierFlags.contains(.shift) }?.command
    }
}
