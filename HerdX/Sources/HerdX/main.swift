import AppKit

/// HerdX: a native macOS client for herdr.
///
/// The server owns terminal emulation and sends composed cell grids plus a
/// structured description of the workspace tree, so this app is a renderer and
/// an input source, not a terminal emulator.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSSplitViewDelegate,
    NSMenuDelegate
{
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
    /// The session the window is attached to, for the title.
    private var sessionTitle: String?
    /// The branch of the focused workspace, when it has one.
    private var branchTitle: String?
    /// A transient line — reconnecting, waiting for a server — which replaces
    /// the ordinary context until it clears.
    private var statusTitle: String?
    /// Held so a theme change can recolour their dividers.
    private var windowSplit: ChromeSplitView?
    /// The width to restore the sidebar to when it is brought back.
    private var sidebarWidth = SidebarView.width
    private var terminalSplit: ChromeSplitView?
    /// The terminal palette the chrome was last built from.
    private var terminalTheme: Theme = .dark
    /// The colour the panes are actually painted in, when it differs from the
    /// configured background.
    private var observedBackground: NSColor?
    /// The colours another client attached to this session is using.
    ///
    /// herdr keeps one host theme for the whole session and applies whichever
    /// client was last active — so with a second client attached, the terminal
    /// changes colour every time you switch apps. Nothing HerdX publishes can
    /// stop that; the only way out is for both clients to hold the same theme.
    ///
    /// When the other client is the one herdr is taking its theme from, its
    /// colours arrive baked into the cells, which is what this remembers.
    private(set) var attachedTerminal: (background: NSColor, foreground: NSColor)?
    /// Identifies the newest transient notice, so an older one's timer does not
    /// clear it.
    private var noticeToken = 0
    /// The strip's real content, restored when a notice times out.
    private var copyModeText: String?
    /// The digit that completed a chord, for the bindings herdr writes as a
    /// range: `switch_tab = "prefix+1..9"` is nine bindings on one line.
    private var pendingDigit = 0
    /// The profile the keymap was built from, so it is parsed once.
    private var appliedKeyProfile: String?
    /// True while resize mode owns the keyboard.
    private var resizing = false

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
    /// What was last sent to the server, so an unchanged theme is not resent.
    private var publishedTheme: [UInt8]?
    /// Machines that have been told our palette. An ssh endpoint attaches
    /// seconds after launch, long after the theme was first published, and a
    /// machine that never heard it composes against its own default background
    /// — which is why switching to one turned the terminal a different colour.
    private var themedEndpoints: Set<Int> = []
    /// Machines already offered a herdr install, so the offer is made once and
    /// not every time the endpoint retries.
    private var offeredInstall: Set<String> = []
    /// Which agents have been looked at since they last changed, which the
    /// snapshot cannot say because it is about this client's attention rather
    /// than the session's state.
    private var agentPriority = AgentPriority()
    /// Held so its tick can follow the sidebar when the switch is used.
    private weak var arrangementItem: NSMenuItem?
    /// What the machine catalog looked like when the session was built.
    private var knownMachines: String?
    private var ticks = 0
    /// The appearance the current theme was resolved from.
    private var appliedSystemIsDark: Bool?
    private let copyModeStatus = ModeStatus()
    private let tabBar = TabBarView()
    private let help = HelpSheet()
    private let prompt = Prompt()
    private let picker = Picker()
    private let themePicker = Picker()
    private let sessionMenu = NSMenu(title: "Session")
    private let agentSounds = AgentSounds()
    private lazy var machinesWindow = MachinesWindowController(
        onChange: { [weak self] in self?.reattach() },
        onInstall: { [weak self] machine in self?.installHerdr(on: machine) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = Preferences.current
        gridView = TerminalGridView(font: preferences.font, lineHeight: preferences.lineHeight)

        let cell = gridView.cellSize
        let cols = 120
        let rows = 34

        gridView.onBackgroundChanged = { [weak self] color in
            guard let self, color != self.observedBackground else { return }
            self.observedBackground = color
            self.applyChrome()
        }

        sidebar = SidebarView()
        sidebar.onSelect = { [weak self] command in
            guard let self, let session = self.session else { return }
            self.invoke(command, session: session)
            self.focusTerminal()
        }
        tabBar.onSelectTab = { [weak self] tabID in
            guard let self, let session = self.session else { return }
            self.invoke(.focusTab(tabID), session: session)
            self.focusTerminal()
        }
        tabBar.onCloseTab = { [weak self] tabID in
            guard let self, let session = self.session else { return }
            self.invoke(.closeTabWithID(tabID), session: session)
            self.focusTerminal()
        }
        tabBar.onNewTab = { [weak self] in
            guard let self, let session = self.session else { return }
            self.invoke(.newTab, session: session)
            self.focusTerminal()
        }
        sidebar.onSelectWorkspace = { [weak self] workspaceID, endpoint in
            self?.focus(.focusWorkspace(workspaceID), on: endpoint)
        }
        sidebar.onSelectPane = { [weak self] paneID, endpoint in
            self?.focus(.focusPane(paneID), on: endpoint)
        }
        sidebar.onArrangementChanged = { [weak self] arrangement in
            guard let self else { return }
            self.preferences.sidebarArrangement = arrangement.rawValue
            Preferences.current = self.preferences
            self.arrangementItem?.state = arrangement == .priority ? .on : .off
        }
        sidebar.show(
            arrangement: preferences.sidebarArrangement
                .flatMap(SidebarView.Arrangement.init(rawValue:)) ?? .spaces)

        sidebar.onSelectEndpoint = { [weak self] index in
            guard let self, let session = self.session else { return }
            session.setActiveEndpoint(index)
            // The new machine's surface has not arrived; drop the old one so
            // the previous machine's output is not shown under a new name.
            self.gridView.forgetSurface()
            self.focusTerminal()
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
        // A transparent title bar takes the window's background colour, which
        // is what carries the chrome up over the traffic lights. Not
        // `.fullSizeContentView`, which is the other half of that look: drawing
        // under the title bar means every view below needs safe-area insets,
        // and that inset shifted the terminal's dirty rect by exactly the title
        // bar's height so it never painted.
        window.titlebarAppearsTransparent = true



        // Tabs sit above the terminal and start where the terminal starts, so
        // the sidebar keeps the whole left column.
        //
        // A split view rather than a plain container: the terminal renders
        // correctly as a split view's arranged subview, and every attempt to
        // make it a constrained sibling ended with one of the two views never
        // drawing at all.
        let terminalArea = ChromeSplitView()
        terminalArea.isVertical = false
        terminalArea.dividerStyle = .thin
        // Tabs and terminal are one surface, so the seam between them should
        // not be visible at all.
        terminalArea.seamless = true
        terminalArea.addArrangedSubview(tabBar)
        terminalArea.addArrangedSubview(gridView)
        terminalArea.setHoldingPriority(.init(260), forSubviewAt: 0)
        terminalArea.setHoldingPriority(.init(250), forSubviewAt: 1)
        terminalSplit = terminalArea

        let split = ChromeSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        windowSplit = split
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
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.topAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        copyModeStatus.attach(to: window, over: gridView)

        // The sidebar opens at its default width and is draggable from there;
        // the divider has to be placed after layout, or it is positioned
        // against a window that has not been sized yet.
        window.contentView?.layoutSubtreeIfNeeded()
        split.setPosition(SidebarView.width, ofDividerAt: 0)

        // Lay out before connecting: the handshake carries a surface size, and
        // asking for one before the views have frames requests a 1x1 surface —
        // which the server duly composes, leaving an empty window.
        window.contentView?.layoutSubtreeIfNeeded()

        if !connect() {
            // A server that is not running yet is not fatal: herdr sessions
            // outlive their clients, so wait for one instead of giving up.
            statusTitle = "waiting for herdr… (\(lastConnectError ?? "no server"))"
            applyTitle()
            reconnect()
        }

        buildMenu()
        arrangementItem?.state =
            preferences.sidebarArrangement == SidebarView.Arrangement.priority.rawValue
            ? .on : .off
        installKeyMonitor()
        events.requestAuthorization()
        applyTheme()

        // Follow the system when the user has not pinned an appearance.
        //
        // This fires whenever the effective appearance is re-evaluated, which
        // includes the app being activated and deactivated, so act only when
        // light/dark has genuinely flipped.
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.systemIsDark != self.appliedSystemIsDark else { return }
                    self.applyTheme()
                }
            }
        }

        if !AppDelegate.isHeadless {
            // `HERDX_QUIET_FRONT` shows the window without taking focus, for
            // validating what only a real compositor can show. Stealing focus
            // from whoever is at the keyboard is not acceptable just to look
            // at a pixel.
            if ProcessInfo.processInfo.environment["HERDX_QUIET_FRONT"] != nil {
                window.orderFront(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(gridView)
                NSApp.activate(ignoringOtherApps: true)
            }
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
        installInputProbeIfRequested()

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
        case .offline where !active.isRemote:
            // The local machine going quiet usually means herdr is not there
            // at all, which "Local is offline" does not begin to say.
            switch LocalHerdr.state(serverIsUp: false) {
            case .missing:
                gridView.placeholder =
                    "HerdX is a client for herdr, which is not installed.\n\n"
                    + LocalHerdr.installCommand
                    + "\n\nthen run  herdr  to start a session."
            case .installed:
                gridView.placeholder =
                    "herdr is installed but not running.\n\n"
                    + "run  herdr  in a terminal to start a session."
            case .running:
                gridView.placeholder = active.error ?? "\(active.label) is offline"
            }
        case .offline:
            gridView.placeholder = active.error ?? "\(active.label) is offline"
        case .online:
            gridView.placeholder =
                active.snapshot == nil
                ? "waiting for \(active.label)…"
                : "waiting for a surface from \(active.label)…"
        }
    }

    /// The title says which session; the subtitle says what is inside it.
    ///
    /// One window is one herdr session, so that is the window-level fact and it
    /// goes on the title line. A workspace, a branch, or a title a program set
    /// describes what is on screen underneath — context, and read as such.
    private func applyTitle() {
        window.title = sessionTitle ?? "HerdX"
        if let statusTitle {
            window.subtitle = statusTitle
            return
        }
        let inside = serverTitle?.isEmpty == false ? serverTitle : workspaceTitle
        window.subtitle = [inside, branchTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
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
        appliedSystemIsDark = systemIsDark
        // Everything this app paints itself comes from the terminal theme and
        // the chrome derived from it, so that the window reads as one surface
        // rather than two. The Mac light/dark appearance follows that chrome
        // and is set in applyChrome, where the chrome is known.
        terminalTheme = preferences.terminalTheme(matching: systemIsDark)

        gridView.theme = terminalTheme
        gridView.apply(
            panePadding: preferences.panePadding, labelSize: preferences.paneLabelSize)

        applyChrome()
        publish(theme: terminalTheme)
    }

    /// Recolours the chrome from the terminal, without telling the server
    /// anything.
    ///
    /// Separate from `applyTheme` because it also runs when a program inside a
    /// pane changes colour, and publishing our palette back on that would be
    /// answering the server with what it just said.
    private func applyChrome() {
        let palette = Chrome(theme: terminalTheme, background: observedBackground)
        gridView.chrome = palette
        gridView.needsDisplay = true
        // The title bar is transparent, so the window's own colour is what
        // shows above the sidebar and tabs.
        window.backgroundColor = palette.surface
        // And the title, the traffic lights and everything else AppKit draws up
        // there sits on that colour, so it has to be told what the colour is.
        // Taking this from the Window setting instead is what put a black title
        // on a dark title bar: the setting chooses a palette, but a program
        // that paints its own background wins on screen, and the chrome follows
        // the screen.
        window.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        sidebar.apply(chrome: palette)
        copyModeStatus.apply(chrome: palette)
        tabBar.apply(chrome: palette)
        windowSplit?.apply(chrome: palette)
        terminalSplit?.apply(chrome: palette)
    }

    /// Tells the server our terminal palette.
    ///
    /// herdr applies the *foreground* client's host theme to every pane, and
    /// picks the foreground client by activity. So with another client attached
    /// to the same session, whichever of you typed last decides what colour the
    /// terminal is, and a pane whose program follows the background re-themes
    /// every time that changes. Publishing is what lets the two agree; the
    /// Terminal setting is what makes them agree on the same thing.
    ///
    /// Sent only when the colours actually differ from what the server was last
    /// told, since republishing an unchanged theme still reads as a change to
    /// the program in the pane.
    private func publish(theme: Theme, force: Bool = false) {
        guard let session else { return }

        let fingerprint =
            [theme.rgbBytes(of: theme.background), theme.rgbBytes(of: theme.foreground)]
            .flatMap { [$0.0, $0.1, $0.2] } + theme.paletteBytes
        guard force || fingerprint != publishedTheme else { return }
        publishedTheme = fingerprint

        session.setDefaultColor(foreground: false, rgb: theme.rgbBytes(of: theme.background))
        session.setDefaultColor(foreground: true, rgb: theme.rgbBytes(of: theme.foreground))
        session.setPalette(theme.paletteBytes)
        session.setAppearance(dark: theme.background.isDarkish)
    }

    @objc private func showPreferences(_ sender: Any?) {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController { [weak self] updated in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.preferences = updated
                    self.agentSounds.isEnabled = updated.agentSounds
                    self.gridView.apply(
                        font: updated.font, lineHeight: updated.lineHeight)
                    self.applyTheme()
                }
            }
        }
        // Told each time it opens: what is attached can change while it is shut.
        preferencesWindow?.attachedTerminal = attachedTerminal
        preferencesWindow?.refresh()
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// The session to attach to, and what to call it.
    ///
    /// The remembered choice only holds while that session is still running: a
    /// session stopped since the app last ran is an ordinary thing to come back
    /// to, and refusing to open a window over it would help nobody. With no
    /// choice — or an environment that names a socket for this run — the core
    /// picks, and this only puts a name to whatever it picked.
    private func resolvedSession() -> (name: String?, socket: String?) {
        let sessions = SessionCatalog.list()
        if !SessionCatalog.environmentPicksSocket, let saved = preferences.sessionName,
            let entry = sessions.first(where: { $0.name == saved && $0.running })
        {
            return (entry.name, entry.clientSocket)
        }
        let socket = HerdrSession.defaultSocketPath
        return (sessions.first { $0.clientSocket == socket }?.name, nil)
    }

    /// Whether a session attaches the saved machines as well as the local
    /// server.
    ///
    /// Yes by default: a machine in herdr's catalog is there to be attached,
    /// and that is what every window did before there was a choice. A session
    /// HerdX made is the exception, because pulling another machine's session
    /// into a window made to be new is not what new means. An unknown session —
    /// one the core picked for itself — keeps the default.
    private func attachesMachines(_ name: String?) -> Bool {
        guard let name else { return true }
        return !preferences.localOnlySessions.contains(name)
    }

    /// Attaches or drops the saved machines for the session in the window.
    @objc private func toggleMachines(_ sender: Any?) {
        guard let name = sessionTitle else { return }
        if attachesMachines(name) {
            preferences.localOnlySessions.append(name)
        } else {
            preferences.localOnlySessions.removeAll { $0 == name }
        }
        Preferences.current = preferences
        reattach()
    }

    /// Attaches to another session.
    ///
    /// The socket is settled when the endpoints are spawned, so there is no
    /// changing it on a live session — it has to be stood up again, exactly as
    /// adding a machine does.
    @objc private func switchSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, name != sessionTitle else { return }
        adopt(session: name)
    }

    private func adopt(session name: String) {
        preferences.sessionName = name
        Preferences.current = preferences
        reattach()
    }

    /// Asks for a name and starts a session under it.
    @objc private func newSession(_ sender: Any?) {
        prompt.ask(
            over: window, title: "New herdr session", value: "", placeholder: "name"
        ) { [weak self] name in
            self?.createSession(named: name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Starts a session and moves the window to it.
    ///
    /// herdr has no "create": a session exists as soon as something names one,
    /// so a name never used before and a session that has been stopped are the
    /// same command. The server takes a moment to start listening, and until it
    /// does there is nothing to attach to — so this waits for herdr to call it
    /// running rather than connecting and hoping.
    private func createSession(named name: String) {
        guard !name.isEmpty else { return }
        // A session lives in a directory named after it, so a name carrying a
        // separator would be a path rather than a name.
        guard !name.contains("/"), !name.hasPrefix(".") else {
            alert(
                "“\(name)” is not a session name",
                "herdr keeps each session in a directory named after it, so the name "
                    + "cannot contain “/” or start with a dot.")
            return
        }
        if SessionCatalog.list().first(where: { $0.name == name })?.running == true {
            // Already up: going there is what was meant.
            adopt(session: name)
            return
        }
        guard LocalHerdr.binaryPath() != nil else {
            alert("herdr is not installed", LocalHerdr.installCommand)
            return
        }
        guard SessionCatalog.start(name) else {
            alert("Could not start “\(name)”", "herdr would not run.")
            return
        }
        // A session made to be new starts local. The machines are a menu item
        // away, and a window that arrives carrying another machine's session is
        // not what anyone means by new.
        if !preferences.localOnlySessions.contains(name) {
            preferences.localOnlySessions.append(name)
            Preferences.current = preferences
        }
        notice("starting \(name)…")
        waitForSession(named: name, until: Date().addingTimeInterval(10))
    }

    /// Polls herdr until the new session is running, then moves to it.
    private func waitForSession(named name: String, until deadline: Date) {
        guard SessionCatalog.list().first(where: { $0.name == name })?.running != true else {
            // A server comes up with nothing in it, and a window attached to an
            // empty session has nothing to show. herdr decides where the first
            // workspace starts; it is not ours to choose.
            if SessionCatalog.workspaceCount(name) == 0 {
                SessionCatalog.createWorkspace(in: name)
            }
            adopt(session: name)
            return
        }
        guard Date() < deadline else {
            alert(
                "“\(name)” did not start",
                "The server was launched but is not listening. `herdr session list` will "
                    + "say whether it came up.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                self?.waitForSession(named: name, until: deadline)
            }
        }
    }

    /// Stops the session the window is on, after asking.
    @objc private func stopSession(_ sender: Any?) {
        guard let name = sessionTitle else { return }
        let confirm = NSAlert()
        confirm.messageText = "Stop “\(name)”?"
        confirm.informativeText =
            "Everything running in it stops, for every client attached to it: herdr keeps "
            + "terminals alive when a client goes away, but they belong to the server. The "
            + "session and its workspaces come back if you start it again."
        let stop = confirm.addButton(withTitle: "Stop")
        let cancel = confirm.addButton(withTitle: "Cancel")
        // Return must not be the button that kills terminals.
        stop.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        stopSession(named: name)
    }

    /// Stops a session and moves the window off it.
    ///
    /// Somewhere to go rather than nowhere: the window was showing a server
    /// that no longer exists, and leaving it to reconnect to a socket nothing
    /// is listening on would only look broken. The default session is the one
    /// to fall back to, being the one a bare `herdr` opens.
    private func stopSession(named name: String) {
        guard SessionCatalog.stop(name) else {
            alert("Could not stop “\(name)”", "herdr would not stop the session.")
            return
        }
        notice("stopped \(name)")
        let running = SessionCatalog.list().filter { $0.running && $0.name != name }
        if let next = running.first(where: \.isDefault) ?? running.first {
            adopt(session: next.name)
        } else {
            preferences.sessionName = nil
            Preferences.current = preferences
            reattach()
        }
    }

    private func alert(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    /// Fills the Session menu from herdr each time it is opened.
    ///
    /// Rebuilt rather than kept in step: sessions are started and stopped by
    /// the herdr CLI and by other clients, so anything cached here would be a
    /// list of what was true the last time this app happened to look.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === sessionMenu else { return }
        menu.removeAllItems()
        let sessions = SessionCatalog.list()
        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No herdr sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for entry in sessions {
            let item = NSMenuItem(
                title: entry.running ? entry.name : "\(entry.name)  (stopped)",
                action: #selector(switchSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.name
            item.state = entry.name == sessionTitle ? .on : .off
            // Attaching to a stopped session would only produce a window
            // waiting for a server that nothing is going to start.
            item.isEnabled = entry.running
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let new = NSMenuItem(
            title: "New Session…", action: #selector(newSession(_:)), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        let stop = NSMenuItem(
            title: sessionTitle.map { "Stop “\($0)”…" } ?? "Stop Session…",
            action: #selector(stopSession(_:)), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = sessionTitle != nil
        menu.addItem(stop)

        // Only worth offering where there is a machine to attach; with an empty
        // catalog it is a switch with nothing on the other end.
        if Machines.all().contains(where: \.enabled) {
            menu.addItem(.separator())
            let machines = NSMenuItem(
                title: "Attach Machines", action: #selector(toggleMachines(_:)),
                keyEquivalent: "")
            machines.target = self
            machines.state = attachesMachines(sessionTitle) ? .on : .off
            machines.isEnabled = sessionTitle != nil
            menu.addItem(machines)
        }
    }

    /// Opens a session and hands it to the views. Returns false if no server.
    @discardableResult
    private func connect() -> Bool {
        let size = gridView.gridSize
        let cell = gridView.cellSize
        let chosen = resolvedSession()
        sessionTitle = chosen.name
        let session: HerdrSession
        do {
            session = try HerdrSession(
                cols: size.cols, rows: size.rows,
                cellWidth: Int(cell.width), cellHeight: Int(cell.height),
                socketPath: chosen.socket, machines: attachesMachines(chosen.name))
        } catch {
            lastConnectError = error.localizedDescription
            return false
        }

        self.session = session
        agentSounds.isEnabled = preferences.agentSounds
        // Endpoint indices are about to mean different machines; what this
        // remembers about the old ones would be answers to the wrong questions.
        agentPriority.forget()
        // A session torn down and stood up again arrives with every agent as it
        // is now, which is first sight rather than a hundred state changes.
        agentSounds.forget()
        gridView.session = session
        // Already active when the session arrives, which is the ordinary case:
        // the notification fired before there was anything to tell.
        session.setFocused(NSApp.isActive)
        gridView.onReadSelection = { [weak session] request in
            guard let session, let snapshot = session.lastSnapshot else { return }
            session.request(request, bootID: snapshot.bootID)
        }
        gridView.onCopyModeChanged = { [weak self] status in
            self?.copyModeText = status
            self?.copyModeStatus.update(status)
        }
        gridView.onCopyModeRequest = { [weak session] request, id, reply in
            guard let session, let snapshot = session.lastSnapshot else { return }
            session.request(request, bootID: snapshot.bootID, id: id, onReply: reply)
        }
        gridView.onFocusPane = { [weak self] paneID in
            guard let self, let session = self.session else { return }
            self.invoke(.focusPane(paneID), session: session)
            self.focusTerminal()
        }
        gridView.onResize = { [weak self] cols, rows in
            guard let self, let session = self.session else { return }
            session.resize(
                cols: cols, rows: rows,
                cellWidth: Int(self.gridView.cellSize.width),
                cellHeight: Int(self.gridView.cellSize.height))
        }
        statusTitle = nil
        applyTitle()
        publishedTheme = nil
        publish(theme: preferences.terminalTheme(matching: systemIsDark), force: true)
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
        statusTitle = "reconnecting…"
        applyTitle()

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

    /// What each pane's frame says about itself.
    ///
    /// The working directory first, because that is what tells two shells in
    /// the same project apart, then the agent and its state when a pane has
    /// one. A pane with neither falls back to whatever herdr calls it.
    private static func paneLabels(from snapshot: Snapshot?) -> [String: String] {
        guard let snapshot else { return [:] }
        let agents = Dictionary(
            snapshot.agents.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        // A zoomed tab sends a surface holding one pane, so the others are not
        // merely small, they are absent — and nothing on screen would otherwise
        // say they exist. It leads the label because the label truncates from
        // the middle, so the head survives however narrow the pane gets.
        let zoomed = Set(snapshot.tabs.filter(\.zoomed).map(\.tabID))
        let paneCount = Dictionary(grouping: snapshot.panes, by: \.tabID).mapValues(\.count)

        var labels: [String: String] = [:]
        for pane in snapshot.panes {
            var parts: [String] = []
            if zoomed.contains(pane.tabID), let total = paneCount[pane.tabID], total > 1 {
                parts.append("⤢ \(total - 1) hidden")
            }
            if let cwd = pane.cwd, !cwd.isEmpty { parts.append(abbreviated(cwd)) }
            if let agent = agents[pane.paneID] {
                if let name = agent.displayAgent, !name.isEmpty { parts.append(name) }
                parts.append(String(describing: agent.agentStatus))
            } else if let label = pane.label, !label.isEmpty {
                parts.append(label)
            }
            labels[pane.paneID] = parts.joined(separator: "  ·  ")
        }
        return labels
    }

    /// Home is where most work happens, so spelling it out wastes the width the
    /// interesting end of the path needs.
    private static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func tick() {
        guard let session else { return }
        let snapshotsChanged = session.pollEndpointSnapshots()

        // Rebuilt every tick, not only when a snapshot lands: an endpoint's
        // connection status changes on its own, and gating on snapshots left
        // a machine reading "connecting…" long after it was up. The sidebar
        // compares a signature and returns immediately when nothing moved.
        // What is on screen is what counts as seen, so this is noted before
        // anything is asked to order agents by it — and only while the app is
        // in front, because a pane focused behind another application has not
        // been seen by anyone.
        for endpoint in session.endpoints {
            guard let snapshot = endpoint.snapshot else { continue }
            agentPriority.observe(
                snapshot: snapshot, endpoint: endpoint.index,
                watching: NSApp.isActive && endpoint.index == session.activeEndpoint)
        }
        sidebar.priority = agentPriority

        let online = Set(session.endpoints.filter { $0.status == .online }.map(\.index))
        if !online.subtracting(themedEndpoints).isEmpty {
            themedEndpoints = online
            publish(theme: terminalTheme, force: true)
        } else if online != themedEndpoints {
            // A machine that dropped is told again when it returns.
            themedEndpoints = online
        }

        noteAttachedTerminal()
        watchMachines()
        offerInstallIfNeeded(session)
        sidebar.update(endpoints: session.endpoints, active: session.activeEndpoint)
        tabBar.update(
            with: session.lastSnapshot, priority: agentPriority,
            endpoint: session.activeEndpoint)
        gridView.paneLabels = Self.paneLabels(from: session.lastSnapshot)

        if snapshotsChanged {
            // Every machine, not just the one on screen: an agent that needs
            // you on another machine is the whole reason they are all attached.
            for endpoint in session.endpoints {
                guard let snapshot = endpoint.snapshot else { continue }
                agentSounds.update(
                    snapshot, endpoint: endpoint.index,
                    focused: endpoint.index == session.activeEndpoint && NSApp.isActive)
            }
            if let snapshot = session.lastSnapshot {
                // The user's own bindings, including a prefix they may have
                // changed. Until one arrives the resolver runs on herdr's
                // documented defaults.
                if let profile = snapshot.serverKeybindingsToml, profile != appliedKeyProfile,
                    let keymap = Keymap(profile: profile)
                {
                    appliedKeyProfile = profile
                    chords.keymap = keymap
                    gridView.prefixLabel = keymap.prefixLabel
                }
                gridView.focusedPaneFromSnapshot = snapshot.focusedPaneID
                if let focused = snapshot.workspaces.first(where: \.focused) {
                    workspaceTitle = focused.label
                    branchTitle = focused.branch
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
        // Endpoints reconnect individually inside the core, so a machine
        // being unreachable is shown in the sidebar rather than treated as a
        // reason to rebuild the session.
    }

    /// The prefix chord has to be seen before the view turns it into pane input.
    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let session = self.session else { return event }
            if self.resizeKey(event, session: session) { return nil }
            self.pendingDigit = Int(event.charactersIgnoringModifiers ?? "") ?? 0
            let (action, consumed) = self.chords.resolve(event)
            self.gridView.prefixArmed = self.chords.prefixArmed
            if let action { self.perform(action, session: session) }
            return consumed ? nil : event
        }
    }

    /// Carries out one of herdr's actions, or says why it cannot.
    ///
    /// The keymap is the server's, so it names actions HerdX has no answer for.
    /// Those say so rather than being swallowed: a bound key that does nothing
    /// and explains nothing is what sent me looking for a broken keyboard.
    private func perform(_ action: Keymap.Action, session: HerdrSession) {
        guard let run = handler(for: action, session: session) else {
            notice("\(chords.keymap.prefixLabel) \(action.title.lowercased()) is not in HerdX yet")
            return
        }
        run()
    }

    /// What an action does, or nil when HerdX has no answer for it.
    ///
    /// One lookup rather than a switch plus a list of what the switch covers:
    /// the help asks this same question, so it cannot claim a binding works
    /// when nothing here carries it out.
    private func handler(
        for action: Keymap.Action, session: HerdrSession
    ) -> (() -> Void)? {
        let snapshot = session.lastSnapshot

        switch action {
        case .help: return { self.invoke(.help, session: session) }
        case .settings: return { self.showPreferences(nil) }
        case .detach: return { self.window.performClose(nil) }
        case .toggleSidebar: return { self.invoke(.toggleSidebar, session: session) }
        case .reloadConfig: return { self.invoke(.reloadConfig, session: session) }

        case .newTab: return { self.invoke(.newTab, session: session) }
        case .closeTab: return { self.invoke(.closeTab, session: session) }
        case .nextTab: return { self.invoke(.nextTab, session: session) }
        case .previousTab: return { self.invoke(.previousTab, session: session) }
        case .switchTab: return { self.focusTab(at: self.pendingDigit - 1, session: session) }

        case .newWorkspace: return { self.invoke(.newWorkspace, session: session) }
        case .closeWorkspace:
            guard let id = snapshot?.workspaces.first(where: \.focused)?.workspaceID else {
                return nil
            }
            return { self.invoke(.closeWorkspace(id), session: session) }

        case .splitVertical: return { self.invoke(.splitRight, session: session) }
        case .splitHorizontal: return { self.invoke(.splitDown, session: session) }
        case .closePane: return { self.invoke(.closePane, session: session) }
        case .zoom: return { self.invoke(.zoomPane, session: session) }
        case .focusPaneLeft: return { self.invoke(.focusLeft, session: session) }
        case .focusPaneDown: return { self.invoke(.focusDown, session: session) }
        case .focusPaneUp: return { self.invoke(.focusUp, session: session) }
        case .focusPaneRight: return { self.invoke(.focusRight, session: session) }
        case .cyclePaneNext: return { self.cyclePane(by: 1, session: session) }
        case .cyclePanePrevious: return { self.cyclePane(by: -1, session: session) }
        case .copyMode: return { self.invoke(.copyMode, session: session) }

        case .swapPaneLeft: return { self.invoke(.swapLeft, session: session) }
        case .swapPaneDown: return { self.invoke(.swapDown, session: session) }
        case .swapPaneUp: return { self.invoke(.swapUp, session: session) }
        case .swapPaneRight: return { self.invoke(.swapRight, session: session) }

        case .editScrollback:
            guard let pane = gridView.focusedPane else { return nil }
            return { self.invoke(.editScrollback(pane), session: session) }

        case .renameTab:
            guard let tab = snapshot?.tabs.first(where: { $0.tabID == snapshot?.focusedTabID })
            else { return nil }
            return {
                self.prompt.ask(
                    over: self.window, title: "Rename tab", value: tab.label
                ) { self.invoke(.renameTab(tab.tabID, $0), session: session) }
            }

        case .renamePane:
            guard let pane = snapshot?.panes.first(where: { $0.paneID == snapshot?.focusedPaneID })
            else { return nil }
            return {
                self.prompt.ask(
                    over: self.window, title: "Rename pane", value: pane.label ?? ""
                ) { self.invoke(.renamePane(pane.paneID, $0), session: session) }
            }

        case .renameWorkspace:
            guard let workspace = snapshot?.workspaces.first(where: \.focused) else { return nil }
            return {
                self.prompt.ask(
                    over: self.window, title: "Rename workspace", value: workspace.label
                ) { self.invoke(.renameWorkspace(workspace.workspaceID, $0), session: session) }
            }

        case .workspacePicker:
            let workspaces = session.endpoints.flatMap { endpoint in
                (endpoint.snapshot?.workspaces ?? []).map { (endpoint, $0) }
            }
            guard !workspaces.isEmpty else { return nil }
            return {
                self.picker.show(
                    over: self.window, title: "Workspaces",
                    items: workspaces.map { endpoint, workspace in
                        Picker.Item(
                            title: workspace.label,
                            detail: [endpoint.label, workspace.branch, "\(workspace.agentStatus)"]
                                .compactMap { $0 }.joined(separator: "  ·  ")
                        ) {
                            self.focus(
                                .focusWorkspace(workspace.workspaceID), on: endpoint.index)
                        }
                    })
            }

        case .goto_:
            let items = self.navigator(session)
            guard !items.isEmpty else { return nil }
            return { self.picker.show(over: self.window, title: "Go to", items: items) }

        case .resizeMode:
            return { self.enterResizeMode() }

        default: return nil
        }
    }

    /// herdr's resize mode: the arrows keep resizing until you leave.
    ///
    /// A mode rather than four bindings, because resizing is something you do
    /// several times in a row and reaching for the prefix between each one is
    /// the whole reason herdr has a mode for it.
    private func enterResizeMode() {
        resizing = true
        copyModeStatus.update("resize  ←↓↑→ or hjkl  ·  esc to finish")
    }

    private func leaveResizeMode() {
        resizing = false
        copyModeStatus.update(copyModeText)
    }

    /// Handles a key while resize mode is up. Returns true when it consumed it.
    private func resizeKey(_ event: NSEvent, session: HerdrSession) -> Bool {
        guard resizing else { return false }
        let direction: String?
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (123, _), (_, "h"): direction = "left"
        case (124, _), (_, "l"): direction = "right"
        case (126, _), (_, "k"): direction = "up"
        case (125, _), (_, "j"): direction = "down"
        default: direction = nil
        }
        guard let direction else {
            // Anything that is not a resize ends the mode rather than being
            // swallowed, so one stray key cannot leave the keyboard captured.
            leaveResizeMode()
            return event.keyCode == 53 || event.keyCode == 36
        }
        invoke(.resizePane(direction), session: session)
        return true
    }

    /// Runs a command against a machine, switching to it first if need be.
    ///
    /// Anything that can name a target on another machine goes through here:
    /// the command has to carry the boot id of the machine it targets, not of
    /// whichever one happened to be active a moment ago.
    private func focus(_ command: Command, on endpoint: Int) {
        guard let session else { return }
        if endpoint != session.activeEndpoint {
            session.setActiveEndpoint(endpoint)
            // The new machine's surface has not arrived; drop the old one so
            // the previous machine's output is not shown under a new name.
            gridView.forgetSurface()
        }
        invoke(command, session: session, bootID: session.bootID(forEndpoint: endpoint))
        focusTerminal()
    }

    /// Everything in the session, flattened for the navigator.
    ///
    /// Workspaces, then their tabs, then the panes inside them: a navigator is
    /// for when you know the name but not where it lives, so the list has to
    /// hold all three rather than make you pick a level first.
    private func navigator(_ session: HerdrSession) -> [Picker.Item] {
        var items: [Picker.Item] = []

        // Every attached machine, not just the one on screen: the whole point
        // of attaching to several is finding what is running elsewhere without
        // having to switch first to go looking.
        for endpoint in session.endpoints {
            guard let snapshot = endpoint.snapshot else { continue }
            let agents = Dictionary(
                snapshot.agents.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })

            for workspace in snapshot.workspaces {
                items.append(
                    Picker.Item(
                        title: workspace.label,
                        detail: [endpoint.label, workspace.branch ?? "workspace"]
                            .joined(separator: "  ·  ")
                    ) { self.focus(.focusWorkspace(workspace.workspaceID), on: endpoint.index) })

                for tab in snapshot.tabs where tab.workspaceID == workspace.workspaceID {
                    let name = tab.label.isEmpty ? "tab \(tab.number)" : tab.label
                    items.append(
                        Picker.Item(
                            title: name,
                            detail: [endpoint.label, workspace.label, "tab"]
                                .joined(separator: "  ·  ")
                        ) { self.focus(.focusTab(tab.tabID), on: endpoint.index) })

                    for pane in snapshot.panes where pane.tabID == tab.tabID {
                        let agent = agents[pane.paneID]
                        // Falls back to the id rather than to "pane": a list
                        // where every third row says the same word is not a
                        // list.
                        let title =
                            [pane.label, agent?.title, agent?.displayAgent]
                            .compactMap { $0 }.first { !$0.isEmpty } ?? pane.paneID
                        items.append(
                            Picker.Item(
                                title: title,
                                detail: [
                                    endpoint.label, workspace.label, name,
                                    pane.cwd.map(Self.abbreviated),
                                ].compactMap { $0 }.joined(separator: "  ·  ")
                            ) { self.focus(.focusPane(pane.paneID), on: endpoint.index) })
                    }
                }
            }
        }
        return items
    }

    /// Focuses a tab or pane by its place in the current tab bar.
    ///
    /// herdr binds these to a position, not to an id, so the id has to come
    /// from the snapshot the same way clicking a chip gets it.
    private func focusTab(at index: Int, session: HerdrSession) {
        guard let snapshot = session.lastSnapshot else { return }
        let tabs = snapshot.tabs.filter { $0.workspaceID == snapshot.focusedWorkspaceID }
        guard tabs.indices.contains(index) else { return }
        invoke(.focusTab(tabs[index].tabID), session: session)
    }

    /// Focuses the tab `step` along from the focused one, wrapping round.
    private func focusTab(offsetBy step: Int, session: HerdrSession) {
        guard let snapshot = session.lastSnapshot else { return }
        let tabs = snapshot.tabs.filter { $0.workspaceID == snapshot.focusedWorkspaceID }
        guard tabs.count > 1,
            let at = tabs.firstIndex(where: { $0.tabID == snapshot.focusedTabID })
        else { return }
        invoke(.focusTab(tabs[(at + step + tabs.count) % tabs.count].tabID), session: session)
    }

    private func cyclePane(by step: Int, session: HerdrSession) {
        let panes = gridView.panes
        guard panes.count > 1, let current = gridView.focusedPane,
            let at = panes.firstIndex(where: { $0.id == current })
        else { return }
        let next = panes[(at + step + panes.count) % panes.count]
        invoke(.focusPane(next.id), session: session)
    }

    /// Reports any prefix binding no keystroke can reach.
    ///
    /// Generated from the keymap rather than from a list here, so it keeps
    /// checking whatever the server sends. It exists because the matcher has
    /// twice been too strict about shift and made a binding unreachable —
    /// silently, since an armed prefix consumes the key either way.
    private func reportUnreachableChords() {
        for (action, binding) in chords.keymap.bindings where binding.usesPrefix {
            // How a key is actually typed is not knowable from the profile:
            // "?" needs a shift the profile never mentions. So a binding counts
            // as reachable if either spelling finds it.
            let reachable = [binding.shift, true].contains { shift in
                var flags: NSEvent.ModifierFlags = shift ? [.shift] : []
                if binding.control { flags.insert(.control) }
                if binding.option { flags.insert(.option) }
                if binding.command { flags.insert(.command) }
                guard
                    let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil,
                        characters: binding.probeCharacters,
                        charactersIgnoringModifiers: binding.probeCharacters,
                        isARepeat: false, keyCode: binding.probeKeyCode)
                else { return false }
                return chords.keymap.action(forPrefixed: event) == action
            }
            if !reachable { print("probe: UNREACHABLE \(action.rawValue) = \(binding.label)") }
        }
        print("probe: checked \(chords.keymap.bindings.filter(\.binding.usesPrefix).count) chords")
    }

    /// Says that a command failed, and why if herdr said.
    private func report(failure reply: String, for command: Command) {
        let message =
            reply
            .split(separator: "\"message\":\"", maxSplits: 1).last?
            .split(separator: "\"").first.map(String.init)
        FileHandle.standardError.write(Data("herdx: \(command.method) failed: \(reply)\n".utf8))
        notice("\(command.method) failed\(message.map { ": \($0)" } ?? "")")
    }

    /// A line over the terminal that clears itself.
    private func notice(_ text: String) {
        noticeToken += 1
        let token = noticeToken
        copyModeStatus.update(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.noticeToken == token else { return }
                self.copyModeStatus.update(self.copyModeText)
            }
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
        // Likewise client-side: the keymap is ours, so herdr has nothing to
        // say about it and no method to ask.
        if case .settings = command {
            showPreferences(nil)
            return
        }
        if case .toggleSidebar = command {
            toggleSidebar()
            return
        }
        // These take a required id that herdr will not infer from who is
        // asking, so the focused one is supplied here rather than in every
        // caller. Sending none is rejected as a missing field.
        if case .closeTab = command, let tab = session.lastSnapshot?.focusedTabID {
            invoke(.closeTabWithID(tab), session: session, bootID: bootID)
            return
        }
        if case .closePane = command, let pane = gridView.focusedPane {
            invoke(.closePaneWithID(pane), session: session, bootID: bootID)
            return
        }
        // herdr's tab.focus takes a tab id and has no relative form, so "the
        // next one" is ours to work out.
        if case .nextTab = command {
            focusTab(offsetBy: 1, session: session)
            return
        }
        if case .previousTab = command {
            focusTab(offsetBy: -1, session: session)
            return
        }
        if case .help = command {
            help.show(over: window, keymap: chords.keymap) { action in
                self.handler(for: action, session: session) != nil
            }
            return
        }
        let id = UUID().uuidString
        guard let boot = bootID ?? session.lastSnapshot?.bootID,
            let json = command.requestJSON(id: id)
        else { return }
        // Replies were dropped, so a request the server rejected did nothing
        // and said nothing — which is how four commands came to be sending
        // parameters herdr does not accept without anyone noticing.
        session.request(json, bootID: boot, id: id) { [weak self] reply in
            guard reply.contains("\"error\"") else { return }
            MainActor.assumeIsolated {
                self?.report(failure: reply, for: command)
            }
        }
    }

    /// Switches the sidebar between machines and agents.
    @objc private func toggleArrangement(_ sender: Any?) {
        let next: SidebarView.Arrangement =
            preferences.sidebarArrangement == SidebarView.Arrangement.priority.rawValue
            ? .spaces : .priority
        preferences.sidebarArrangement = next.rawValue
        Preferences.current = preferences
        sidebar.show(arrangement: next)
        arrangementItem?.state = next == .priority ? .on : .off
        if let session { sidebar.update(endpoints: session.endpoints, active: session.activeEndpoint) }
    }

    /// Picks a theme, showing each one as the highlight passes over it.
    ///
    /// Applied on the way past rather than only on Return: a palette is a thing
    /// you judge by looking at it, and a list of names tells you nothing about
    /// which one you want.
    @objc private func showThemes(_ sender: Any?) {
        let installed = ThemeLibrary.installed()
        guard !installed.isEmpty else {
            offerToFetchThemes()
            return
        }
        let before = (preferences.themeName, preferences.themeColors)

        // Read up front so each row can say what it is. "kitty theme" on four
        // hundred rows says nothing, while light or dark is most of what
        // anyone is filtering for.
        let described = installed.map { entry -> Picker.Item in
            let theme = ThemeLibrary.theme(at: entry.url)
            let detail =
                theme.map { theme in
                    (theme.background.isDarkish ? "dark" : "light") + "  ·  "
                        + (Preferences.encode(theme.background) ?? "")
                } ?? "unreadable"
            return Picker.Item(title: entry.name, detail: detail) { [weak self] in
                guard let self, let theme else { return }
                // Applied here as well as on highlight: what is on screen is a
                // preview, and a preview is not what was chosen.
                self.preview(theme: theme, named: entry.name)
            }
        }

        themePicker.show(
            over: window, title: "Themes",
            items: described,
            // Floating rather than a sheet: the window behind a sheet is
            // blurred, and a blurred terminal is the one thing that cannot
            // show what a palette does.
            as: .floating,
            onHighlight: { [weak self] item in
                guard let self,
                    let entry = installed.first(where: { $0.name == item.title }),
                    let theme = ThemeLibrary.theme(at: entry.url)
                else { return }
                self.preview(theme: theme, named: entry.name)
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.preferences.themeName = before.0
                self.preferences.themeColors = before.1
                self.commitTheme()
            })
    }

    /// Shows a theme without keeping it, so moving off it puts things back.
    private func preview(theme: Theme, named name: String) {
        preferences.themeName = name
        preferences.themeColors = theme.hexComponents
        // A loaded palette and the two overrides cannot both win, and the
        // overrides would repaint two of the twenty colours being looked at.
        preferences.background = nil
        preferences.foreground = nil
        commitTheme()
    }

    private func commitTheme() {
        Preferences.current = preferences
        applyTheme()
        // Settings may be open beside the picker, and it reads the theme's name
        // and colours out of the same settings.
        preferencesWindow?.refresh()
    }

    /// Offers to fetch the collection, saying where it comes from.
    private func offerToFetchThemes() {
        let alert = NSAlert()
        alert.messageText = "Get colour themes?"
        alert.informativeText =
            "HerdX will download kitty's theme collection — a few hundred palettes — "
            + "from github.com/kovidgoyal/kitty-themes, and keep them in "
            + "Application Support. Nothing is sent."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        notice("fetching themes…")
        ThemeLibrary.fetch { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch result {
                case .success(let count):
                    self.notice("\(count) themes ready")
                    self.showThemes(nil)
                case .failure(let error):
                    let failed = NSAlert()
                    failed.messageText = "The themes could not be downloaded"
                    failed.informativeText = error.reason
                    failed.runModal()
                }
            }
        }
    }

    @objc private func showMachines(_ sender: Any?) {
        machinesWindow.present()
    }

    /// Remembers the colours when they are not the ones we asked for.
    ///
    /// A surface painted in colours we did not publish was composed against
    /// another client's host theme, so those are its colours.
    private func noteAttachedTerminal() {
        // Every pane, not the dominant one: a host theme colours the whole
        // session at once, while a program with its own palette colours only
        // the pane it runs in.
        guard let background = gridView.uniformBackground,
            let foreground = gridView.dominantForeground
        else { return }
        let ours = Chrome(theme: terminalTheme, background: nil)
        guard background.isNoticeablyDifferent(from: ours.content) else {
            return
        }
        attachedTerminal = (background, foreground)
    }

    /// Picks up machines added or removed outside this window.
    ///
    /// The catalog is shared: herdr's own TUI edits it, and so does the setup
    /// command HerdX runs in a pane, which finishes long after the click that
    /// started it. Neither can tell us, so the file is watched.
    ///
    /// Once a second rather than every frame — it is a file read, and a list of
    /// machines does not change at sixty hertz.
    private func watchMachines() {
        ticks += 1
        guard ticks % 60 == 0 else { return }
        let current = Machines.all()
            .map { "\($0.id):\($0.label):\($0.target):\($0.session):\($0.enabled)" }
            .joined(separator: "|")
        guard let previous = knownMachines else {
            knownMachines = current
            return
        }
        guard previous != current else { return }
        knownMachines = current
        reattach()
    }

    /// Offers to set herdr up on a machine that answered without it.
    ///
    /// Once per machine, because an endpoint retries on a backoff and an offer
    /// that returned every few seconds would be a fault of its own. Declining
    /// leaves the row saying what is wrong, and the Machines window still
    /// offers it.
    private func offerInstallIfNeeded(_ session: HerdrSession) {
        // Nothing can answer a modal in a window that was never shown.
        guard !AppDelegate.isHeadless else { return }
        for endpoint in session.endpoints
        where endpoint.needsInstall && !offeredInstall.contains(endpoint.id) {
            offeredInstall.insert(endpoint.id)
            guard let machine = Machines.all().first(where: { $0.id == endpoint.id })
            else { continue }

            let alert = NSAlert()
            alert.messageText = "Set herdr up on “\(endpoint.label)”?"
            alert.informativeText =
                "\(machine.target) is reachable but has no herdr installed, so "
                + "HerdX cannot attach to it.\n\nHerdX will open a terminal running "
                + "herdr's own setup, which downloads the build matching that machine "
                + "and asks you to confirm before changing anything."
            alert.addButton(withTitle: "Open Terminal")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn {
                installHerdr(on: machine)
            }
        }
    }

    /// Opens a local tab running herdr's own remote installer.
    ///
    /// A pane rather than a background command: herdr refuses to install
    /// unless stdin is a terminal, because approving a binary onto another
    /// machine is a decision it wants a person to make. A pane is a terminal,
    /// so its prompt arrives where you can answer it.
    private func installHerdr(on machine: Machines.Machine) {
        guard let session,
            let local = session.endpoints.first(where: { !$0.isRemote && $0.status == .online })
        else {
            // The installer is herdr's, and it runs in a herdr pane. Without a
            // local server there is neither, and saying "no local server" to
            // someone who has never installed herdr explains nothing.
            let alert = NSAlert()
            switch LocalHerdr.state(serverIsUp: false) {
            case .missing:
                alert.messageText = "herdr is not installed on this Mac"
                alert.informativeText =
                    "HerdX is a client for herdr, and sets up other machines by running "
                    + "herdr's own installer here. Install it first:\n\n"
                    + LocalHerdr.installCommand
            case .installed, .running:
                alert.messageText = "herdr is not running on this Mac"
                alert.informativeText =
                    "The installer runs in a herdr terminal. Run  herdr  to start a "
                    + "session, then try again."
            }
            alert.runModal()
            return
        }
        focus(.newTab, on: local.index)

        // The pane does not exist until the server has made it and said so, so
        // the command waits for the snapshot rather than a guess at how long
        // that takes.
        waitForNewPane(session: session, tries: 40) { [weak self] pane in
            guard let self else { return }
            guard let pane else {
                self.notice("could not open a terminal for the installer")
                return
            }
            session.send(text: Self.setupCommand(for: machine) + "\n", to: pane)
        }
    }

    /// Calls back with the focused pane once it changes, or nil if it does not.
    private func waitForNewPane(
        session: HerdrSession, tries: Int, then act: @escaping (String?) -> Void
    ) {
        let before = session.lastSnapshot?.focusedPaneID
        var remaining = tries
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated {
                    let now = session.lastSnapshot?.focusedPaneID
                    if let now, now != before {
                        act(now)
                        return
                    }
                    remaining -= 1
                    if remaining <= 0 { act(nil) } else { poll() }
                }
            }
        }
        poll()
    }

    /// What to run to set a machine up.
    ///
    /// `herdr machine add` prepares the remote and saves the machine itself,
    /// and unlike `herdr --remote` it does not go on to attach a TUI — which a
    /// pane is already inside, and which herdr refuses to nest. Subcommands are
    /// exempt from that guard; the TUI is what it stops.
    ///
    /// It has no idea the machine is already saved and would simply add a
    /// second copy, so the old row is removed after. Chained with `&&` because
    /// `add` writes nothing until the remote is prepared: decline the install
    /// and the machine is left exactly as it was.
    private static func setupCommand(for machine: Machines.Machine) -> String {
        var add = "herdr machine add --label \(shellQuoted(machine.label))"
        if machine.session != "default" {
            add += " --remote-session \(shellQuoted(machine.session))"
        }
        add += " \(shellQuoted(machine.target))"
        return add + " && herdr machine remove \(shellQuoted(machine.id))"
    }

    /// Single-quoted for the shell the pane is running.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Rebuilds the session from scratch.
    ///
    /// Both the socket and the list of endpoints are resolved once, when the
    /// session is created, so neither a machine added to the catalog nor a
    /// different herdr session is something a live session can be told about —
    /// it has to be stood up again.
    private func reattach() {
        gridView.forgetSurface()
        gridView.session = nil
        session = nil
        themedEndpoints = []
        publishedTheme = nil
        knownMachines = nil
        if !connect() {
            statusTitle = "waiting for herdr… (\(lastConnectError ?? "no server"))"
            reconnect()
        }
        applyTitle()
    }

    @objc private func findInPane(_ sender: Any?) {
        gridView.enterCopyMode(searching: true)
        window.makeFirstResponder(gridView)
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let session, let command = Command.allByTag[sender.tag] else { return }
        invoke(command, session: session)
    }

    /// Hands the keyboard back to the terminal, abandoning a half-entered
    /// chord.
    ///
    /// Every pointing gesture that changes what has focus goes through here:
    /// the prefix was aimed at the pane you were in when you pressed it, so
    /// carrying it across to a new pane, tab or machine would fire the chord
    /// somewhere you never pointed it.
    private func focusTerminal() {
        chords.reset()
        gridView.prefixArmed = false
        window.makeFirstResponder(gridView)
    }

    /// Collapses the sidebar out of the split, rather than hiding its contents
    /// and leaving the space it was occupying behind.
    private func toggleSidebar() {
        guard let split = windowSplit else { return }
        if split.isSubviewCollapsed(sidebar) {
            split.setPosition(sidebarWidth, ofDividerAt: 0)
        } else {
            // Remembered, so bringing it back does not forget a width that was
            // dragged to deliberately.
            sidebarWidth = max(sidebar.frame.width, SidebarView.minimumWidth)
            split.setPosition(0, ofDividerAt: 0)
        }
        split.layoutSubtreeIfNeeded()
        // The terminal just changed width by a couple of hundred points, and
        // the server composes to the size it was last told.
        gridView.reportGridSize()
        copyModeStatus.reposition()
    }

    /// Which subview the split may collapse. Without this `setPosition(0, …)`
    /// is clamped by the minimum width and the sidebar merely gets narrow.
    func splitView(_ splitView: NSSplitView, canCollapseSubview view: NSView) -> Bool {
        view is SidebarView
    }

    /// How far the sidebar may be dragged. Without these the split view lets
    /// it be squeezed to nothing or dragged over the whole window.
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat,
        ofSubviewAt index: Int
    ) -> CGFloat {
        index == 0 ? SidebarView.minimumWidth : proposed
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat,
        ofSubviewAt index: Int
    ) -> CGFloat {
        index == 0 ? min(SidebarView.maximumWidth, proposed) : proposed
    }

    /// The terminal takes the slack when the window resizes; the sidebar keeps
    /// whatever width it was dragged to.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        !(view is SidebarView)
    }

    /// herdr only takes the host theme from the client it considers foreground,
    /// and a client is promoted when it says it has focus. Without this, HerdX
    /// was promoted only as a side effect of typing — so changing a theme
    /// without typing first did nothing at all.
    ///
    /// Application level rather than window level: opening a sheet takes key
    /// away from the window, and a theme picker that told the server it had
    /// stopped looking would be unable to show anything.
    func applicationDidBecomeActive(_ notification: Notification) {
        session?.setFocused(true)
    }

    func applicationWillResignActive(_ notification: Notification) {
        session?.setFocused(false)
    }

    func windowDidResize(_ notification: Notification) { copyModeStatus.reposition() }
    func windowDidMove(_ notification: Notification) { copyModeStatus.reposition() }

    /// Disarms a half-entered chord when the window stops listening.
    ///
    /// The prefix consumes the next keystroke wherever it arrives. Left armed
    /// across a trip to another app, it eats the first key typed on the way
    /// back, which reads as the keyboard having stopped working.
    func windowDidResignKey(_ notification: Notification) {
        chords.reset()
        gridView.prefixArmed = false
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(
            title: "Settings…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        // herdr has no binding for this — it is a config setting there — so
        // this is HerdX's own, and it goes in the menu rather than into a
        // keymap read from the server.
        let agents = NSMenuItem(
            title: "Sort Sidebar by Agent", action: #selector(toggleArrangement(_:)),
            keyEquivalent: "a")
        agents.keyEquivalentModifierMask = [.command, .option]
        agents.target = self
        arrangementItem = agents
        appMenu.addItem(agents)
        appMenu.addItem(.separator())

        let themes = NSMenuItem(
            title: "Themes…", action: #selector(showThemes(_:)), keyEquivalent: "t")
        themes.keyEquivalentModifierMask = [.command, .option]
        themes.target = self
        appMenu.addItem(themes)
        let machines = NSMenuItem(
            title: "Machines…", action: #selector(showMachines(_:)), keyEquivalent: "m")
        machines.keyEquivalentModifierMask = [.command, .shift]
        machines.target = self
        appMenu.addItem(machines)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit HerdX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let sessionItem = NSMenuItem()
        sessionMenu.delegate = self
        // The delegate decides what is enabled; left to AppKit, every item with
        // no responder in the chain would be greyed out.
        sessionMenu.autoenablesItems = false
        sessionItem.submenu = sessionMenu
        main.addItem(sessionItem)

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

    /// Dev affordance: `HERDX_PROBE_INPUT=<text>` reports the input state and
    /// then types that text, so the AppKit half of the keyboard path can be
    /// tested without a human at the keyboard.
    ///
    /// Point it at a throwaway session with `HERDR_CLIENT_SOCKET_PATH`; it
    /// types into whatever pane is focused.
    private func installInputProbeIfRequested() {
        guard let probe = ProcessInfo.processInfo.environment["HERDX_PROBE_INPUT"] else { return }
        let delay = ProcessInfo.processInfo.environment["HERDX_PROBE_DELAY"]
            .flatMap(Double.init) ?? 6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                print("probe: window.isKeyWindow=\(self.window.isKeyWindow)")
                print("probe: firstResponder=\(String(describing: self.window.firstResponder))")
                print("probe: gridView.acceptsFirstResponder=\(self.gridView.acceptsFirstResponder)")
                print("probe: gridView.session=\(self.gridView.session != nil)")
                print("probe: focusedPaneFromSnapshot=\(self.gridView.focusedPaneFromSnapshot ?? "nil")")
                print("probe: focusedPane=\(self.gridView.focusedPane ?? "nil")")
                print("probe: panes=\(self.gridView.panes.map(\.id))")
                print("probe: cellSize=\(self.gridView.cellSize) grid=\(self.gridView.gridSize)")
                let first = self.sidebar.rebuilds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MainActor.assumeIsolated {
                        print("probe: sidebar rebuilds in 3s=\(self.sidebar.rebuilds - first)")
                    }
                }
                if ProcessInfo.processInfo.environment["HERDX_PROBE_RESIZE"] != nil {
                    self.enterResizeMode()
                    print("probe: parent frame=\(self.window.frame)")
                    print("probe: strip \(self.copyModeStatus.describeFrame())")
                }
                // Runs real commands against whatever session is attached and
                // reports what the server made of them. Point it at a
                // throwaway session: it creates and closes tabs.
                if ProcessInfo.processInfo.environment["HERDX_PROBE_COMMANDS"] != nil,
                    let session = self.session
                {
                    print("probe: panes=\(session.lastSnapshot?.panes.count ?? 0)")
                    self.invoke(.splitRight, session: session)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        MainActor.assumeIsolated {
                            print("probe: after split panes=\(session.lastSnapshot?.panes.count ?? 0)")
                            self.invoke(.zoomPane, session: session)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                MainActor.assumeIsolated {
                                    let after = session.lastSnapshot
                                    print("probe: zoomed=\(after?.tabs.first?.zoomed ?? false) surfacePanes=\(self.gridView.panes.count)")
                                    print("probe: labels=\(self.gridView.paneLabels)")
                                    self.invoke(.closePane, session: session)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        MainActor.assumeIsolated {
                                            print("probe: cleaned panes=\(session.lastSnapshot?.panes.count ?? 0)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if ProcessInfo.processInfo.environment["HERDX_PROBE_CHORDS"] != nil {
                    self.reportUnreachableChords()
                }

                // Give the keys time to reach the server, then leave: a probe
                // that never exits leaves its output stuck in a pipe buffer.
                // A capture hook, when there is one, needs the app to outlive
                // the probe so it can photograph what the probe set up.
                guard self.capturePath == nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    fflush(stdout)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func installCaptureHookIfRequested() {
        guard let path = capturePath else { return }
        let delay = ProcessInfo.processInfo.environment["HERDX_CAPTURE_DELAY"]
            .flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
            guard let self else { NSApp.terminate(nil); return }

            // `HERDX_CAPTURE_SETTINGS` and `HERDX_CAPTURE_HELP` shoot those
            // windows instead of the main one, which is otherwise impossible to
            // see headlessly.
            let environment = ProcessInfo.processInfo.environment
            let settings = environment["HERDX_CAPTURE_SETTINGS"] != nil
            let machinesWanted = environment["HERDX_CAPTURE_MACHINES"] != nil
            let themesWanted = environment["HERDX_CAPTURE_THEMES"] != nil
            if themesWanted { self.showThemes(nil) }
            if machinesWanted {
                self.showMachines(nil)
                if environment["HERDX_CAPTURE_MACHINES"] == "add" {
                    self.machinesWindow.beginAdd()
                }
            }
            // The value names any action, so a sheet other than help can be
            // photographed too.
            let sheetAction = environment["HERDX_CAPTURE_HELP"]
                .flatMap { Keymap.Action(rawValue: $0) ?? .help }
            let helpWanted = sheetAction != nil
            if settings { self.showPreferences(nil) }
            if let sheetAction, let session = self.session {
                self.perform(sheetAction, session: session)
            }
            let target: NSView? =
                themesWanted
                ? self.themePicker.presented?.contentView
                : machinesWanted
                ? (self.machinesWindow.window?.attachedSheet?.contentView
                    ?? self.machinesWindow.window?.contentView)
                : settings
                ? self.preferencesWindow?.window?.contentView
                : (helpWanted
                    ? self.window.attachedSheet?.contentView : self.window.contentView)
            guard let view = target
            else {
                NSApp.terminate(nil)
                return
            }
            self.gridView.refreshIfNeeded()
            view.layoutSubtreeIfNeeded()
            self.gridView.displayIfNeeded()
            let composited = environment["HERDX_CAPTURE_COMPOSITED"] != nil
            let rep = composited ? self.composited() : self.snapshot(of: view)
            if let data = rep?.representation(using: .png, properties: [:])
            {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            // A sheet holds terminate off until it closes, so the capture would
            // write its file and then hang forever.
            if let sheet = self.window.attachedSheet { self.window.endSheet(sheet) }
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
    /// The window as the compositor actually draws it.
    ///
    /// `cacheDisplay` walks subviews and draws them in order; a real window
    /// composites layers, and the two disagree about anything whose visibility
    /// depends on layer order. This asks the window server for our own window
    /// and nothing else, so it cannot catch anything else on the display.
    private func composited() -> NSBitmapImageRep? {
        guard
            let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                [.boundsIgnoreFraming, .bestResolution])
        else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

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
