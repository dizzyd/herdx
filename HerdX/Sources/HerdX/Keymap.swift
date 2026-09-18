import AppKit

/// The keymap herdr publishes, rather than one we invented.
///
/// Every snapshot carries `server_keybindings_toml`: the user's own bindings,
/// normalised by the server, prefix included. Guessing at them meant guessing
/// wrong — a hand-written table had fifteen of the fifty-eight, and no way to
/// know when it drifted. Reading theirs also means a custom prefix or a
/// rebound key works here without HerdX knowing anything about it.
struct Keymap {
    /// What the server calls each action, in the order the help should read.
    ///
    /// Names are herdr's, so they line up with the profile without a
    /// translation table in between.
    enum Action: String, CaseIterable {
        case help, settings, detach, reloadConfig = "reload_config"
        case newWorkspace = "new_workspace", closeWorkspace = "close_workspace"
        case renameWorkspace = "rename_workspace", workspacePicker = "workspace_picker"
        case previousWorkspace = "previous_workspace", nextWorkspace = "next_workspace"
        case switchWorkspace = "switch_workspace"
        case goto_ = "goto"
        case newTab = "new_tab", closeTab = "close_tab", renameTab = "rename_tab"
        case previousTab = "previous_tab", nextTab = "next_tab"
        case moveTabPrevious = "move_tab_previous", moveTabNext = "move_tab_next"
        case switchTab = "switch_tab"
        case splitVertical = "split_vertical", splitHorizontal = "split_horizontal"
        case closePane = "close_pane", zoom, renamePane = "rename_pane"
        case focusPaneLeft = "focus_pane_left", focusPaneDown = "focus_pane_down"
        case focusPaneUp = "focus_pane_up", focusPaneRight = "focus_pane_right"
        case swapPaneLeft = "swap_pane_left", swapPaneDown = "swap_pane_down"
        case swapPaneUp = "swap_pane_up", swapPaneRight = "swap_pane_right"
        case cyclePaneNext = "cycle_pane_next", cyclePanePrevious = "cycle_pane_previous"
        case lastPane = "last_pane"
        case copyMode = "copy_mode", editScrollback = "edit_scrollback"
        case resizeMode = "resize_mode"
        case resizePaneLeft = "resize_pane_left", resizePaneDown = "resize_pane_down"
        case resizePaneUp = "resize_pane_up", resizePaneRight = "resize_pane_right"
        case toggleSidebar = "toggle_sidebar"
        case newWorktree = "new_worktree", openWorktree = "open_worktree"
        case removeWorktree = "remove_worktree"
        case openNotificationTarget = "open_notification_target"
        case previousAgent = "previous_agent", nextAgent = "next_agent"
        case focusAgent = "focus_agent"

        /// How the action reads in the help.
        var title: String {
            if self == .goto_ { return "Go to" }
            let words = rawValue.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// One key, as the profile spells it.
    enum Key: Equatable {
        case character(String)
        case tab
        case arrow(UInt16)
        /// `1..9` — nine bindings written as one, selecting by position.
        case digits

        /// Whether an event is this key. Characters compare against the
        /// unmodified key so a binding means the same on any layout.
        func matches(_ event: NSEvent) -> Bool {
            switch self {
            case .character(let want):
                return event.charactersIgnoringModifiers?.lowercased() == want
            case .tab:
                return event.keyCode == 48
            case .arrow(let code):
                return event.keyCode == code
            case .digits:
                guard let typed = event.charactersIgnoringModifiers, typed.count == 1,
                    let digit = Int(typed)
                else { return false }
                return (1...9).contains(digit)
            }
        }

        var label: String {
            switch self {
            case .character(let key): return key
            // Spelled out: ⇥ is a handful of hairlines at this size and reads
            // as a smudge next to the letters it is listed among.
            case .tab: return "tab"
            case .arrow(let code):
                return ["↑", "↓", "←", "→"][[126, 125, 123, 124].firstIndex(of: Int(code)) ?? 0]
            case .digits: return "1…9"
            }
        }
    }

    struct Binding: Equatable {
        var usesPrefix: Bool
        var shift: Bool
        var control: Bool
        var option: Bool
        var command: Bool
        var key: Key

        /// How it reads in the help, without the prefix, which is stated once.
        var label: String {
            let modifiers = (control ? "⌃" : "") + (option ? "⌥" : "") + (command ? "⌘" : "")
            // A shifted letter is written as the capital. ⇧X is how a menu
            // spells it, but in a column of single keys the capital says the
            // same thing in one glyph, and it is the key you actually press.
            if case .character(let key) = key, shift, key.count == 1,
                key.first?.isLetter == true
            {
                return modifiers + key.uppercased()
            }
            return modifiers + (shift ? "⇧" : "") + key.label
        }

        /// Whether the event is this chord.
        ///
        /// Every modifier is compared, the ones the binding does not want
        /// included: a chord is not "⌃B or anything containing it", or ⌘⌃B
        /// would arm the prefix on its way to a menu item.
        ///
        /// Shift is the exception, and only when `ignoringShift`. A profile
        /// writes `help = "prefix+?"` with no shift in it, because "?" already
        /// carries one — demanding shift be up there made help unreachable.
        /// A keystroke that would produce this binding, for self-checking.
        var probeCharacters: String {
            switch key {
            case .character(let key): return key
            case .tab: return "\t"
            case .arrow: return "\u{F700}"
            case .digits: return "1"
            }
        }

        var probeKeyCode: UInt16 {
            switch key {
            case .tab: return 48
            case .arrow(let code): return code
            default: return 0
            }
        }

        func matches(_ event: NSEvent, ignoringShift: Bool = false) -> Bool {
            let flags = event.modifierFlags
            let shiftMatches = ignoringShift || flags.contains(.shift) == shift
            return key.matches(event)
                && shiftMatches
                && flags.contains(.control) == control
                && flags.contains(.option) == option
                && flags.contains(.command) == command
        }
    }

    /// The chord that arms everything else.
    private(set) var prefix = Binding(
        usesPrefix: false, shift: false, control: true, option: false, command: false,
        key: .character("b"))
    private(set) var bindings: [(action: Action, binding: Binding)] = []

    /// Parses the profile the server sends.
    ///
    /// A line parser rather than a TOML library: the server writes this with
    /// `toml::to_string_pretty` over a flat struct of strings, so what arrives
    /// is always `name = "value"` under one table — never nested, never
    /// multi-line. Anything it does not recognise is skipped rather than
    /// guessed at.
    init?(profile: String) {
        var found: [(Action, Binding)] = []
        var prefixSpec: Binding?

        for line in profile.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !value.isEmpty else { continue }

            if parts[0] == "prefix" {
                prefixSpec = Self.parse(value)
                continue
            }
            guard let action = Action(rawValue: parts[0]), let binding = Self.parse(value) else {
                continue
            }
            found.append((action, binding))
        }

        guard !found.isEmpty else { return nil }
        if let prefixSpec { prefix = prefixSpec }
        bindings = found
    }

    /// `prefix+shift+h`, `ctrl+b`, `prefix+1..9`, `up`.
    private static func parse(_ spec: String) -> Binding? {
        var binding = Binding(
            usesPrefix: false, shift: false, control: false, option: false, command: false,
            key: .character(""))
        var key: Key?

        for token in spec.lowercased().split(separator: "+") {
            switch token {
            case "prefix": binding.usesPrefix = true
            case "shift": binding.shift = true
            case "ctrl", "control": binding.control = true
            case "alt", "option": binding.option = true
            case "cmd", "command", "super": binding.command = true
            case "tab": key = .tab
            case "up": key = .arrow(126)
            case "down": key = .arrow(125)
            case "left": key = .arrow(123)
            case "right": key = .arrow(124)
            case "minus": key = .character("-")
            case "1..9": key = .digits
            default:
                // Anything left is the key itself. A named key we do not know
                // is left unbound rather than mapped onto the wrong one.
                guard token.count == 1 else { return nil }
                key = .character(String(token))
            }
        }
        guard let key else { return nil }
        binding.key = key
        return binding
    }

    /// The action a key completes, once the prefix is armed.
    ///
    /// The action a key completes, once the prefix is armed.
    ///
    /// Exact first, then ignoring shift. Both passes are needed: `h` and
    /// `shift+h` are two different bindings and must not be confused, while
    /// `?` is one binding that cannot be typed without a shift the profile
    /// never mentions. Trying exact first means the explicit binding always
    /// wins where there is one.
    func action(forPrefixed event: NSEvent) -> Action? {
        let prefixed = bindings.filter(\.binding.usesPrefix)
        if let exact = prefixed.first(where: { $0.binding.matches(event) }) {
            return exact.action
        }
        return prefixed.first { $0.binding.matches(event, ignoringShift: true) }?.action
    }

    /// How the prefix itself reads, for the help and the armed indicator.
    var prefixLabel: String {
        (prefix.control ? "⌃" : "") + (prefix.option ? "⌥" : "")
            + (prefix.shift ? "⇧" : "") + (prefix.command ? "⌘" : "")
            + prefix.key.label.uppercased()
    }
}

extension Keymap {
    /// herdr's defaults, used until a snapshot brings the user's own.
    ///
    /// Written as a profile rather than as a table so there is one parser and
    /// one shape of data, and so this stays comparable to what arrives.
    static let fallback: Keymap = Keymap(
        profile: """
            prefix = "ctrl+b"
            help = "prefix+?"
            settings = "prefix+s"
            new_workspace = "prefix+shift+n"
            rename_workspace = "prefix+shift+w"
            close_workspace = "prefix+shift+d"
            workspace_picker = "prefix+w"
            goto = "prefix+g"
            detach = "prefix+q"
            reload_config = "prefix+shift+r"
            open_notification_target = "prefix+o"
            new_tab = "prefix+c"
            rename_tab = "prefix+shift+t"
            previous_tab = "prefix+p"
            next_tab = "prefix+n"
            switch_tab = "prefix+1..9"
            close_tab = "prefix+shift+x"
            rename_pane = "prefix+shift+p"
            edit_scrollback = "prefix+e"
            copy_mode = "prefix+["
            focus_pane_left = "prefix+h"
            focus_pane_down = "prefix+j"
            focus_pane_up = "prefix+k"
            focus_pane_right = "prefix+l"
            swap_pane_left = "prefix+shift+h"
            swap_pane_down = "prefix+shift+j"
            swap_pane_up = "prefix+shift+k"
            swap_pane_right = "prefix+shift+l"
            cycle_pane_next = "prefix+tab"
            cycle_pane_previous = "prefix+shift+tab"
            split_vertical = "prefix+v"
            split_horizontal = "prefix+minus"
            close_pane = "prefix+x"
            zoom = "prefix+z"
            resize_mode = "prefix+r"
            toggle_sidebar = "prefix+b"
            """)!
}
