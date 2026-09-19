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
    /// A line parser rather than a TOML library, because the shape is narrow:
    /// `name = "value"` under `[keys]`, where the value is one spelling or an
    /// array of them. Two things about that shape were being missed, and both
    /// came from assuming it was narrower still.
    ///
    /// The server can write tables beside `[keys]` — `[keys.indexed]`,
    /// `[[keys.command]]` — whose keys are not action names, so which table a
    /// line is under has to be tracked rather than ignored.
    ///
    /// And `toml::to_string_pretty` writes an array over several lines, so an
    /// action bound to more than one chord arrives as `next_tab = [` followed
    /// by its spellings. Read a line at a time, that first line says the
    /// binding is the `[` key.
    /// Parses a profile without adding anything to it, so the additions
    /// themselves do not recurse through `adopt`.
    private init?(bare profile: String) {
        self.init(profile: profile, adoptingAdditions: false)
    }

    init?(profile: String) {
        self.init(profile: profile, adoptingAdditions: true)
    }

    private init?(profile: String, adoptingAdditions: Bool) {
        var found: [(Action, Binding)] = []
        var prefixSpec: Binding?

        // True until a table header says otherwise, so the profiles written
        // here — which carry no header at all — parse the same way.
        var readingKeys = true
        let lines = profile.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[[") || (line.hasPrefix("[") && line.hasSuffix("]")
                && !line.contains("="))
            {
                readingKeys = line == "[keys]"
                continue
            }
            guard readingKeys else { continue }

            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }

            var raw = parts[1]
            // An array runs over as many lines as it has entries, so it has to
            // be gathered before any of it can be read as a binding.
            if raw.hasPrefix("[") {
                while !raw.hasSuffix("]"), index < lines.count {
                    raw += lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                }
            }
            let specs = Self.spellings(in: raw)
            guard !specs.isEmpty else { continue }

            if parts[0] == "prefix" {
                // Always one string upstream; if that ever changes, the first
                // is the one the server says it is using.
                prefixSpec = specs.compactMap(Self.parse).first
                continue
            }
            guard let action = Action(rawValue: parts[0]) else { continue }
            // Every spelling is a binding of its own. An action bound to two
            // chords is two ways to reach it, not a choice between them.
            found.append(contentsOf: specs.compactMap(Self.parse).map { (action, $0) })
        }

        guard !found.isEmpty else { return nil }
        if let prefixSpec { prefix = prefixSpec }
        bindings = found
        if adoptingAdditions { adopt(Self.additions) }
    }

    /// Adds bindings of our own wherever herdr has left the key free.
    ///
    /// Written as a profile and run through the same parser, so there is one
    /// way a binding comes to exist. A key herdr already uses is left alone:
    /// these are additions, and an addition that overrode the user's own
    /// keymap would be the guessing this class exists to stop.
    private mutating func adopt(_ profile: String) {
        guard let extra = Keymap(bare: profile) else { return }
        for candidate in extra.bindings {
            let taken = bindings.contains {
                $0.binding.usesPrefix == candidate.binding.usesPrefix
                    && $0.binding.key == candidate.binding.key
                    && $0.binding.shift == candidate.binding.shift
                    && $0.binding.control == candidate.binding.control
                    && $0.binding.option == candidate.binding.option
                    && $0.binding.command == candidate.binding.command
            }
            guard !taken else { continue }
            bindings.append(candidate)
        }
    }

    /// The spellings one value holds: a single one, or an array of them.
    ///
    /// The brackets are only an array when they wrap the whole value —
    /// `copy_mode = "prefix+["` is one spelling that happens to end in one.
    private static func spellings(in raw: String) -> [String] {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else {
            let single = unquoted(raw)
            return single.isEmpty ? [] : [single]
        }
        return raw.dropFirst().dropLast()
            .split(separator: ",")
            .map { unquoted(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func unquoted(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
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
        Self.action(for: event, among: bindings.filter(\.binding.usesPrefix))
    }

    /// The action a keystroke carries out on its own.
    ///
    /// A profile is free to write a binding without the prefix —
    /// `new_tab = "alt+t"` — and herdr honours it. Nothing here looked for
    /// one, so those keys fell through to the pane as though unbound.
    func action(forDirect event: NSEvent) -> Action? {
        Self.action(for: event, among: bindings.filter { !$0.binding.usesPrefix })
    }

    private static func action(
        for event: NSEvent, among candidates: [(action: Action, binding: Binding)]
    ) -> Action? {
        if let exact = candidates.first(where: { $0.binding.matches(event) }) {
            return exact.action
        }
        return candidates.first { $0.binding.matches(event, ignoringShift: true) }?.action
    }

    /// How the prefix itself reads, for the help and the armed indicator.
    var prefixLabel: String {
        (prefix.control ? "⌃" : "") + (prefix.option ? "⌥" : "")
            + (prefix.shift ? "⇧" : "") + (prefix.command ? "⌘" : "")
            + prefix.key.label.uppercased()
    }
}

extension Keymap {
    /// Bindings HerdX adds where herdr leaves the key unbound.
    ///
    /// The arrows do what hjkl already does. herdr's own keymap is built for
    /// hands that stay on the home row; a Mac app is also used by people who
    /// reach for the arrow keys, and there is no reason both cannot work.
    static let additions = """
        focus_pane_left = "prefix+left"
        focus_pane_down = "prefix+down"
        focus_pane_up = "prefix+up"
        focus_pane_right = "prefix+right"
        """

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
