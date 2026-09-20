import AppKit

extension Command {
    struct Key {
        var equivalent: String
        var modifiers: NSEvent.ModifierFlags
    }

    var tag: Int {
        switch self {
        case .newTab: return 1
        case .closeTab: return 2
        case .nextTab: return 3
        case .previousTab: return 4
        case .splitRight: return 5
        case .splitDown: return 6
        case .focusLeft: return 7
        case .focusDown: return 8
        case .focusUp: return 9
        case .focusRight: return 10
        case .closePane: return 11
        case .zoomPane: return 12
        case .newWorkspace: return 13
        case .focusPane: return 14
        case .focusTab: return 15
        case .focusWorkspace: return 16
        case .copyMode: return 17
        case .closeTabWithID: return 18
        case .help: return 19
        case .settings: return 20
        case .detach: return 21
        case .toggleSidebar: return 22
        case .reloadConfig: return 23
        case .closeWorkspace: return 24
        case .swapLeft: return 25
        case .swapDown: return 26
        case .swapUp: return 27
        case .swapRight: return 28
        case .editScrollback: return 29
        case .renameTab: return 30
        case .renamePane: return 31
        case .renameWorkspace: return 32
        case .resizePane: return 33
        case .closePaneWithID: return 34
        case .newLocalWorkspace: return 35
        }
    }

    static let allByTag: [Int: Command] = {
        let all: [Command] = [
            .newTab, .closeTab, .nextTab, .previousTab, .splitRight, .splitDown,
            .focusLeft, .focusDown, .focusUp, .focusRight, .closePane, .zoomPane, .newWorkspace,
            .newLocalWorkspace, .copyMode, .help,
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.tag, $0) })
    }()

    /// ⌘ chords, mirroring what a Mac user expects, alongside the `ctrl+b`
    /// prefix bindings handled in `ChordResolver`.
    static let menuLayout: [(String, Key, Command)] = [
        ("New Tab", Key(equivalent: "t", modifiers: .command), .newTab),
        ("Close Tab", Key(equivalent: "w", modifiers: .command), .closeTab),
        ("", Key(equivalent: "", modifiers: []), .newTab),
        ("Split Right", Key(equivalent: "d", modifiers: .command), .splitRight),
        ("Split Down", Key(equivalent: "d", modifiers: [.command, .shift]), .splitDown),
        ("Close Pane", Key(equivalent: "w", modifiers: [.command, .shift]), .closePane),
        ("Zoom Pane", Key(equivalent: "\r", modifiers: [.command, .shift]), .zoomPane),
        ("", Key(equivalent: "", modifiers: []), .newTab),
        // The arrows are the function-key codepoints AppKit matches menu key
        // equivalents against. The ASCII cursor-control characters that were
        // here instead are what a terminal sends, not what a menu compares, so
        // these four items could never fire.
        ("Select Pane Left", Key(equivalent: "\u{F702}", modifiers: [.command, .option]), .focusLeft),
        ("Select Pane Right", Key(equivalent: "\u{F703}", modifiers: [.command, .option]), .focusRight),
        ("Select Pane Up", Key(equivalent: "\u{F700}", modifiers: [.command, .option]), .focusUp),
        ("Select Pane Down", Key(equivalent: "\u{F701}", modifiers: [.command, .option]), .focusDown),
        ("", Key(equivalent: "", modifiers: []), .newTab),
        ("Next Tab", Key(equivalent: "]", modifiers: [.command, .shift]), .nextTab),
        ("Previous Tab", Key(equivalent: "[", modifiers: [.command, .shift]), .previousTab),
        ("", Key(equivalent: "", modifiers: []), .newTab),
        ("New Workspace", Key(equivalent: "n", modifiers: [.command, .shift]), .newWorkspace),
        // No key equivalent: this one's keystroke is a prefix chord, which a
        // Mac menu has no way to spell. ⇧⌘N is spent on the item above, and
        // giving two items the same equivalent hands it to whichever AppKit
        // finds first — which is how copy mode once became unreachable.
        ("New Local Workspace", Key(equivalent: "", modifiers: []), .newLocalWorkspace),
        ("", Key(equivalent: "", modifiers: []), .newTab),
        // Not shift-command-bracket: that is Previous Tab, and AppKit gives a
        // duplicate equivalent to whichever item it finds first, so copy mode
        // was unreachable from the menu.
        ("Copy Mode", Key(equivalent: "c", modifiers: [.command, .option]), .copyMode),
        ("", Key(equivalent: "", modifiers: []), .newTab),
        // Shift-command-slash is what a Mac calls Help.
        ("Keyboard Shortcuts", Key(equivalent: "/", modifiers: [.command, .shift]), .help),
    ]
}
