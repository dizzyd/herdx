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
        let shifted = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": return .newTab
        case "v": return .splitRight
        case "-": return .splitDown
        case "h": return .focusLeft
        case "j": return .focusDown
        case "k": return .focusUp
        case "l": return .focusRight
        case "n": return shifted ? .newWorkspace : .nextTab
        case "p": return .previousTab
        case "x": return shifted ? .closeTab : .closePane
        case "z": return .zoomPane
        default: return nil
        }
    }
}
