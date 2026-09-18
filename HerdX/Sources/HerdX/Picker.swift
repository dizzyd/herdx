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

    private var window: NSWindow?
    private let search = NSSearchField()
    private let table = NSTableView()
    private var all: [Item] = []
    private var shown: [Item] = []

    func show(over parent: NSWindow, title: String, items: [Item]) {
        guard window == nil else { return }
        all = items
        shown = items

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
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }

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

        let sheet = PickerSheet(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = title
        sheet.contentView = content
        sheet.onChoose = { [weak self] in self?.chooseSelected() }
        window = sheet

        parent.beginSheet(sheet) { [weak self] _ in self?.window = nil }
        // The search field takes the keys, so typing filters straight away and
        // the arrows still reach the list.
        sheet.makeFirstResponder(search)
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
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc private func chooseSelected() {
        let row = table.selectedRow
        guard shown.indices.contains(row) else { return }
        let item = shown[row]
        close()
        item.choose()
    }

    private func close() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
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
    }
}

/// A sheet that escape closes and return commits.
private final class PickerSheet: NSWindow {
    var onChoose: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        sheetParent?.endSheet(self)
    }
}
