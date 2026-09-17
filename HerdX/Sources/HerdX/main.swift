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
    private var reconnecting = false
    private var lastConnectError: String?
    private var preferences = Preferences.current
    private var preferencesWindow: PreferencesWindowController?
    private var appearanceObserver: NSKeyValueObservation?
    private let copyModeStatus = CopyModeStatusView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = Preferences.current
        gridView = TerminalGridView(font: preferences.font)

        let cell = gridView.cellSize
        let cols = 120
        let rows = 34

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

        copyModeStatus.translatesAutoresizingMaskIntoConstraints = false

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(gridView)
        // The terminal takes all the slack; the sidebar holds its width.
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 1)
        // The status strip floats over the terminal rather than taking a row
        // from it; copy mode should not reflow the grid.
        let container = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(split)
        container.addSubview(copyModeStatus)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.topAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            copyModeStatus.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: SidebarView.width + 12),
            copyModeStatus.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -12),
        ])
        window.contentView = container

        if !connect() {
            // A server that is not running yet is not fatal: herdr sessions
            // outlive their clients, so wait for one instead of giving up.
            window.subtitle = "waiting for herdr…"
        }

        buildMenu()
        installKeyMonitor()
        events.requestAuthorization()
        applyTheme()

        // Follow the system when the user has not pinned an appearance.
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyTheme() }
            }
        }

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

    private var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Applies the current theme to the views and tells the server about it.
    ///
    /// The server resolves `Reset` colours and its own chrome against the
    /// host's palette, so publishing ours keeps server-composed output matching
    /// what the app draws.
    private func applyTheme() {
        let theme = preferences.theme(matching: systemIsDark)
        gridView.theme = theme
        gridView.needsDisplay = true

        switch preferences.appearance {
        case .system: window.appearance = nil
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        case .light: window.appearance = NSAppearance(named: .aqua)
        }
        sidebar.apply(theme: theme)
        copyModeStatus.apply(theme: theme)
        publish(theme: theme)
    }

    private func publish(theme: Theme) {
        guard let session else { return }
        let background = theme.rgbBytes(of: theme.background)
        let foreground = theme.rgbBytes(of: theme.foreground)
        session.setDefaultColor(foreground: false, rgb: background)
        session.setDefaultColor(foreground: true, rgb: foreground)
        session.setPalette(theme.paletteBytes)
        session.setAppearance(dark: theme.background.isDarkish)
    }

    @objc private func showPreferences(_ sender: Any?) {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController { [weak self] updated in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.preferences = updated
                    self.gridView.apply(font: updated.font)
                    self.applyTheme()
                }
            }
        }
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens a session and hands it to the views. Returns false if no server.
    @discardableResult
    private func connect() -> Bool {
        let size = gridView.gridSize
        let cell = gridView.cellSize
        let session: HerdrSession
        do {
            session = try HerdrSession(
                cols: size.cols, rows: size.rows,
                cellWidth: Int(cell.width), cellHeight: Int(cell.height))
        } catch {
            lastConnectError = error.localizedDescription
            return false
        }

        self.session = session
        gridView.session = session
        gridView.onReadSelection = { [weak session] request in
            guard let session, let snapshot = session.lastSnapshot else { return }
            session.request(request, bootID: snapshot.bootID)
        }
        gridView.onCopyModeChanged = { [weak self] status in
            self?.copyModeStatus.update(status)
        }
        gridView.onCopyModeRequest = { [weak session] request, id, reply in
            guard let session, let snapshot = session.lastSnapshot else { return }
            session.request(request, bootID: snapshot.bootID, id: id, onReply: reply)
        }
        gridView.onFocusPane = { [weak self] paneID in
            guard let self, let session = self.session else { return }
            self.invoke(.focusPane(paneID), session: session)
        }
        gridView.onResize = { [weak self] cols, rows in
            guard let self, let session = self.session else { return }
            session.resize(
                cols: cols, rows: rows,
                cellWidth: Int(self.gridView.cellSize.width),
                cellHeight: Int(self.gridView.cellSize.height))
        }
        window.subtitle = ""
        publish(theme: preferences.theme(matching: systemIsDark))
        return true
    }

    /// Reattaches after the server goes away.
    ///
    /// herdr keeps terminals running when a client disconnects, so dropping the
    /// connection is a normal event — a server restart or an update — not a
    /// reason to make the user relaunch.
    private func reconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        session = nil
        gridView.session = nil
        window.subtitle = "reconnecting…"

        // Back off so a server that is down does not get hammered, but stay
        // responsive enough that a restart feels instant.
        func attempt(delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.connect() {
                        self.reconnecting = false
                        self.window.makeFirstResponder(self.gridView)
                        return
                    }
                    attempt(delay: min(delay * 2, 5))
                }
            }
        }
        attempt(delay: 0.25)
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
            reconnect()
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
        // Copy mode is entirely client-side: herdr has no endpoint method for
        // it, because the shell that owns the keymap owns the mode.
        if case .copyMode = command {
            gridView.enterCopyMode()
            window.makeFirstResponder(gridView)
            return
        }
        guard let snapshot = session.lastSnapshot,
            let json = command.requestJSON(id: UUID().uuidString)
        else { return }
        session.request(json, bootID: snapshot.bootID)
    }

    @objc private func findInPane(_ sender: Any?) {
        gridView.enterCopyMode(searching: true)
        window.makeFirstResponder(gridView)
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let session, let command = Command.allByTag[sender.tag] else { return }
        invoke(command, session: session)
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(
            title: "Settings…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
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
        editMenu.addItem(.separator())
        let find = NSMenuItem(
            title: "Find…", action: #selector(findInPane(_:)), keyEquivalent: "f")
        find.target = self
        editMenu.addItem(find)
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
        let delay = ProcessInfo.processInfo.environment["HERDX_CAPTURE_DELAY"]
            .flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
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



    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(
    ProcessInfo.processInfo.environment["HERDX_CAPTURE"] == nil ? .regular : .prohibited)
app.delegate = delegate
app.run()
