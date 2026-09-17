import AppKit

/// HerdX: a native macOS client for herdr.
///
/// The server owns terminal emulation and sends composed cell grids plus a
/// structured description of the workspace tree, so this app is a renderer and
/// an input source, not a terminal emulator.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var gridView: TerminalGridView!
    private var sidebar: SidebarView!
    private var session: HerdrSession?
    private let chords = ChordResolver()
    private var timer: Timer?
    private let events = EventPresenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        gridView = TerminalGridView(pointSize: 13)

        let cols = 120
        let rows = 34
        let cell = gridView.cellSize

        sidebar = SidebarView()
        sidebar.onSelect = { [weak self] command in
            guard let self, let session = self.session else { return }
            self.invoke(command, session: session)
            self.window.makeFirstResponder(self.gridView)
        }

        window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: CGFloat(cols) * cell.width + SidebarView.width,
                height: CGFloat(rows) * cell.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "HerdX"
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.center()

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(gridView)
        // The terminal takes all the slack; the sidebar holds its width.
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 1)
        window.contentView = split

        do {
            let session = try HerdrSession(
                cols: cols, rows: rows,
                cellWidth: Int(cell.width), cellHeight: Int(cell.height))
            self.session = session
            gridView.session = session
            gridView.onReadSelection = { [weak self] request in
                guard let self, let snapshot = session.lastSnapshot else { return }
                session.request(request, bootID: snapshot.bootID)
                _ = self
            }
            gridView.onFocusPane = { [weak self] paneID in
                guard let self else { return }
                self.invoke(.focusPane(paneID), session: session)
            }
            gridView.onResize = { [weak self] cols, rows in
                guard let self, let cell = self.gridView?.cellSize else { return }
                session.resize(
                    cols: cols, rows: rows,
                    cellWidth: Int(cell.width), cellHeight: Int(cell.height))
            }
        } catch {
            presentFatal(error)
            return
        }

        buildMenu()
        installKeyMonitor()
        events.requestAuthorization()

        if capturePath == nil {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(gridView)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Lay the window out off-screen so the view hierarchy has real
            // frames to render into, without ever appearing on a display.
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        installCaptureHookIfRequested()

        // A display-linked repaint would be tighter, but the core only bumps a
        // revision when a surface actually lands, so a cheap tick is enough.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard let session else { return }
        if session.pollSnapshot(), let snapshot = session.lastSnapshot {
            sidebar.update(with: snapshot)
            gridView.focusedPaneFromSnapshot = snapshot.focusedPaneID
            if let focused = snapshot.workspaces.first(where: \.focused) {
                window.title = "HerdX — \(focused.label)"
                window.subtitle = focused.branch ?? ""
            }
        }
        for event in session.drainEvents() {
            events.present(event, window: window)
        }
        gridView.refreshIfNeeded()
        if let error = session.takeError() {
            NSLog("herdr: %@", error)
        }
        if !session.isConnected {
            timer?.invalidate()
            window.subtitle = "disconnected"
        }
    }

    /// The prefix chord has to be seen before the view turns it into pane input.
    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let session = self.session else { return event }
            let (command, consumed) = self.chords.resolve(event)
            if let command { self.invoke(command, session: session) }
            return consumed ? nil : event
        }
    }

    private func invoke(_ command: Command, session: HerdrSession) {
        guard let snapshot = session.lastSnapshot,
            let json = command.requestJSON(id: UUID().uuidString)
        else { return }
        session.request(json, bootID: snapshot.bootID)
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let session, let command = Command.allByTag[sender.tag] else { return }
        invoke(command, session: session)
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit HerdX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // Routed to the first responder, so the grid view handles them.
        editMenu.addItem(
            withTitle: "Copy", action: #selector(TerminalGridView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(TerminalGridView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let shellItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        for (title, key, command) in Command.menuLayout {
            if title.isEmpty {
                shellMenu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(
                title: title, action: #selector(menuCommand(_:)), keyEquivalent: key.equivalent)
            item.keyEquivalentModifierMask = key.modifiers
            item.tag = command.tag
            item.target = self
            shellMenu.addItem(item)
        }
        shellItem.submenu = shellMenu
        main.addItem(shellItem)

        NSApp.mainMenu = main
    }

    /// Dev affordance: `HERDX_CAPTURE=/path.png` renders the window and exits.
    ///
    /// The window is never ordered on-screen and the app never activates, so
    /// this does not interrupt whatever you are doing. It also sidesteps
    /// `screencapture -R`, which picks the wrong display on multi-monitor setups.
    private var capturePath: String? {
        ProcessInfo.processInfo.environment["HERDX_CAPTURE"]
    }

    private func installCaptureHookIfRequested() {
        guard let path = capturePath else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
            guard let self, let view = self.window.contentView else { NSApp.terminate(nil); return }
            self.gridView.refreshIfNeeded()
            view.layoutSubtreeIfNeeded()
            self.gridView.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                NSApp.terminate(nil)
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
            }
        }
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not connect to herdr"
        alert.informativeText =
            """
            \(error.localizedDescription)

            HerdX attaches to a running herdr server. Start one with `herdr` in \
            a terminal, then reopen this app.
            """
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(
    ProcessInfo.processInfo.environment["HERDX_CAPTURE"] == nil ? .regular : .prohibited)
app.delegate = delegate
app.run()
