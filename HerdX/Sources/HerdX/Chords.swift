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
    /// The same workspace, on this Mac rather than on whatever is on screen.
    case newLocalWorkspace
    /// Asked before hibernating, never from a keystroke: what agents are in a
    /// workspace, what is running in a pane, and the shape of a tab.
    case agentList
    case paneProcessInfo(String)
    case layoutExport(String)
    case focusPane(String)
    case focusTab(String)
    case focusWorkspace(String)
    case closeTabWithID(String)
    case closePaneWithID(String)
    /// Handled entirely in the client; it has no endpoint method.
    case copyMode
    /// Likewise: the keymap is ours, so the reference to it has to be ours too.
    case help
    case settings
    case detach
    case toggleSidebar
    case reloadConfig
    case closeWorkspace(String)
    case swapLeft, swapDown, swapUp, swapRight
    case editScrollback(String)
    case renameTab(String, String)
    case renamePane(String, String)
    case renameWorkspace(String, String)
    case resizePane(String)

    var method: String {
        switch self {
        case .newTab: return "tab.create"
        case .closeTab: return "tab.close"
        case .nextTab, .previousTab: return "tab.focus"
        case .splitRight, .splitDown: return "pane.split"
        case .focusLeft, .focusDown, .focusUp, .focusRight: return "pane.focus_direction"
        case .closePane, .closePaneWithID: return "pane.close"
        case .zoomPane: return "pane.zoom"
        case .newWorkspace: return "workspace.create"
        case .focusPane: return "pane.focus"
        case .focusTab: return "tab.focus"
        case .focusWorkspace: return "workspace.focus"
        case .closeTabWithID: return "tab.close"
        case .swapLeft, .swapDown, .swapUp, .swapRight: return "pane.swap"
        case .editScrollback: return "pane.edit_scrollback"
        case .renameTab: return "tab.rename"
        case .renamePane: return "pane.rename"
        case .renameWorkspace: return "workspace.rename"
        case .resizePane: return "pane.resize"
        case .reloadConfig: return "server.reload_config"
        case .closeWorkspace: return "workspace.close"
        case .agentList: return "agent.list"
        case .paneProcessInfo: return "pane.process_info"
        case .layoutExport: return "layout.export"
        // Client-side: no endpoint method, because none of it is the server's
        // business.
        case .copyMode, .help, .settings, .detach, .toggleSidebar: return ""
        // Resolved before it reaches the wire. It is workspace.create aimed at
        // a named machine, and the aiming is `invoke`'s job rather than
        // anything the request itself can say.
        case .newLocalWorkspace: return ""
        }
    }

    /// `nextTab` and `previousTab` carry none: herdr's `tab.focus` takes a tab
    /// id and has no relative form, so the neighbour is resolved from the
    /// snapshot before the request is built.
    var params: [String: Any] {
        switch self {
        case .splitRight: return ["direction": "right"]
        case .splitDown: return ["direction": "down"]
        case .focusLeft: return ["direction": "left"]
        case .focusDown: return ["direction": "down"]
        case .focusUp: return ["direction": "up"]
        case .focusRight: return ["direction": "right"]
        case .focusPane(let id): return ["pane_id": id]
        case .focusTab(let id): return ["tab_id": id]
        case .focusWorkspace(let id): return ["workspace_id": id]
        case .closeTabWithID(let id): return ["tab_id": id]
        case .closePaneWithID(let id): return ["pane_id": id]
        // `focus` defaults to false, so without it the thing you just asked
        // for is created somewhere you are not looking.
        case .newTab, .newWorkspace: return ["focus": true]
        case .closeWorkspace(let id): return ["workspace_id": id]
        case .swapLeft: return ["direction": "left"]
        case .swapDown: return ["direction": "down"]
        case .swapUp: return ["direction": "up"]
        case .swapRight: return ["direction": "right"]
        case .editScrollback(let id): return ["pane_id": id]
        case .paneProcessInfo(let id): return ["pane_id": id]
        // By tab: a workspace can hold several, and each is its own tree.
        case .layoutExport(let id): return ["tab_id": id]
        case .renameTab(let id, let label): return ["tab_id": id, "label": label]
        case .renamePane(let id, let label): return ["pane_id": id, "label": label]
        case .renameWorkspace(let id, let label): return ["workspace_id": id, "label": label]
        // No amount: herdr picks its own step, which is the one its own
        // resize mode moves by.
        case .resizePane(let direction): return ["direction": direction]
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

/// Resolves keystrokes against the keymap herdr published.
///
/// Two schemes run side by side, because both are muscle memory for somebody:
/// macOS ⌘ chords (also surfaced in the menu bar) and herdr's prefix. The
/// client owns its keymap — we told the server `endpoint_keybindings: false` —
/// so anything not claimed here falls through to the focused pane untouched.
///
/// What the prefix is, and what follows it, comes from the server rather than
/// from a table here: see `Keymap`.
final class ChordResolver {
    /// True while the prefix has been pressed and we are awaiting its partner.
    private(set) var prefixArmed = false

    /// herdr's defaults until a snapshot brings the user's own.
    var keymap = Keymap.fallback

    func reset() { prefixArmed = false }

    /// Returns an action when the event completes a chord, and whether the
    /// event was consumed (armed prefixes consume without producing one).
    func resolve(_ event: NSEvent) -> (action: Keymap.Action?, consumed: Bool) {
        if prefixArmed {
            prefixArmed = false
            return (keymap.action(forPrefixed: event), true)
        }

        if keymap.prefix.matches(event) {
            prefixArmed = true
            return (nil, true)
        }

        // A binding the profile writes without the prefix — `new_tab =
        // "alt+t"` — fires on its own, as it does in herdr. Nothing looked for
        // one, so those keys went to the pane as though they were unbound.
        //
        // One of these wins over a menu item carrying the same chord: the
        // keymap belongs to the user, and the menu is ours.
        if let direct = keymap.action(forDirect: event) {
            return (direct, true)
        }

        // Everything else is the pane's. ⌘ chords that are only in the menu
        // are dispatched by AppKit, and there is nothing to do for them here.
        return (nil, false)
    }
}
