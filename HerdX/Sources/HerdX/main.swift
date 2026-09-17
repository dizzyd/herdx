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
    /// Why the last connection attempt failed, shown while waiting.
    private var lastConnectError: String?
    /// A title set by a program inside a pane, which outranks ours.
    private var serverTitle: String?

    /// Runs without ever showing a window.
    ///
    /// Set by `HERDX_HEADLESS`, and implied by `HERDX_CAPTURE`. Development on
    /// this app means running it dozens of times; every one of those stealing
    /// focus from whoever is at the keyboard is not acceptable, so not showing
    /// a window is its own mode rather than a side effect of capturing one.
    static var isHeadless: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["HERDX_HEADLESS"] != nil || environment["HERDX_CAPTURE"] != nil
    }
    private var preferences = Preferences.current
    private var preferencesWindow: PreferencesWindowController?
    private var appearanceObserver: NSKeyValueObservation?
    private let copyModeStatus = CopyModeStatusView()
    private let tabBar = TabBarView()

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
        tabBar.onSelectTab = { [weak self] tabID in
            guard let self, let session = self.session else { return }
            self.invoke(.focusTab(tabID), session: session)
            self.window.makeFirstResponder(self.gridView)
        }
        tabBar.onCloseTab = { [weak self] tabID in
            guard let self, let session = self.session else { return }
            self.invoke(.closeTabWithID(tabID), session: session)
        }
        tabBar.onNewTab = { [weak self] in
            guard let self, let session = self.session else { return }
            self.invoke(.newTab, session: session)
            self.window.makeFirstResponder(self.gridView)
        }
        sidebar.onSelectWorkspace = { [weak self] workspaceID, endpoint in
            guard let self, let session = self.session else { return }
            if endpoint != session.activeEndpoint {
                session.setActiveEndpoint(endpoint)
                self.gridView.forgetSurface()
            }
            // The command must carry the boot id of the machine it targets, not
            // of whichever one happened to be active a moment ago.
            self.invoke(
                .focusWorkspace(workspaceID), session: session,
                bootID: session.bootID(forEndpoint: endpoint))
            self.window.makeFirstResponder(self.gridView)
        }
        sidebar.onSelectEndpoint = { [weak self] index in
            guard let self, let session = self.session else { return }
            session.setActiveEndpoint(index)
            // The new machine's surface has not arrived; drop the old one so
            // the previous machine's output is not shown under a new name.
            self.gridView.forgetSurface()
            self.window.makeFirstResponder(self.gridView)
        }

        window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: CGFloat(cols) * cell.width + SidebarView.width,
                height: CGFloat(rows) * cell.height),
            // Not `.fullSizeContentView`: drawing under the title bar means
            // every pane below it needs safe-area insets, and that inset was
            // shifting the terminal's dirty rect by exactly the title bar's
            // height so it never painted.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "HerdX"
        window.delegate = self
        window.center()


        copyModeStatus.translatesAutoresizingMaskIntoConstraints = false

        // Tabs sit above the terminal and start where the terminal starts, so
        // the sidebar keeps the whole left column.
        //
        // A split view rather than a plain container: the terminal renders
        // correctly as a split view's arranged subview, and every attempt to
        // make it a constrained sibling ended with one of the two views never
        // drawing at all.
        let terminalArea = NSSplitView()
        terminalArea.isVertical = false
        terminalArea.dividerStyle = .thin
        terminalArea.addArrangedSubview(tabBar)
        terminalArea.addArrangedSubview(gridView)
        terminalArea.setHoldingPriority(.init(260), forSubviewAt: 0)
        terminalArea.setHoldingPriority(.init(250), forSubviewAt: 1)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(terminalArea)
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

        // Lay out before connecting: the handshake carries a surface size, and
        // asking for one before the views have frames requests a 1x1 surface —
        // which the server duly composes, leaving an empty window.
        window.contentView?.layoutSubtreeIfNeeded()

        if !connect() {
            // A server that is not running yet is not fatal: herdr sessions
            // outlive their clients, so wait for one instead of giving up.
            window.subtitle = "waiting for herdr… (\(lastConnectError ?? "no server"))"
            reconnect()
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

        if !AppDelegate.isHeadless {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(gridView)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Lay the window out off-screen so the view hierarchy has real
            // frames to render into, without ever appearing on a display.
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        // Layout has certainly happened by now, so make sure the server has the
        // real size even if no frame change fired after the handshake.
        gridView.reportGridSize()

        installCaptureHookIfRequested()

        // A display-linked repaint would be tighter, but the core only bumps a
        // revision when a surface actually lands, so a cheap tick is enough.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private var workspaceTitle: String?

    /// Explains an empty terminal, rather than leaving it blank.
    private func updatePlaceholder(session: HerdrSession) {
        let endpoints = session.endpoints
        guard let active = endpoints.first(where: { $0.index == session.activeEndpoint }) else {
            gridView.placeholder = "no machine selected"
            return
        }
        switch active.status {
        case .connecting:
            gridView.placeholder = "connecting to \(active.label)…"
        case .offline:
            gridView.placeholder = "\(active.label) is offline"
        case .online:
            gridView.placeholder =
                active.snapshot == nil
                ? "waiting for \(active.label)…"
                : "waiting for a surface from \(active.label)…"
        }
    }

    private func applyTitle() {
        if let serverTitle, !serverTitle.isEmpty {
            window.title = serverTitle
        } else if let workspaceTitle {
            window.title = "HerdX — \(workspaceTitle)"
        } else {
            window.title = "HerdX"
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
        tabBar.apply(theme: theme)
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
        // The view is laid out by now, so tell the server the real size; the
        // size used for the handshake was whatever existed before layout.
        gridView.reportGridSize()
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
        serverTitle = nil
        applyTitle()
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
        let snapshotsChanged = session.pollEndpointSnapshots()

        // Rebuilt every tick, not only when a snapshot lands: an endpoint's
        // connection status changes on its own, and gating on snapshots left
        // a machine reading "connecting…" long after it was up. The sidebar
        // compares a signature and returns immediately when nothing moved.
        sidebar.update(endpoints: session.endpoints, active: session.activeEndpoint)
        tabBar.update(with: session.lastSnapshot)

        if snapshotsChanged {
            if let snapshot = session.lastSnapshot {
                gridView.focusedPaneFromSnapshot = snapshot.focusedPaneID
                if let focused = snapshot.workspaces.first(where: \.focused) {
                    workspaceTitle = focused.label
                    window.subtitle = focused.branch ?? ""
                }
            }
            applyTitle()
        }
        for event in session.drainEvents() {
            // A program in a pane setting the title outranks the workspace
            // name, which is only a default; snapshots arrive constantly and
            // would otherwise clobber it within a frame.
            if case .windowTitle(let title) = event {
                serverTitle = title
                applyTitle()
                continue
            }
            events.present(event, window: window)
        }
        updatePlaceholder(session: session)
        gridView.refreshIfNeeded()
        if let error = session.takeError() {
            NSLog("herdr: %@", error)
        }
        // Endpoints reconnect individually inside the core, so a machine
        // being unreachable is shown in the sidebar rather than treated as a
        // reason to rebuild the session.
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

    private func invoke(_ command: Command, session: HerdrSession, bootID: String? = nil) {
        // Copy mode is entirely client-side: herdr has no endpoint method for
        // it, because the shell that owns the keymap owns the mode.
        if case .copyMode = command {
            gridView.enterCopyMode()
            window.makeFirstResponder(gridView)
            return
        }
        guard let boot = bootID ?? session.lastSnapshot?.bootID,
            let json = command.requestJSON(id: UUID().uuidString)
        else { return }
        session.request(json, bootID: boot)
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
            if let data = self.snapshot(of: view)?
                .representation(using: .png, properties: [:])
            {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
            }
        }
    }

    /// Renders the window off-screen for development.
    ///
    /// A plain `cacheDisplay` of the content view, which is truthful as long as
    /// nothing in the tree is layer-backed. It briefly was not: an earlier
    /// version composited the terminal separately to work around a view that
    /// was not drawing, which produced correct-looking screenshots of a broken
    /// window and cost hours. If this starts coming back blank, fix the view,
    /// not the screenshot.
    private func snapshot(of view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(AppDelegate.isHeadless ? .prohibited : .regular)
app.delegate = delegate
app.run()
