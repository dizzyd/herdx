import AppKit

extension Command {
    struct Key {
        var equivalent: String
        var modifiers: NSEvent.ModifierFlags

        /// An item a Mac menu cannot spell: its keystroke is a prefix chord.
        static let unbound = Key(equivalent: "", modifiers: [])
    }

    /// A row of one of the menu-bar menus.
    ///
    /// Separators were spelled as an item with an empty title carrying a
    /// command nobody would ever run, which every reader of the table — and
    /// every loop over it — had to know to skip.
    enum Row {
        case separator
        case item(String, Key, Command)
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
        case .paneList: return 36
        case .paneProcessInfo: return 37
        case .layoutExport: return 38
        case .hibernateWorkspace: return 39
        case .createWorkspace: return 40
        case .layoutApply: return 41
        case .paneSendText: return 42
        case .paneGet: return 44
        case .zoomPaneWithID: return 43
        }
    }

    static let allByTag: [Int: Command] = {
        let all: [Command] = [
            .newTab, .closeTab, .nextTab, .previousTab, .splitRight, .splitDown,
            .focusLeft, .focusDown, .focusUp, .focusRight, .closePane, .zoomPane, .newWorkspace,
            .newLocalWorkspace, .hibernateWorkspace, .copyMode, .toggleSidebar, .help,
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.tag, $0) })
    }()

    /// ⌘ chords, mirroring what a Mac user expects, alongside the `ctrl+b`
    /// prefix bindings handled in `ChordResolver`.
    ///
    /// Split by the menu each row belongs in, because where an item lives is
    /// half of whether anyone finds it: tabs and panes are made in Shell, the
    /// window's own contents are shown and hidden in View, and moving between
    /// what is already open is in Window, which is where every other Mac app
    /// keeps "next tab".
    static let shellRows: [Row] = [
        .item("New Tab", Key(equivalent: "t", modifiers: .command), .newTab),
        .item("Close Tab", Key(equivalent: "w", modifiers: .command), .closeTab),
        .separator,
        .item("Split Right", Key(equivalent: "d", modifiers: .command), .splitRight),
        .item("Split Down", Key(equivalent: "d", modifiers: [.command, .shift]), .splitDown),
        .item("Close Pane", Key(equivalent: "w", modifiers: [.command, .shift]), .closePane),
        .separator,
        .item("New Workspace", Key(equivalent: "n", modifiers: [.command, .shift]), .newWorkspace),
        // No key equivalent: this one's keystroke is a prefix chord, which a
        // Mac menu has no way to spell. ⇧⌘N is spent on the item above, and
        // giving two items the same equivalent hands it to whichever AppKit
        // finds first — which is how copy mode once became unreachable.
        .item("New Local Workspace", .unbound, .newLocalWorkspace),
        // Also without an equivalent: its keystroke is a prefix chord, and a ⌘
        // shortcut for something that ends processes is too easy to hit while
        // reaching for ⌘H, which macOS uses to hide the app.
        .item("Hibernate Workspace", .unbound, .hibernateWorkspace),
    ]

    /// Copy mode sits under Edit because that is what it is for — selecting
    /// text out of the scrollback — and it is next to Find, which enters it
    /// already searching.
    static let editRows: [Row] = [
        // Not shift-command-bracket: that is Previous Tab, and AppKit gives a
        // duplicate equivalent to whichever item it finds first, so copy mode
        // was unreachable from the menu.
        .item("Copy Mode", Key(equivalent: "c", modifiers: [.command, .option]), .copyMode)
    ]

    /// Two tables rather than one, because the View menu interleaves them with
    /// items that are HerdX's own rather than herdr's — sorting the sidebar,
    /// and the theme picker.
    static let sidebarRows: [Row] = [
        // Titled for what it does next, and retitled by `validateMenuItem`
        // when the sidebar is already collapsed. ⌃⌘S is what the rest of the
        // Mac uses for a sidebar.
        .item("Hide Sidebar", Key(equivalent: "s", modifiers: [.command, .control]), .toggleSidebar)
    ]

    static let paneViewRows: [Row] = [
        .item("Zoom Pane", Key(equivalent: "\r", modifiers: [.command, .shift]), .zoomPane)
    ]

    /// Moving between what is open, which on a Mac lives in the Window menu
    /// alongside Minimize and the list of windows.
    static let windowRows: [Row] = [
        .item("Next Tab", Key(equivalent: "]", modifiers: [.command, .shift]), .nextTab),
        .item("Previous Tab", Key(equivalent: "[", modifiers: [.command, .shift]), .previousTab),
        .separator,
        // The arrows are the function-key codepoints AppKit matches menu key
        // equivalents against. The ASCII cursor-control characters that were
        // here instead are what a terminal sends, not what a menu compares, so
        // these four items could never fire.
        .item("Select Pane Left", Key(equivalent: "\u{F702}", modifiers: [.command, .option]), .focusLeft),
        .item("Select Pane Right", Key(equivalent: "\u{F703}", modifiers: [.command, .option]), .focusRight),
        .item("Select Pane Up", Key(equivalent: "\u{F700}", modifiers: [.command, .option]), .focusUp),
        .item("Select Pane Down", Key(equivalent: "\u{F701}", modifiers: [.command, .option]), .focusDown),
    ]

    static let helpRows: [Row] = [
        // Shift-command-slash is what a Mac calls Help.
        .item("Keyboard Shortcuts", Key(equivalent: "/", modifiers: [.command, .shift]), .help)
    ]

    /// Every herdr command the menu bar carries, in the order the bar carries
    /// them. The help sheet's menu column reads this, and so do the checks
    /// that no item is unreachable.
    static let menuLayout: [(String, Key, Command)] = {
        (shellRows + editRows + sidebarRows + paneViewRows + windowRows + helpRows)
            .compactMap { row in
                guard case .item(let title, let key, let command) = row else { return nil }
                return (title, key, command)
            }
    }()
}
