import AppKit

/// A searchable list, for herdr's workspace picker and session navigator.
///
/// One component for both: they differ only in what goes in the list, and a
/// navigator that behaves differently from the picker beside it would be two
/// things to learn instead of one.
@MainActor
final class Picker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        let title: String
        let detail: String
        let choose: () -> Void
    }

    /// How the list is put on screen.
    enum Presentation {
        /// Drops out of the title bar, modal to the window. The shape for a
        /// list you read off the list.
        case sheet
        /// Floats over the window instead. macOS blurs the window behind a
        /// sheet, and a palette can only be judged against the terminal it is
        /// about to colour — behind a sheet there is nothing to judge.
        case floating
    }

    /// Raised as the highlight moves, for a list whose entries are worth
    /// seeing before they are chosen.
    private var onHighlight: ((Item) -> Void)?
    /// Raised when the list is closed without choosing, so a preview can be
    /// put back.
    private var onCancel: (() -> Void)?
    private var chose = false

    private var window: NSWindow?
    /// The window the list is in, for the capture probe: headlessly there is
    /// nothing else to photograph it through.
    var presented: NSWindow? { window }
    /// The list and its filter field, for the capture probe and for the tests
    /// that ask what one presentation left behind for the next.
    var list: NSTableView { table }
    var filterField: NSSearchField { search }
    private let search = NSSearchField()
    private let table = NSTableView()
    private var all: [Item] = []
    private var shown: [Item] = []
    /// The row the highlight was last raised for.
    ///
    /// A selection change is reported twice when the code that moved the
    /// highlight also announces it, and a theme preview repaints the window.
    private var highlighted: Int?

    override init() {
        super.init()
        configure()
    }

    /// Builds the list and the filter field, once.
    ///
    /// Both outlive a presentation — only the window around them is rebuilt —
    /// so doing this in `show` added a column every time the list was opened.
    /// Two columns draw every row's content twice, and it got worse from there.
    private func configure() {
        search.placeholderString = "Filter"
        search.font = .systemFont(ofSize: 13)
        search.target = self
        search.action = #selector(filterChanged)
        search.delegate = self

        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 38
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(chooseSelected)
        table.style = .inset
    }

    func show(
        over parent: NSWindow, title: String, items: [Item],
        as presentation: Presentation = .sheet,
        onHighlight: ((Item) -> Void)? = nil, onCancel: (() -> Void)? = nil
    ) {
        guard window == nil else { return }
        all = items
        shown = items
        self.onHighlight = onHighlight
        self.onCancel = onCancel
        chose = false

        // Reused between presentations, so whatever the last one was left
        // holding — a filter, a highlight, the previous list — has to go.
        search.stringValue = ""
        highlighted = nil
        table.reloadData()
        if shown.isEmpty {
            table.deselectAll(nil)
        } else {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [search, scroll])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 320),
        ])

        let chooser = PickerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: presentation == .sheet ? [.titled] : [.titled, .closable],
            backing: .buffered, defer: false)
        chooser.title = title
        chooser.contentView = content
        chooser.onChoose = { [weak self] in self?.chooseSelected() }
        // `window` below is a strong reference, so ARC already owns this; a
        // window that also releases itself on close is released twice.
        chooser.isReleasedWhenClosed = false
        window = chooser

        switch presentation {
        case .sheet:
            parent.beginSheet(chooser) { [weak self] _ in self?.finish() }
        case .floating:
            // A child window so it travels with the window it is about and
            // stays above it, and a panel so taking the keys does not make the
            // window behind look switched off.
            chooser.isFloatingPanel = true
            chooser.hidesOnDeactivate = false
            chooser.becomesKeyOnlyIfNeeded = false
            // An ordinary Mac window, so it takes the light/dark appearance the
            // window was given rather than any of the chrome's colours.
            chooser.appearance = parent.appearance
            chooser.delegate = self
            parent.addChildWindow(chooser, ordered: .above)
            // Where the sheet would have come down, so it is the same place to
            // look — and everything below it is the theme, unblurred.
            chooser.setFrameTopLeftPoint(
                NSPoint(
                    x: parent.frame.midX - chooser.frame.width / 2,
                    y: parent.contentRect(forFrameRect: parent.frame).maxY))
            // Headlessly the window behind this one was never ordered in, and a
            // list on its own is exactly the window nobody asked to see. It
            // still lays out, so a capture can still photograph it.
            if parent.isVisible { chooser.makeKeyAndOrderFront(nil) }
        }
        highlightChanged()
        // The search field takes the keys, so typing filters straight away and
        // the arrows still reach the list.
        chooser.makeFirstResponder(search)
    }

    /// Runs once, however the list was closed.
    private func finish() {
        guard window != nil else { return }
        window = nil
        // Closed without choosing: whatever the highlight was showing is not
        // what anyone asked for.
        if !chose { onCancel?() }
        onHighlight = nil
        onCancel = nil
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let item = shown[row]
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    @objc private func filterChanged() {
        let query = search.stringValue.lowercased()
        shown =
            query.isEmpty
            ? all
            : all.filter {
                $0.title.lowercased().contains(query) || $0.detail.lowercased().contains(query)
            }
        table.reloadData()
        // Row 0 after filtering is a different item from row 0 before it, so
        // the highlight has moved even where the index has not.
        highlighted = nil
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        highlightChanged()
    }

    /// Clicking a row moves the highlight, and nothing else was telling anyone.
    ///
    /// Only the keyboard went through `move`, so a list whose entries are
    /// previewed as they are highlighted showed the keyboard's idea of where
    /// the highlight was — and double-clicking a row committed that instead of
    /// the row under the pointer.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as AnyObject === table else { return }
        highlightChanged()
    }

    @objc private func chooseSelected() {
        let row = table.selectedRow
        guard shown.indices.contains(row) else { return }
        let item = shown[row]
        chose = true
        close()
        // After closing, so what a chooser puts on screen is not undone by the
        // cancellation path — and explicitly, rather than trusting whatever a
        // preview last left behind.
        item.choose()
    }

    private func highlightChanged() {
        guard shown.indices.contains(table.selectedRow) else {
            highlighted = nil
            return
        }
        guard table.selectedRow != highlighted else { return }
        highlighted = table.selectedRow
        onHighlight?(shown[table.selectedRow])
    }

    private func close() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }
}

extension Picker: NSSearchFieldDelegate {
    /// Arrows move the list while the field keeps the keys, and return takes
    /// whatever is highlighted — the shape every quick-open panel has.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            chooseSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    private func move(by step: Int) {
        guard !shown.isEmpty else { return }
        let next = min(max(table.selectedRow + step, 0), shown.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
        highlightChanged()
    }
}

extension Picker: NSWindowDelegate {
    /// The floating form has a close button and can be closed by the window
    /// list, neither of which goes through `close()`.
    func windowWillClose(_ notification: Notification) {
        guard let window, notification.object as AnyObject === window else { return }
        if let parent = window.parent {
            parent.removeChildWindow(window)
            // Handing the keys back explicitly: a sheet returns them to its
            // parent, a closing child window leaves whichever window AppKit
            // picks with them, and the terminal not taking keys after a theme
            // was chosen reads as the keyboard having died.
            DispatchQueue.main.async { parent.makeKey() }
        }
        finish()
    }
}

/// A list window that escape closes and return commits.
///
/// An `NSPanel` in both forms: as a sheet it behaves as one either way, and as
/// a floating chooser it has to take the keys without the window underneath
/// going grey.
private final class PickerWindow: NSPanel {
    var onChoose: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let parent = sheetParent {
            parent.endSheet(self)
        } else {
            close()
        }
    }
}
