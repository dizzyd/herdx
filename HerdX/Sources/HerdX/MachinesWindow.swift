import AppKit

/// Manages the machines herdr attaches to.
///
/// It edits herdr's own catalog, the same file `herdr machine` writes, so a
/// machine added here shows up in the TUI and vice versa. There is no endpoint
/// method for any of this — the catalog is a client-side file, and the client
/// is us.
@MainActor
final class MachinesWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate
{
    /// Raised when the catalog changed, so the session can pick it up.
    private let onChange: () -> Void
    /// Raised to set herdr up on a machine that does not have it.
    private let onInstall: (String) -> Void

    private let table = NSTableView()
    private var machines: [Machines.Machine] = []
    private let editor = MachineEditor()
    private let removeButton = NSButton()
    private let editButton = NSButton()

    private let installButton = NSButton()

    init(onChange: @escaping () -> Void, onInstall: @escaping (String) -> Void) {
        self.onChange = onChange
        self.onInstall = onInstall

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Machines"
        window.setFrameAutosaveName("MachinesWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)

        for (title, column) in [
            ("Name", "label"), ("SSH target", "target"), ("Session", "session"),
        ] {
            let item = NSTableColumn(identifier: .init(column))
            item.title = title
            item.width = column == "target" ? 220 : 130
            table.addTableColumn(item)
        }
        let on = NSTableColumn(identifier: .init("enabled"))
        on.title = "On"
        on.width = 34
        table.addTableColumn(on)

        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.target = self
        table.doubleAction = #selector(edit)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(title: "Add…", target: self, action: #selector(addMachine))
        add.bezelStyle = .rounded
        editButton.title = "Edit…"
        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(edit)
        installButton.title = "Install herdr…"
        installButton.bezelStyle = .rounded
        installButton.target = self
        installButton.action = #selector(install)
        removeButton.title = "Remove"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(remove)

        let note = NSTextField(
            labelWithString:
                "Machines are shared with herdr, and attach over ssh using your own keys.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let buttons = NSStackView(views: [
            note, NSView(), installButton, add, editButton, removeButton,
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        window.contentView = content
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reload() {
        machines = Machines.all()
        table.reloadData()
        updateButtons()
    }

    private func updateButtons() {
        let hasSelection = machines.indices.contains(table.selectedRow)
        editButton.isEnabled = hasSelection
        removeButton.isEnabled = hasSelection
        installButton.isEnabled = hasSelection
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { machines.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let machine = machines[row]
        guard let column = tableColumn?.identifier.rawValue else { return nil }

        if column == "enabled" {
            let box = NSButton(
                checkboxWithTitle: "", target: self, action: #selector(toggleEnabled))
            box.state = machine.enabled ? .on : .off
            box.tag = row
            return box
        }

        let text: String
        switch column {
        case "label": text = machine.label
        case "target": text = machine.target
        default: text = machine.session
        }
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        // A disabled machine is still listed, because it still has to be
        // editable; it just says plainly that it is not being attached to.
        field.textColor = machine.enabled ? .labelColor : .tertiaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSButton) {
        guard machines.indices.contains(sender.tag) else { return }
        let machine = machines[sender.tag]
        apply(
            Machines.save(
                id: machine.id, label: machine.label, target: machine.target,
                session: machine.session, enabled: sender.state == .on))
    }

    /// Opens the add sheet, for the capture affordance.
    func beginAdd() { addMachine() }

    @objc private func addMachine() {
        guard let window else { return }
        editor.ask(over: window, machine: nil) { [weak self] label, target, session in
            self?.apply(
                Machines.save(
                    id: nil, label: label, target: target, session: session, enabled: true))
        }
    }

    @objc private func edit() {
        guard let window, machines.indices.contains(table.selectedRow) else { return }
        let machine = machines[table.selectedRow]
        editor.ask(over: window, machine: machine) { [weak self] label, target, session in
            self?.apply(
                Machines.save(
                    id: machine.id, label: label, target: target, session: session,
                    enabled: machine.enabled))
        }
    }

    /// Sets herdr up on a machine, by running herdr's own installer.
    ///
    /// Not reimplemented here: herdr downloads the build matching the far
    /// side's platform — your Mac's binary cannot seed a Linux box — checks the
    /// version supports endpoint federation, and refuses to install at all
    /// unless a person at a terminal approves. Doing any of that ourselves
    /// would be duplicating careful work and discarding its one safeguard.
    @objc private func install() {
        guard let window, machines.indices.contains(table.selectedRow) else { return }
        let machine = machines[table.selectedRow]

        let alert = NSAlert()
        alert.messageText = "Install herdr on “\(machine.label)”?"
        alert.informativeText =
            "HerdX will open a terminal running:\n\n"
            + "    herdr --remote \(machine.target)\n\n"
            + "herdr downloads the build matching that machine and copies it to "
            + "~/.local/bin/herdr. It asks you to confirm in the terminal before "
            + "changing anything."
        alert.addButton(withTitle: "Open Terminal")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.window?.close()
                self?.onInstall(machine.target)
            }
        }
    }

    @objc private func remove() {
        guard let window, machines.indices.contains(table.selectedRow) else { return }
        let machine = machines[table.selectedRow]

        // Asked before doing, because the session running on that machine
        // carries on without it and there is no undo here.
        let alert = NSAlert()
        alert.messageText = "Remove “\(machine.label)”?"
        alert.informativeText =
            "HerdX will stop attaching to \(machine.target). "
            + "Nothing on the machine itself is changed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                Machines.remove(id: machine.id)
                self?.reload()
                self?.onChange()
            }
        }
    }

    private func apply(_ result: Result<String, Machines.Refusal>) {
        switch result {
        case .success:
            reload()
            onChange()
        case .failure(let refusal):
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = "That machine could not be saved"
            alert.informativeText = refusal.reason
            alert.beginSheetModal(for: window) { _ in }
            reload()
        }
    }
}

/// The add-and-edit sheet: a name, where to ssh, and which session.
@MainActor
private final class MachineEditor {
    private var window: NSWindow?
    private let label = NSTextField()
    private let target = NSTextField()
    private let session = NSTextField()
    private var commit: ((String, String, String) -> Void)?

    func ask(
        over parent: NSWindow, machine: Machines.Machine?,
        commit: @escaping (String, String, String) -> Void
    ) {
        guard window == nil else { return }
        self.commit = commit

        label.stringValue = machine?.label ?? ""
        label.placeholderString = "Alemetry"
        target.stringValue = machine?.target ?? ""
        target.placeholderString = "user@host"
        session.stringValue = machine?.session ?? "default"
        session.placeholderString = "default"

        for field in [label, target, session] {
            field.font = .systemFont(ofSize: 13)
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(dismiss))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(accept))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let grid = NSGridView(views: [
            [Self.caption("Name:"), label],
            [Self.caption("SSH target:"), target],
            [Self.caption("Session:"), session],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: grid.widthAnchor),
        ])

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = machine == nil ? "Add Machine" : "Edit Machine"
        sheet.contentView = content
        content.layoutSubtreeIfNeeded()
        sheet.setContentSize(content.fittingSize)
        window = sheet

        parent.beginSheet(sheet) { [weak self] _ in self?.window = nil }
        sheet.makeFirstResponder(label)
    }

    private static func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    @objc private func accept() {
        let values = (label.stringValue, target.stringValue, session.stringValue)
        close()
        commit?(values.0, values.1, values.2)
    }

    @objc private func dismiss() { close() }

    private func close() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
