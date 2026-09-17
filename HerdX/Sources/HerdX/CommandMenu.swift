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
        }
    }

    static let allByTag: [Int: Command] = {
        let all: [Command] = [
            .newTab, .closeTab, .nextTab, .previousTab, .splitRight, .splitDown,
            .focusLeft, .focusDown, .focusUp, .focusRight, .closePane, .zoomPane, .newWorkspace,
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
        ("Select Pane Left", Key(equivalent: "\u{1C}", modifiers: [.command, .option]), .focusLeft),
        ("Select Pane Right", Key(equivalent: "\u{1D}", modifiers: [.command, .option]), .focusRight),
        ("Select Pane Up", Key(equivalent: "\u{1E}", modifiers: [.command, .option]), .focusUp),
        ("Select Pane Down", Key(equivalent: "\u{1F}", modifiers: [.command, .option]), .focusDown),
        ("", Key(equivalent: "", modifiers: []), .newTab),
        ("Next Tab", Key(equivalent: "]", modifiers: [.command, .shift]), .nextTab),
        ("Previous Tab", Key(equivalent: "[", modifiers: [.command, .shift]), .previousTab),
        ("", Key(equivalent: "", modifiers: []), .newTab),
        ("New Workspace", Key(equivalent: "n", modifiers: [.command, .shift]), .newWorkspace),
    ]
}
