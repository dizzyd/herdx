import AppKit

/// HerdX: a native macOS client for herdr.
///
/// The server owns terminal emulation and sends composed cell grids plus a
/// structured description of the workspace tree, so this app is a renderer and
/// an input source, not a terminal emulator.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSSplitViewDelegate,
    NSMenuDelegate, NSMenuItemValidation
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
    /// The theme under the highlight in the theme list, shown whatever the
    /// appearance.
    ///
    /// Choosing the dark theme while the system is light would otherwise
    /// preview nothing: the slot being changed is not the one on screen.
    private var previewTheme: Theme?
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
    /// Whether this run may still start a herdr server.
    ///
    /// Spent by starting one — the point is to save someone a trip to a
    /// terminal, not to keep putting one back — and spent just as surely by
    /// Stop Session, which is someone saying they want it stopped. Without that
    /// second half, stopping a server this app did not start put it straight
    /// back a sixtieth of a second later, because the flag had never been set.
    private var mayStartLocalHerdr = true
    /// Likewise for the offer to install herdr here, which is a dialog and can
    /// only be shown once without becoming something to fight with. Distinct
    /// from `offeredInstall`, which is about herdr on other machines.
    private var offeredLocalInstall = false

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
    private let hibernator = Hibernator()
    private var workspaceActivity = WorkspaceActivity()
    private var sweepTimer: Timer?
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

        sidebar.onSelectHibernated = { [weak self] id, _ in
            self?.revive(id)
        }
        sidebar.onSelectEndpoint = { [weak self] index in
            guard let self, let session = self.session else { return }
            self.switchTo(endpoint: index, session: session)
            self.focusTerminal()
        }

        window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: CGFloat(cols) * cell.width + SidebarView.width,
                height: CGFloat(rows) * cell.height),
            // Not `.fullSizeContentView`, though it is half of the look the
            // transparent title bar below is after: drawing under the title
            // bar means every view beneath it needs safe-area insets, and that
            // inset shifted the terminal's dirty rect by exactly the title
            // bar's height, so it never painted at all.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "HerdX"
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.center()
        // A transparent title bar takes the window's background colour, which
        // is what carries the chrome up over the traffic lights.
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
            gridView.placeholder = herdrExplanation ?? "waiting for herdr…"
            applyTitle()
            if !startLocalHerdr() { reconnect() }
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
        installLockProbeIfRequested()
        installWakeObserver()
        installWakeProbeIfRequested()
        installWorktreeProbeIfRequested()
        checkForUpdate()
        // Its own slow timer, not the sixty-a-second one: this asks a server
        // several questions and nothing it looks at changes in under an hour.
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepForHibernation() }
        }

        // A display-linked repaint would be tighter, but the core only bumps a
        // revision when a surface actually lands, so a cheap tick is enough.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private var workspaceTitle: String?

    /// Why nothing is answering, or nil when herdr is fine and the silence is
    /// something else.
    ///
    /// Split out because the same situations arrive by two routes, and only one
    /// of them was covered. A session whose local endpoint goes quiet gets this
    /// through `updatePlaceholder` — but someone with no herdr at all never has
    /// a session for that to run on, so the terminal stayed blank and the whole
    /// story was a window subtitle reading "waiting for herdr… (no server)".
    /// That is the one person who most needs telling.
    private var herdrExplanation: String? {
        switch LocalHerdr.state(serverIsUp: false) {
        case .missing:
            return "HerdX is a client for herdr, which is not installed.\n\n"
                + LocalHerdr.installCommand
                + "\n\nHelp ▸ Install herdr… will copy that line for you."
        case .installed:
            return "herdr is installed but not running.\n\n"
                + "Session ▸ New Session… will start one."
        case .running:
            return nil
        }
    }

    /// What to do about a local machine that is not answering: start the server
    /// if herdr is here, and offer to fetch it if it is not.
    ///
    /// One door for both, because both are answers to the same fact and neither
    /// could hang off the thing that looks like it — see the caller.
    /// Dev affordance: `HERDX_CAPTURE_INSTALL=1` puts the first-run dialog up on
    /// a Mac that has herdr, which otherwise never reaches it.
    ///
    /// Through the same tick the real thing comes through, so what this puts on
    /// screen is the dialog rather than a second one built beside it.
    ///
    /// What a capture gets back differs by macOS, which is worth knowing before
    /// deciding the dialog is broken: the macOS 15 guest in `scripts/vm.sh`
    /// renders the whole alert, and macOS 26 renders only the command field.
    /// `cacheDisplay` walks subviews, and an alert whose furniture is layer
    /// backed leaves it nothing to walk. Raising it at launch, from a tick, and
    /// after a run loop spin all came back byte for byte identical. The field is
    /// the part this app owns, so the flag still answers what it is for.
    static var pretendsHerdrIsMissing: Bool {
        ProcessInfo.processInfo.environment["HERDX_CAPTURE_INSTALL"] != nil
    }

    private func answerForMissingHerdr() {
        if AppDelegate.pretendsHerdrIsMissing {
            guard !offeredLocalInstall else { return }
            offeredLocalInstall = true
            LocalHerdr.offerInstall(over: window)
            return
        }
        switch LocalHerdr.state(serverIsUp: false) {
        case .missing:
            guard !offeredLocalInstall else { return }
            offeredLocalInstall = true
            // Headless runs are allowed this one: a window that is never
            // ordered in cannot put a sheet on anybody's screen, and it is the
            // only way to photograph a dialog that a Mac with herdr on it never
            // reaches. The capture hook ends the sheet so terminate is not held.
            LocalHerdr.offerInstall(over: window)
        case .installed:
            startLocalHerdr()
        case .running:
            break
        }
    }

    /// Starts herdr on this Mac, rather than asking for it to be started
    /// somewhere else.
    ///
    /// This app is a client, but "herdr is installed but not running — go and
    /// run it in another terminal" is a strange thing for a Mac app to say
    /// about a program it can start itself, and it was the first thing anyone
    /// saw. herdr's own default session, named by herdr rather than guessed
    /// here; the server keeps running afterwards, which is the point of herdr
    /// and is what a session started any other way does too.
    ///
    /// Returns false when it did not try, so the caller can fall back to
    /// waiting. Three reasons not to: there is nothing to start, the run is a
    /// capture or a probe — spawning a server from a screenshot is the kind of
    /// side effect nobody goes looking for — or the environment named a socket,
    /// which means a test run aimed somewhere deliberate, and answering it with
    /// the *default* session would be aiming somewhere else entirely.
    @discardableResult
    private func startLocalHerdr() -> Bool {
        let named = AppDelegate.namedSession
        // The session the window is on, not herdr's default: a window aimed at
        // a named session that is not running wants *that* server, and starting
        // the default one would leave it looking at the same dead socket.
        let wanted = sessionTitle ?? named
        guard mayStartLocalHerdr,
            case .installed = LocalHerdr.state(serverIsUp: false),
            // A named session is a developer asking for this on purpose, and is
            // the only way to watch it happen; otherwise a headless run or one
            // aimed at a socket keeps its hands to itself.
            named != nil || (!AppDelegate.isHeadless && !SessionCatalog.environmentPicksSocket),
            wanted.map(SessionCatalog.start) ?? SessionCatalog.startDefault()
        else { return false }
        mayStartLocalHerdr = false
        statusTitle = "starting herdr…"
        gridView.placeholder = "starting herdr…"
        applyTitle()
        waitForLocalHerdr(until: Date().addingTimeInterval(10))
        return true
    }

    /// Waits for the server just launched to start listening, then hands over
    /// to the ordinary wait, which puts the first workspace in an empty session
    /// and attaches the window to it.
    private func waitForLocalHerdr(until deadline: Date) {
        let name = sessionTitle ?? AppDelegate.namedSession
        let isTheOne: (SessionEntry) -> Bool = { entry in
            entry.running && (name.map { entry.name == $0 } ?? entry.isDefault)
        }
        if let entry = SessionCatalog.list().first(where: isTheOne) {
            waitForSession(named: entry.name, until: deadline)
            return
        }
        guard Date() < deadline else {
            // Back to waiting rather than an alert: the window already says
            // what is wrong, and a server may yet arrive from somewhere else.
            statusTitle = "herdr did not start"
            gridView.placeholder = herdrExplanation ?? "waiting for herdr…"
            applyTitle()
            reconnect()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.waitForLocalHerdr(until: deadline) }
        }
    }

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
            gridView.placeholder =
                herdrExplanation ?? active.error ?? "\(active.label) is offline"
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
        terminalTheme = previewTheme ?? preferences.terminalTheme(matching: systemIsDark)

        gridView.theme = terminalTheme
        gridView.apply(
            panePadding: preferences.panePadding, labelSize: preferences.paneLabelSize)

        applyChrome()
        publish(theme: terminalTheme)
    }

    /// Builds the window's chrome from the terminal theme.
    private func applyChrome() {
        let palette = Chrome(theme: terminalTheme)
        gridView.chrome = palette
        gridView.needsDisplay = true
        // The title bar is transparent, so the window's own colour is what
        // shows above the sidebar and tabs.
        window.backgroundColor = palette.surface
        // And the title, the traffic lights and everything else AppKit draws up
        // there sits on that colour, so it has to be told what the colour is.
        // Taken from the chrome rather than the system: a dark theme under a
        // light system appearance otherwise put a black title on a dark bar.
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
    /// every time that changes. Publishing is what lets the two agree; giving both
    /// the same theme is what makes them agree on the same thing.
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
            preferencesWindow = PreferencesWindowController(
                onChange: { [weak self] updated in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.preferences = updated
                        self.agentSounds.isEnabled = updated.agentSounds
                        self.gridView.apply(
                            font: updated.font, lineHeight: updated.lineHeight)
                        self.applyTheme()
                    }
                },
                onChooseTheme: { [weak self] slot in
                    MainActor.assumeIsolated { self?.showThemes(for: slot) }
                })
        }
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
    /// Dev affordance: `HERDX_SESSION=<name>` aims one run at a named session,
    /// running or not, without writing the choice into settings.
    ///
    /// The twin of `HERDX_ENDPOINT`, and the only way to watch this window
    /// start a server: the real path starts herdr's *default* session, which on
    /// any Mac that has one is the session the developer is sitting in.
    private static var namedSession: String? {
        ProcessInfo.processInfo.environment["HERDX_SESSION"]
    }

    private func resolvedSession() -> (name: String?, socket: String?) {
        let sessions = SessionCatalog.list()
        if let named = AppDelegate.namedSession {
            // Its own socket, which herdr lists for a stopped session as well as
            // a running one. A name herdr has never heard of has no socket here
            // at all, and `connect` refuses rather than passing nil on — nil
            // means "the one the core would pick", which is the real session
            // this exists to stay away from.
            return (named, sessions.first { $0.name == named }?.clientSocket)
        }
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
        // A run the environment aimed keeps its aim to itself, exactly as
        // `resolvedSession` ignores the saved name for one. Otherwise a probe
        // would leave the real app pointed at a throwaway session.
        if AppDelegate.namedSession == nil {
            preferences.sessionName = name
            Preferences.current = preferences
        }
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
            // The same offer as the first run makes, rather than the command as
            // text in an alert nobody can copy from.
            LocalHerdr.offerInstall(over: window)
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
        // Asked for, so not undone: the window is about to find a local endpoint
        // that will not come up, which is the same thing it starts a server for.
        mayStartLocalHerdr = false
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
        // A run aimed at a session by name connects to that session or to
        // nothing. herdr lists a session it knows about whether or not it is
        // running, so no socket here means no such session — and handing the
        // core a nil socket would aim this run at whichever session it would
        // have picked, which is the developer's own. It would attach, publish a
        // theme and resize the surface, all under the throwaway name.
        //
        // Returning false is not the end of it: the caller starts the session
        // that was asked for and comes back, which is also what makes
        // `HERDX_SESSION` work for a name that has never been used.
        if AppDelegate.namedSession != nil, chosen.socket == nil {
            lastConnectError = "no session named “\(chosen.name ?? "")” yet"
            return false
        }
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
        workspaceActivity.forget()
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
            // Answered even when there is nothing to ask: motions are run one
            // at a time, each from where the last one landed, so a request
            // that never calls back would stop every later one.
            guard let session, let snapshot = session.lastSnapshot else { return reply("") }
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

    /// Dev affordance: `HERDX_PROBE_WAKE=1` posts the wake notification and
    /// reports what the endpoints made of it.
    ///
    /// A real wake needs a real sleep, which is not something a test run can
    /// arrange, so this exercises the half that is in this app: that the
    /// observer is installed, that it reaches the core, and that the policy
    /// picks the remote machines and leaves a local one alone. What the core
    /// then does with a nudged connection is measured in `session_wake.rs`,
    /// against a server rather than against this app's opinion of one.
    ///
    /// Statuses are printed before and after, because "it asked" is checking
    /// your own homework — the transition is the answer.
    private func installWakeProbeIfRequested() {
        guard ProcessInfo.processInfo.environment["HERDX_PROBE_WAKE"] != nil else { return }
        let delay = ProcessInfo.processInfo.environment["HERDX_PROBE_DELAY"]
            .flatMap(Double.init) ?? 6
        func report(_ when: String) {
            for endpoint in session?.endpoints ?? [] {
                print(
                    "probe: \(when) \(endpoint.label) remote=\(endpoint.isRemote)"
                        + " status=\(endpoint.status)"
                        + " attachments=\(endpoint.attachments)"
                        + (endpoint.error.map { " error=\($0)" } ?? ""))
            }
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                report("before")
                // Counted here as well as reported by the core, because the
                // two answer different questions and only one of them is
                // always available. This says the observer fired and which
                // endpoints the policy picked; the attachment numbers either
                // side say whether the reconnect then landed, which a machine
                // that cannot be reached at all will never show.
                let asked = self.session?.reattachRemotes() ?? 0
                NSWorkspace.shared.notificationCenter.post(
                    name: NSWorkspace.didWakeNotification, object: nil)
                print("probe: posted didWake; the policy picks \(asked) endpoints")
                fflush(stdout)
                for seconds in [1.0, 3.0, 6.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                        MainActor.assumeIsolated {
                            report("t+\(Int(seconds))s")
                            if seconds == 6.0 {
                                print("probe: done")
                                fflush(stdout)
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Reattaches the remote machines the moment the Mac wakes.
    ///
    /// Waking is the one moment when a connection's staleness is known rather
    /// than waited for, and this is the only place that hears about it — hence
    /// an observer here and not a timer anywhere. Everything else belongs to
    /// the core: `hx_reattach_remotes` decides which endpoints it applies to,
    /// and `ARCHITECTURE.md` says why the alternative is no good.
    private func installWakeObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.session?.reattachRemotes() }
        }
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
                    // A server this window started of its own accord may have
                    // arrived while this was waiting; connecting a second time
                    // would drop the session that is already up.
                    if self.session != nil {
                        self.reconnecting = false
                        return
                    }
                    if self.connect() {
                        self.reconnecting = false
                        self.window.makeFirstResponder(self.gridView)
                        return
                    }
                    // herdr may have been installed since the window opened, in
                    // which case there is now something here to start.
                    self.startLocalHerdr()
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
            let watching = NSApp.isActive && endpoint.index == session.activeEndpoint
            agentPriority.observe(
                snapshot: snapshot, endpoint: endpoint.index, watching: watching)
            workspaceActivity.observe(
                snapshot: snapshot, endpoint: endpoint.index, watching: watching)
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

        watchMachines()
        offerInstallIfNeeded(session)
        sidebar.update(
            endpoints: session.endpoints, active: session.activeEndpoint,
            hibernated: hibernator.records)
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
        // A herdr that is neither installed nor running does not look like a
        // failure to connect: the core makes a session either way and
        // reconnects endpoints on its own, so what it looks like is a local
        // endpoint that never comes up. Both answers hang off that one fact,
        // and hanging either off the connection meant it never fired at all.
        // The flags are checked first because this runs sixty times a second.
        if mayStartLocalHerdr || !offeredLocalInstall,
            AppDelegate.pretendsHerdrIsMissing
                || session.endpoints.first(where: { !$0.isRemote })?.status == .offline
        {
            answerForMissingHerdr()
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
            // A local monitor is called for every key this application gets,
            // including the ones meant for Settings, the Machines sheet and
            // every text field in them. Without this, `⌃b x` typed while
            // renaming a tab closed a pane instead of typing an x — and resize
            // mode, below, swallowed arrow keys in those fields too.
            guard
                KeyRouting.belongsToTerminal(
                    event: event.window, terminal: self.window,
                    firstResponder: self.window.firstResponder, terminalView: self.gridView)
            else { return event }
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
        case .hibernateWorkspace:
            return { self.invoke(.hibernateWorkspace, session: session) }
        case .newLocalWorkspace:
            // Named rather than assumed: the whole point of the key is which
            // machine the workspace lands on, so it goes through `focus`,
            // which switches first and carries that machine's boot id.
            guard let local = session.localEndpoint else {
                // Offline is a different thing from unbound, and the generic
                // "not in HerdX yet" would send someone looking in the wrong
                // place entirely.
                return { self.notice("no herdr server on this Mac") }
            }
            return { self.focus(.newWorkspace, on: local.index) }
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

        // All three are offered whatever the focused workspace is. Whether an
        // action applies to it is a question with a useful answer — "start from
        // the parent", "this is not a worktree" — and returning nil here would
        // replace that answer with "not in HerdX yet".
        case .newWorktree: return { self.newWorktree(session: session) }
        case .openWorktree: return { self.openWorktree(session: session) }
        case .removeWorktree: return { self.removeWorktree(session: session) }

        // Zero jumps to whatever most needs you; the other two cycle. All three
        // walk the same order the Agents sidebar is in, so the key and the list
        // cannot disagree about what "next" means.
        case .focusAbove: return { self.stepUpOrDown(by: -1, session: session) }
        case .focusBelow: return { self.stepUpOrDown(by: 1, session: session) }

        case .focusTopAgent: return { self.focusAgent(by: 0, session: session) }
        case .nextAgent: return { self.focusAgent(by: 1, session: session) }
        case .previousAgent: return { self.focusAgent(by: -1, session: session) }

        default: return nil
        }
    }

    /// The up and down arrows, which belong to the panes when there are panes
    /// to move between and to the sidebar when there are not.
    ///
    /// A tab holding one pane has nothing above or below it, so the key would
    /// otherwise be dead — and dead in a way that looks like a broken keyboard
    /// rather than like a key with nothing to do.
    private func stepUpOrDown(by offset: Int, session: HerdrSession) {
        if (session.lastSnapshot?.panesInFocusedTab ?? 0) > 1 {
            invoke(offset < 0 ? .focusUp : .focusDown, session: session)
            return
        }
        // Silent when there is nowhere to go: at the ends of the list the key
        // genuinely has nothing to do, and saying so every time would be noise
        // on a key that is held down.
        sidebar.step(by: offset)
    }

    /// Moves to another agent, in the order the Agents sidebar shows.
    ///
    /// Across every attached machine, not just the one on screen: an agent that
    /// needs you on another machine is the reason they are all attached, and a
    /// key that only reached the current one would step over it silently.
    ///
    /// herdr resolves these client-side too — there is no next-agent request to
    /// send, only `pane.focus` with an id worked out here.
    private func focusAgent(by offset: Int, session: HerdrSession) {
        let all = session.endpoints.flatMap { endpoint in
            (endpoint.snapshot?.agents ?? []).map { (endpoint, $0) }
        }
        let ordered = agentPriority.ordered(all, agent: { $0.1 }, endpoint: { $0.0.index })
        // By the pane the server says is focused rather than by the agent's own
        // `focused` flag: every machine has a focused pane of its own, so that
        // flag is true on all of them at once and the cursor would be found in
        // whichever list position came first.
        let here = session.activeEndpoint
        let focusedPane = session.lastSnapshot?.focusedPaneID
        let current = ordered.firstIndex {
            $0.0.index == here && $0.1.paneID == focusedPane
        }
        guard let next = AgentPriority.step(from: current, by: offset, count: ordered.count)
        else {
            notice("no agents")
            return
        }
        let (endpoint, agent) = ordered[next]
        focus(.focusPane(agent.paneID), on: endpoint.index)
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
        switchTo(endpoint: endpoint, session: session)
        invoke(command, session: session, bootID: session.bootID(forEndpoint: endpoint))
        focusTerminal()
    }

    /// Switches which machine the window is showing.
    ///
    /// One place, because the per-machine state has to move together: the
    /// transport, the snapshot commands are built from, and the pane input
    /// goes to. Doing two of the three left commands carrying the old
    /// machine's boot id and typing addressed to a pane id that names
    /// somebody else's work on the new server.
    private func switchTo(endpoint index: Int, session: HerdrSession) {
        guard index != session.activeEndpoint else { return }
        session.setActiveEndpoint(index)
        // The new machine's surface has not arrived; drop the old one so the
        // previous machine's output is not shown under a new name.
        gridView.forgetSurface()
        // Whatever the new machine last said, which may be nothing yet. The
        // next snapshot fills it in either way.
        gridView.focusedPaneFromSnapshot = session.lastSnapshot?.focusedPaneID
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

    /// Ends the focused workspace's processes, keeping enough to bring it back.
    ///
    /// Pressed rather than swept, so it does not wait for the idle clock — that
    /// is the point of having a key for it. Every other refusal still holds and
    /// is put on screen: a key that quietly ends a running build would be worse
    /// than no key at all, and "nothing happened" is the one answer that
    /// teaches you nothing.
    ///
    /// Local only. What this reads is outside the client shell's allow-list, so
    /// it goes over the local API socket, and a remote machine has none here.
    private func hibernateFocusedWorkspace(session: HerdrSession) {
        guard let local = session.localEndpoint, local.index == session.activeEndpoint else {
            notice("hibernating works on this Mac only, for now")
            return
        }
        guard let snapshot = session.lastSnapshot,
            let workspace = snapshot.workspaces.first(where: \.focused)
        else {
            notice("no workspace to hibernate")
            return
        }
        // Several round trips, so say something before the first one rather
        // than leaving the key looking dead.
        notice("hibernating \(workspace.label)…")
        hibernator.hibernate(
            workspace: workspace, in: snapshot, endpointID: local.id,
            socket: session.apiSocket
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let record):
                self.notice("hibernated \(record.label)")
            case .failure(let error):
                self.notice(Self.explain(error))
            }
        }
    }

    /// Ends the processes of one local workspace that has been quiet too long.
    ///
    /// One per sweep, quietest first. Hibernating several at once would take a
    /// machine apart in a single minute, and each is several round trips.
    ///
    /// Nothing is said when it works: the row appearing in the sidebar is the
    /// notification, and a notice that clears itself after two and a half
    /// seconds is no use for something that happens while you are elsewhere.
    /// Nothing is said when it declines either — most workspaces are in use,
    /// and that is not news. A refusal goes to stderr, where a question about
    /// why something did not hibernate can be answered.
    private func sweepForHibernation() {
        guard let after = hibernateAfter else { return }
        guard let session, let local = session.localEndpoint, let snapshot = local.snapshot
        else { return }

        let quietest = workspaceActivity.candidates(
            in: snapshot, on: local.index, after: after)
        guard let id = quietest.first,
            let workspace = snapshot.workspaces.first(where: { $0.workspaceID == id })
        else { return }

        hibernator.hibernate(
            workspace: workspace, in: snapshot, endpointID: local.id,
            socket: session.apiSocket
        ) { result in
            if case .failure(let error) = result {
                FileHandle.standardError.write(
                    Data("herdx: left \(workspace.label) alone: \(Self.explain(error))\n".utf8))
            }
        }
    }

    /// How long a workspace must be quiet before the sweep will end it.
    ///
    /// `HERDX_HIBERNATE_AFTER_SECONDS` is a dev affordance: the setting is in
    /// hours, which is right for the feature and impossible to wait for while
    /// testing it. It works whether or not the setting is on, because a run
    /// that sets it is asking for exactly this.
    private var hibernateAfter: TimeInterval? {
        if let named = ProcessInfo.processInfo.environment["HERDX_HIBERNATE_AFTER_SECONDS"],
            let seconds = TimeInterval(named)
        {
            return seconds
        }
        guard let hours = preferences.hibernateAfterHours, hours > 0 else { return nil }
        return TimeInterval(hours) * 3600
    }

    /// Brings a hibernated workspace back, and says how it went.
    ///
    /// Several round trips — the workspace, then each tab's layout, then an
    /// agent per pane once that pane has reached a prompt — so it says it has
    /// started rather than leaving the click looking ignored.
    private func revive(_ id: UUID) {
        guard let record = hibernator.records.first(where: { $0.id == id }) else { return }
        // The attached session, because the socket is derived from what this
        // window is actually on. Without one there is nothing to revive into.
        guard let session else {
            notice("no herdr to revive into")
            return
        }
        notice("reviving \(record.label)…")
        hibernator.revive(
            id, socket: session.apiSocket
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let record):
                self.notice("\(record.label) is back")
            case .failure(let error):
                self.notice(Self.explain(error))
            }
        }
    }

    /// Why a hibernation was declined, in the words of whichever part declined.
    private static func explain(_ error: Error) -> String {
        if let refusal = error as? HibernationPlan.Refusal { return refusal.reason }
        if let failure = error as? Revival.Failure { return failure.reason }
        if let failure = error as? LocalAPI.Failure { return failure.reason }
        if let failure = error as? Reply.Failure { return failure.text }
        return "\(error)"
    }

    /// Says that a command failed, and why herdr said it did.
    ///
    /// The whole reply goes to stderr and only the reason to the window: the
    /// notice is one line over somebody's terminal.
    private func report(_ rejection: Reply.Failure, reply: String, for command: Command) {
        FileHandle.standardError.write(Data("herdx: \(command.method) failed: \(reply)\n".utf8))
        notice("\(command.method) failed: \(rejection.text)")
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

    /// Dev affordance: `HERDX_PROBE_WORKTREE=<cwd>` runs the whole worktree
    /// round trip against a live server and reports what it made of it.
    ///
    /// Throwaway sessions and throwaway repos only — it creates a branch and a
    /// checkout and then deletes them.
    ///
    /// The sheets are what a person uses and what a probe cannot answer, so
    /// this drives the requests under them. The one thing it is really for is
    /// the path: `Worktrees.checkoutPath` promises one before anything exists,
    /// and the only way to know the promise is kept is to ask herdr where the
    /// checkout actually went. Unit vectors cannot answer that — they only say
    /// the port matches the copy of the rule that was copied.
    private func installWorktreeProbeIfRequested() {
        guard let cwd = ProcessInfo.processInfo.environment["HERDX_PROBE_WORKTREE"] else { return }
        let delay = ProcessInfo.processInfo.environment["HERDX_PROBE_DELAY"]
            .flatMap(Double.init) ?? 6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.runWorktreeProbe(in: cwd) }
        }
    }

    private func runWorktreeProbe(in cwd: String) {
        guard let session else { return print("probe: no session") }
        func say(_ text: String) {
            print("probe: \(text)")
            fflush(stdout)
        }
        func finish() {
            say("done")
            NSApp.terminate(nil)
        }

        guard let target = worktreeTarget(session: session) else {
            return say("no machine to aim at")
        }
        // Its own workspace in the repo under test, so the probe never asks
        // about whatever the session happened to be sitting in.
        ask(.createWorkspace(cwd: cwd, label: "wtprobe"), Reply.WorkspaceCreated.self,
            session: session, target: target, failing: "workspace"
        ) { made in
            let workspace = made.workspace.workspaceID
            say("workspace=\(workspace) cwd=\(cwd)")
            let root = session.lastSnapshot?.worktreeDirectory
            say("worktree_directory=\(root ?? "nil")")

            self.ask(.worktreeList(workspace: workspace), Reply.WorktreeList.self,
                session: session, target: target, failing: "list"
            ) { list in
                let branch = "worktree/probe-\(Int(Date().timeIntervalSince1970) % 100000)"
                // Worked out before the request, exactly as the sheet shows it.
                let predicted = root.map {
                    Worktrees.checkoutPath(
                        root: $0, repo: list.source.repoName, branch: branch)
                }
                say("repo=\(list.source.repoName) existing=\(list.worktrees.count)")
                say("predicted=\(predicted ?? "nil")")

                self.ask(.worktreeCreate(workspace: workspace, branch: branch),
                    Reply.WorktreeCreated.self, session: session, target: target,
                    failing: "create"
                ) { created in
                    // What the server did, against what we told the person it
                    // would do.
                    say("created tab=\(created.tab.tabID) at=\(created.worktree.path)")
                    say("path_matches_preview=\(created.worktree.path == predicted)")

                    self.ask(.worktreeList(workspace: workspace), Reply.WorktreeList.self,
                        session: session, target: target, failing: "relist"
                    ) { after in
                        let entry = after.worktrees.first { $0.path == created.worktree.path }
                        say(
                            "relisted=\(after.worktrees.count) found=\(entry != nil) "
                                + "title=\(entry?.title ?? "nil") "
                                + "linked=\(entry?.isLinkedWorktree ?? false) "
                                + "open_workspace=\(entry?.openWorkspaceID ?? "nil")")
                        say("offered_to_open=\(after.openable.count)")

                        // Removed through the same guard a person goes through,
                        // so the probe also says whether that guard agrees the
                        // new workspace is removable.
                        guard let opened = entry?.openWorkspaceID else {
                            say("no workspace to remove; leaving \(created.worktree.path)")
                            return finish()
                        }
                        let made = session.lastSnapshot?.workspaces
                            .first { $0.workspaceID == opened }
                        say(
                            "remove_refusal=\(Worktrees.refusal(for: .removeWorktree, workspace: made) ?? "none")")

                        // The lookup the remove flow actually does, which is
                        // not the one above: it lists from *inside* the linked
                        // checkout and finds the entry pointing back at it.
                        // Whether `worktree.list` answers from there at all is
                        // herdr's business, and the only way to know is to ask.
                        //
                        // Strictly before the removal, never alongside it.
                        // herdr runs one worktree operation at a time and
                        // answers `endpoint_busy` to anything that overlaps —
                        // which, measured the overlapping way round, replaced
                        // the refusal this probe exists to read.
                        self.ask(.worktreeList(workspace: opened),
                            Reply.WorktreeList.self, session: session, target: target,
                            failing: "list from linked"
                        ) { inside in
                            let mine = inside.worktrees.first { $0.openWorkspaceID == opened }
                            say(
                                "from_linked repo=\(inside.source.repoName) "
                                    + "found_self=\(mine != nil) path=\(mine?.path ?? "nil")")
                            say("path_is_the_one_created=\(mine?.path == created.worktree.path)")

                            // Left dirty on purpose. The second half of the
                            // remove flow hangs off herdr's refusal code, and a
                            // code that does not match is a force prompt that
                            // never appears — the person just sees a removal
                            // fail and stay failed.
                            let dirtied = FileManager.default.createFile(
                                atPath: created.worktree.path + "/probe-dirt.txt",
                                contents: Data("uncommitted\n".utf8))
                            say("dirtied=\(dirtied)")

                            self.sendProbeRemoval(
                                workspace: opened, force: false, session: session, say: say
                            ) { gentle in
                                say(
                                    "unforced=\(gentle.map { "refused \($0.code ?? "nil")" } ?? "removed")")
                                say("needs_force=\(gentle.map(Worktrees.needsForce) ?? false)")
                                self.sendProbeRemoval(
                                    workspace: opened, force: true, session: session, say: say
                                ) { forced in
                                    say("forced=\(forced.map { "refused \($0.text)" } ?? "removed")")
                                    self.ask(.worktreeList(workspace: workspace),
                                        Reply.WorktreeList.self, session: session,
                                        target: target, failing: "final"
                                    ) { final in
                                        let gone = !final.worktrees.contains {
                                            $0.path == created.worktree.path
                                        }
                                        say("removed=\(gone) remaining=\(final.worktrees.count)")
                                        self.invoke(.closeWorkspace(workspace), session: session)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                            MainActor.assumeIsolated { finish() }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// One removal for the probe, reporting the refusal rather than acting on
    /// it — the flow a person drives asks a question here instead.
    private func sendProbeRemoval(
        workspace: String, force: Bool, session: HerdrSession, say: @escaping (String) -> Void,
        then done: @escaping (Reply.Failure?) -> Void
    ) {
        let id = UUID().uuidString
        let command = Command.worktreeRemove(workspace: workspace, force: force)
        guard let boot = session.lastSnapshot?.bootID, let json = command.requestJSON(id: id)
        else { return say("remove: no boot id") }
        session.request(json, bootID: boot, id: id) { body in
            MainActor.assumeIsolated { done(Reply.rejection(in: body)) }
        }
    }

    // MARK: - Worktrees

    /// Asks the endpoint about the focused workspace's repo, then hands over.
    ///
    /// Every worktree action starts here, create included: the sheet shows
    /// where a branch will land, and that needs the repo's name, which the
    /// snapshot does not carry. The guard runs first so a refusal costs no
    /// request — and so it can say which way round the rule is, which is the
    /// part that tells someone what to do instead.
    private func withWorktrees(
        _ action: Keymap.Action, session: HerdrSession,
        then use: @escaping (String, Worktrees.Target, Reply.WorktreeList) -> Void
    ) {
        let workspace = session.lastSnapshot?.workspaces.first(where: \.focused)
        if let refusal = Worktrees.refusal(for: action, workspace: workspace) {
            notice(refusal)
            return
        }
        guard let workspace, let target = worktreeTarget(session: session) else { return }
        ask(.worktreeList(workspace: workspace.workspaceID), Reply.WorktreeList.self,
            session: session, target: target, failing: "worktrees"
        ) { use(workspace.workspaceID, target, $0) }
    }

    /// The machine in front of us now, to pin a flow to. See `Worktrees.Target`.
    private func worktreeTarget(session: HerdrSession) -> Worktrees.Target? {
        let endpoint = session.activeEndpoint
        guard let bootID = session.bootID(forEndpoint: endpoint) else { return nil }
        return Worktrees.Target(
            endpoint: endpoint, bootID: bootID,
            label: session.endpoints.first { $0.index == endpoint }?.label ?? "that machine")
    }

    /// Whether a flow may still act, saying so when it may not.
    private func stillAimed(
        at target: Worktrees.Target, session: HerdrSession, doing what: String
    ) -> Bool {
        guard
            let drift = Worktrees.drift(
                from: target,
                // Identity, not equality: a rebuilt session is a different
                // object holding a different set of machines.
                sessionReplaced: self.session !== session,
                activeEndpoint: session.activeEndpoint,
                bootID: session.bootID(forEndpoint: target.endpoint))
        else { return true }
        notice("\(what): \(drift)")
        return false
    }

    /// One request whose reply is read rather than only checked for rejection.
    ///
    /// `invoke` is for the commands whose reply says nothing but whether they
    /// worked. These three carry what the next step needs — the repo, the tab
    /// to focus — so the body has to be decoded, and a failure named rather
    /// than swallowed.
    private func ask<Result: Decodable>(
        _ command: Command, _ type: Result.Type, session: HerdrSession,
        target: Worktrees.Target, failing label: String,
        then use: @escaping (Result) -> Void
    ) {
        guard stillAimed(at: target, session: session, doing: label) else { return }
        let id = UUID().uuidString
        guard let json = command.requestJSON(id: id) else { return }
        // The pinned boot id, not the active snapshot's: they are the same
        // until the window moves, and the whole point is the case where it has.
        session.request(json, bootID: target.bootID, id: id) { [weak self] body in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch Reply.decode(type, from: body) {
                case .success(let result): use(result)
                case .failure(let failure): self.notice("\(label): \(failure.text)")
                }
            }
        }
    }

    /// Asks for a branch, showing where it will be checked out as it is typed.
    private func newWorktree(session: HerdrSession) {
        withWorktrees(.newWorktree, session: session) { workspace, target, list in
            // Absent only from a server too old to publish it; the sheet then
            // asks for a branch without claiming to know where it goes.
            let root = session.lastSnapshot?.worktreeDirectory
            self.prompt.ask(
                over: self.window, title: "New worktree",
                value: Worktrees.branchSuggestion(),
                describe: root.map { root in
                    { branch in
                        branch.isEmpty
                            ? ""
                            : Worktrees.checkoutPath(
                                root: root, repo: list.source.repoName, branch: branch)
                    }
                }
            ) { branch in
                // The sheet may have been open across a machine switch, so the
                // target is checked again on the way out of it rather than
                // trusted from when it opened.
                self.createWorktree(
                    branch: branch, from: workspace, target: target, session: session)
            }
        }
    }

    /// Creates the checkout and goes to it.
    ///
    /// Two steps because the request cannot ask for focus and mean it: herdr
    /// makes the workspace asynchronously, and the reply is the first thing
    /// that knows which tab there is to focus.
    private func createWorktree(
        branch: String, from workspace: String, target: Worktrees.Target, session: HerdrSession
    ) {
        // `git worktree add` plus whatever the repo runs on checkout, so this
        // is not instant and the window should not look idle while it happens.
        notice("creating \(branch)…")
        ask(.worktreeCreate(workspace: workspace, branch: branch), Reply.WorktreeCreated.self,
            session: session, target: target, failing: "worktree \(branch)"
        ) { created in
            // A tab id from the machine this was created on. Focusing it
            // against whatever is active now would name another machine's tab.
            guard self.stillAimed(at: target, session: session, doing: "worktree \(branch)")
            else { return }
            self.invoke(.focusTab(created.tab.tabID), session: session, bootID: target.bootID)
            self.notice("worktree \(branch)")
        }
    }

    /// Lists the repo's checkouts and opens the chosen one.
    private func openWorktree(session: HerdrSession) {
        withWorktrees(.openWorktree, session: session) { workspace, target, list in
            let entries = list.openable
            guard !entries.isEmpty else {
                self.notice("no git worktrees for this repo")
                return
            }
            self.picker.show(
                over: self.window, title: "Open worktree",
                items: entries.map { entry in
                    // Said rather than left to be discovered: opening one that
                    // is already open lands you somewhere you could have
                    // reached, and the repo's own checkout is not a worktree
                    // anyone means to "open".
                    let detail = [
                        entry.openWorkspaceID != nil ? "open" : nil,
                        entry.isLinkedWorktree ? nil : "source",
                        entry.isDetached ? "detached" : nil,
                        entry.path,
                    ].compactMap { $0 }.joined(separator: "  ·  ")
                    return Picker.Item(title: entry.title, detail: detail) {
                        // A path from one machine's repo, so it goes back to
                        // that machine or nowhere. The list can be up for a
                        // while, and an identical path exists on more than one
                        // of these machines.
                        guard
                            self.stillAimed(
                                at: target, session: session, doing: "open \(entry.title)")
                        else { return }
                        self.invoke(
                            .worktreeOpen(workspace: workspace, path: entry.path),
                            session: session, bootID: target.bootID)
                    }
                })
        }
    }

    /// Removes the checkout this workspace is, after asking.
    private func removeWorktree(session: HerdrSession) {
        withWorktrees(.removeWorktree, session: session) { workspace, target, list in
            // The guard only proved this workspace is a linked checkout. Which
            // checkout it is comes from the list, and a workspace herdr does
            // not match to one is not ours to remove.
            guard let entry = list.worktrees.first(where: { $0.openWorkspaceID == workspace })
            else {
                self.notice("This workspace is not a Herdr-managed worktree checkout.")
                return
            }
            guard
                self.confirm(
                    "Remove “\(entry.title)”?",
                    detail: "The checkout at \(entry.path) is deleted. The branch is not.",
                    action: "Remove")
            else { return }
            self.sendWorktreeRemoval(
                entry, workspace: workspace, target: target, force: false, session: session)
        }
    }

    /// Sends the removal, and asks a second time when git will not do it
    /// quietly.
    ///
    /// herdr answers a checkout with uncommitted work — or one whose directory
    /// has already gone — by refusing and saying so, rather than by deciding
    /// for anybody. So does this: the second question is a different question,
    /// and it names what is being thrown away.
    private func sendWorktreeRemoval(
        _ entry: Reply.WorktreeList.Entry, workspace: String, target: Worktrees.Target,
        force: Bool, session: HerdrSession
    ) {
        let doing = "remove \(entry.title)"
        guard stillAimed(at: target, session: session, doing: doing) else { return }
        let id = UUID().uuidString
        let command = Command.worktreeRemove(workspace: workspace, force: force)
        guard let json = command.requestJSON(id: id) else { return }
        session.request(json, bootID: target.bootID, id: id) { [weak self] body in
            MainActor.assumeIsolated {
                // The session this was sent on, not whichever one the window
                // holds now: a rebuilt session is a different set of machines.
                guard let self else { return }
                guard let failure = Reply.rejection(in: body) else {
                    self.notice("removed \(entry.title)")
                    return
                }
                guard !force, Worktrees.needsForce(failure) else {
                    self.notice("\(doing): \(failure.text)")
                    return
                }
                // The second question names the machine as well as the
                // checkout, because a person who has moved on since the first
                // one needs to know which one they are answering about.
                guard
                    self.confirm(
                        "Force removal of “\(entry.title)” on \(target.label)?",
                        detail: "git will not remove it as it is: \(failure.text)",
                        action: "Force Remove")
                else { return }
                self.sendWorktreeRemoval(
                    entry, workspace: workspace, target: target, force: true, session: session)
            }
        }
    }

    /// A destructive confirm, with Return on Cancel.
    private func confirm(_ message: String, detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        let proceed = alert.addButton(withTitle: action)
        let cancel = alert.addButton(withTitle: "Cancel")
        // Return must not be the button that deletes a directory.
        proceed.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
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
        // Resolved here rather than in the menu handler, because `invoke` is
        // the one door every caller comes through: aimed at the active machine
        // it would be an ordinary new workspace wearing a name that says local.
        if case .newLocalWorkspace = command {
            perform(.newLocalWorkspace, session: session)
            return
        }
        if case .hibernateWorkspace = command {
            hibernateFocusedWorkspace(session: session)
            return
        }
        // Each is a sequence rather than a payload, and each asks the repo
        // about itself before it can even draw its sheet.
        if case .newWorktree = command {
            newWorktree(session: session)
            return
        }
        if case .openWorktree = command {
            openWorktree(session: session)
            return
        }
        if case .removeWorktree = command {
            removeWorktree(session: session)
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
            guard let rejection = Reply.rejection(in: reply) else { return }
            MainActor.assumeIsolated {
                self?.report(rejection, reply: reply, for: command)
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

    /// The theme list, for whichever theme is on screen now.
    @objc private func showThemes(_ sender: Any?) {
        showThemes(for: preferences.slot(matching: systemIsDark))
    }

    /// Picks a theme for one slot, showing each one as the highlight passes
    /// over it.
    ///
    /// Applied on the way past rather than only on Return: a palette is a thing
    /// you judge by looking at it, and a list of names tells you nothing about
    /// which one you want.
    private func showThemes(for slot: Preferences.Slot) {
        // Read up front so each row can say what it is. "kitty theme" on four
        // hundred rows says nothing, while light or dark is most of what
        // anyone is filtering for.
        func describe(_ theme: Theme) -> String {
            (theme.background.isDarkish ? "dark" : "light") + "  ·  "
                + (Preferences.encode(theme.background) ?? "")
        }
        func row(
            _ title: String, _ theme: Theme, choice: Preferences.ThemeChoice?
        ) -> Picker.Item {
            Picker.Item(
                title: title, detail: describe(theme),
                choose: { [weak self] in self?.commitTheme(choice, for: slot) },
                highlight: { [weak self] in self?.showPreview(of: theme) })
        }

        var items = [row("Built-in", Preferences.theme(nil, for: slot), choice: nil)]
        let installed = ThemeLibrary.installed()
        // A file that does not read is left out rather than listed: there is
        // nothing to preview, and choosing it could not do anything.
        for entry in installed {
            guard let theme = ThemeLibrary.theme(at: entry.url) else { continue }
            items.append(
                row(
                    entry.name, theme,
                    choice: Preferences.ThemeChoice(
                        name: entry.name, colors: theme.hexComponents)))
        }
        // In the list rather than in front of it: going back to the built-in
        // palette or loading a file of your own should not wait on a download.
        if installed.isEmpty {
            items.append(
                Picker.Item(title: "Download Themes…", detail: "kitty's collection") {
                    [weak self] in
                    self?.endThemePreview()
                    self?.offerToFetchThemes(for: slot)
                })
        }
        // Last rather than a button beside the list: it is one more way of
        // arriving at a theme, and here is where themes are chosen.
        items.append(
            Picker.Item(title: "Load from File…", detail: "a kitty .conf") { [weak self] in
                self?.loadTheme(for: slot)
            })

        themePicker.show(
            over: window,
            title: preferences.appearance == .system ? "\(slot.title) Theme" : "Theme",
            items: items,
            // Floating rather than a sheet: the window behind a sheet is
            // blurred, and a blurred terminal is the one thing that cannot
            // show what a palette does.
            as: .floating,
            onCancel: { [weak self] in self?.endThemePreview() })
    }

    private func showPreview(of theme: Theme) {
        previewTheme = theme
        applyTheme()
    }

    /// Back to what is configured. Nothing was written while previewing, so
    /// there is nothing to put back.
    private func endThemePreview() {
        guard previewTheme != nil else { return }
        previewTheme = nil
        applyTheme()
    }

    /// Settles a slot, ending any preview.
    private func commitTheme(_ choice: Preferences.ThemeChoice?, for slot: Preferences.Slot) {
        previewTheme = nil
        preferences[theme: slot] = choice
        Preferences.current = preferences
        applyTheme()
        // Settings may be open beside the picker, and it shows the theme names.
        preferencesWindow?.refresh()
    }

    /// Loads a kitty theme file.
    ///
    /// For a theme that is not in the collection: kitty's themes are published
    /// as files, and reading one is a great deal less work for everybody than
    /// picking twenty colours out of a panel.
    private func loadTheme(for slot: Preferences.Slot) {
        // A file panel is no place to judge a palette from.
        endThemePreview()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "conf") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a kitty theme (.conf)"
        guard panel.runModal() == .OK, let url = panel.url,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }

        guard let theme = Theme(kittyConfiguration: text) else {
            let alert = NSAlert()
            alert.messageText = "That file is not a colour theme"
            alert.informativeText =
                "A kitty theme sets background, foreground and color0 through "
                + "color15. This one does not."
            alert.runModal()
            return
        }
        commitTheme(
            Preferences.ThemeChoice(
                name: url.deletingPathExtension().lastPathComponent,
                colors: theme.hexComponents),
            for: slot)
    }

    /// Offers to fetch the collection, saying where it comes from.
    private func offerToFetchThemes(for slot: Preferences.Slot) {
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
                    self.showThemes(for: slot)
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

    @objc private func showInstallHerdr(_ sender: Any?) {
        LocalHerdr.offerInstall(over: window)
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
        guard let session, let local = session.localEndpoint else {
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
            gridView.placeholder = herdrExplanation ?? "waiting for herdr…"
            reconnect()
        }
        applyTitle()
    }

    @objc private func findInPane(_ sender: Any?) {
        gridView.enterCopyMode(searching: true)
        window.makeFirstResponder(gridView)
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let command = Command.allByTag[sender.tag] else { return }
        // ⌘W closes what is in front of you. When that is Settings or Machines,
        // closing a herdr tab instead is the kind of surprise you notice only
        // after the tab has gone — so this one item follows the front window.
        // Decided here as well as in `validateMenuItem`, because a key
        // equivalent can fire without the menu ever being opened.
        if case .closeTab = command, !terminalIsFrontmost {
            NSApp.keyWindow?.performClose(sender)
            return
        }
        guard let session else { return }
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
        gridView.clearLinkHover()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        gridView.refreshLinkHover()
    }

    private func buildMenu() {
        NSApp.mainMenu = makeMainMenu()
    }

    /// Builds the menu bar.
    ///
    /// Returned rather than installed, so a test can walk the real thing: every
    /// way a Mac menu goes wrong is invisible in the source. An item whose
    /// command is not in `allByTag` clicks and does nothing; two items claiming
    /// one keystroke leave whichever AppKit finds second unreachable; and a
    /// missing standard item — Hide, Services, Minimize — is noticed only by
    /// the person who reaches for it and finds it gone.
    func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(applicationMenu())
        main.addItem(commandMenu(titled: "Shell", rows: Command.shellRows))
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(sessionMenuItem())
        main.addItem(windowMenu())
        main.addItem(helpMenu())
        return main
    }

    /// The app menu: what macOS puts under the application's own name.
    ///
    /// The order is the system's, not a preference — About, settings, Services,
    /// the three hide items, Quit — because it is the one menu whose contents
    /// every Mac user already knows. Machines sits beside Settings for the same
    /// reason Mail keeps Accounts there: it is a thing you configure once, not
    /// a thing you do to the window in front of you.
    private func applicationMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "HerdX")
        // Spelled out because macOS only substitutes the application's name
        // into these titles for a menu that came from a nib.
        menu.addItem(
            withTitle: "About HerdX",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let settings = NSMenuItem(
            title: "Settings…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let machines = NSMenuItem(
            title: "Machines…", action: #selector(showMachines(_:)), keyEquivalent: "m")
        machines.keyEquivalentModifierMask = [.command, .shift]
        machines.target = self
        menu.addItem(machines)
        menu.addItem(.separator())
        // Handed to AppKit rather than filled in here: the system owns the
        // contents, and telling it which menu to own is the only way in.
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        // No target: `hide:` and the two beside it are NSApplication's, and
        // NSApplication is the last link in the responder chain.
        menu.addItem(
            withTitle: "Hide HerdX", action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let hideOthers = NSMenuItem(
            title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit HerdX", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    /// The standard Edit menu, aimed at the first responder rather than at this
    /// object, which is what makes one ⌘C mean the terminal's selection in the
    /// terminal and a text field's in Settings.
    ///
    /// Undo and Cut do nothing in a terminal and are greyed there, but the
    /// Settings and Machines windows are full of text fields that have both —
    /// until now with no menu item to reach them by.
    private func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        // Spelled as strings because neither is declared on NSResponder; they
        // are what AppKit's own Edit menu sends, and the field editor answers.
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(
            withTitle: "Copy", action: #selector(TerminalGridView.copy(_:)), keyEquivalent: "c")
        menu.addItem(
            withTitle: "Paste", action: #selector(TerminalGridView.paste(_:)), keyEquivalent: "v")
        menu.addItem(
            withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a")
        menu.addItem(.separator())
        let find = NSMenuItem(
            title: "Find…", action: #selector(findInPane(_:)), keyEquivalent: "f")
        find.target = self
        menu.addItem(find)
        add(rows: Command.editRows, to: menu)
        item.submenu = menu
        return item
    }

    /// What the window shows: the sidebar, how it is ordered, the zoomed pane,
    /// and the palette everything is drawn in.
    private func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        add(rows: Command.sidebarRows, to: menu)
        // herdr has no binding for this — it is a config setting there — so
        // this is HerdX's own, and it goes in the menu rather than into a
        // keymap read from the server.
        let agents = NSMenuItem(
            title: "Sort Sidebar by Agent", action: #selector(toggleArrangement(_:)),
            keyEquivalent: "a")
        agents.keyEquivalentModifierMask = [.command, .option]
        agents.target = self
        arrangementItem = agents
        menu.addItem(agents)
        menu.addItem(.separator())
        add(rows: Command.paneViewRows, to: menu)
        // Beside Zoom Pane because they are the same wish at two scales, and
        // ⌃⌘F is the system's: AppKit swaps the title for "Exit Full Screen"
        // itself, which is why this one is not retitled in `validateMenuItem`.
        let fullScreen = NSMenuItem(
            title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreen)
        menu.addItem(.separator())
        let themes = NSMenuItem(
            title: "Themes…", action: #selector(showThemes(_:)), keyEquivalent: "t")
        themes.keyEquivalentModifierMask = [.command, .option]
        themes.target = self
        menu.addItem(themes)
        item.submenu = menu
        return item
    }

    private func sessionMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        sessionMenu.delegate = self
        // The delegate decides what is enabled; left to AppKit, every item with
        // no responder in the chain would be greyed out.
        sessionMenu.autoenablesItems = false
        item.submenu = sessionMenu
        return item
    }

    /// The standard Window menu, carrying the moves between what is already
    /// open. Next Tab and the pane arrows are here rather than in Shell because
    /// this is where a Mac user looks for them.
    private func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        menu.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        add(rows: Command.windowRows, to: menu)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "")
        item.submenu = menu
        // AppKit keeps the list of open windows at the foot of whichever menu
        // it is told is this one. Settings and Machines are ordinary windows,
        // and this is the only way back to one that has gone behind the
        // terminal.
        NSApp.windowsMenu = menu
        return item
    }

    private func helpMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        add(rows: Command.helpRows, to: menu)
        // The one thing someone with no herdr needs, and the only way back to
        // it once the dialog at launch has been dismissed. Hidden by
        // `validateMenuItem` on a Mac that already has herdr.
        let install = NSMenuItem(
            title: "Install herdr…", action: #selector(showInstallHerdr(_:)), keyEquivalent: "")
        install.target = self
        menu.addItem(install)
        item.submenu = menu
        // Named to AppKit, so the system's help handling finds this menu rather
        // than one that merely happens to be called Help.
        NSApp.helpMenu = menu
        return item
    }

    /// A menu made only of herdr commands.
    private func commandMenu(titled title: String, rows: [Command.Row]) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        add(rows: rows, to: menu)
        item.submenu = menu
        return item
    }

    /// Turns a table of rows into menu items. The command travels as the tag,
    /// which is the only part of it that survives a round trip through AppKit.
    private func add(rows: [Command.Row], to menu: NSMenu) {
        for row in rows {
            switch row {
            case .separator:
                menu.addItem(.separator())
            case .item(let title, let key, let command):
                let item = NSMenuItem(
                    title: title, action: #selector(menuCommand(_:)),
                    keyEquivalent: key.equivalent)
                item.keyEquivalentModifierMask = key.modifiers
                item.tag = command.tag
                item.target = self
                menu.addItem(item)
            }
        }
    }

    /// Greys out what cannot work, and retitles the two items whose meaning
    /// depends on what is in front.
    ///
    /// Only items aimed at this object arrive here. The Edit menu's are aimed
    /// at the first responder and validated by whoever holds it, which is how
    /// Undo can be live in a Settings text field and dead in the terminal.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(menuCommand(_:)):
            guard let command = Command.allByTag[item.tag] else { return false }
            if case .closeTab = command {
                guard terminalIsFrontmost else {
                    item.title = "Close Window"
                    return NSApp.keyWindow?.styleMask.contains(.closable) ?? false
                }
                item.title = "Close Tab"
            }
            if case .toggleSidebar = command {
                let collapsed = windowSplit.map { $0.isSubviewCollapsed(sidebar) } ?? false
                item.title = collapsed ? "Show Sidebar" : "Hide Sidebar"
            }
            return session != nil
        case #selector(findInPane(_:)):
            return session != nil
        case #selector(showInstallHerdr(_:)):
            // Offering to install what is already installed reads as the app
            // not knowing what is on the machine it is running on.
            item.isHidden = LocalHerdr.binaryPath() != nil
            return true
        default:
            return true
        }
    }

    /// Whether the keyboard is aimed at the terminal window.
    ///
    /// No key window means the app is not active, and the terminal is then what
    /// a keystroke would arrive at. A sheet counts as something else: ⌘W while
    /// a rename prompt is up should not reach past it and close a tab.
    private var terminalIsFrontmost: Bool {
        let key = NSApp.keyWindow
        return key == nil || key === window
    }

    /// Says so when a newer HerdX has been published, once a day at most.
    ///
    /// At launch and nowhere else. An app that notices mid-session has to
    /// interrupt to say so, and there is no moment during a day's work when
    /// being told about a download is welcome; the moment it is welcome is the
    /// one where you have just started the thing.
    ///
    /// The day is spent before the answer arrives rather than after, so a
    /// machine with no network does not try again on every launch — and a
    /// release found on a flaky connection is still found tomorrow.
    private func checkForUpdate() {
        // Probes and captures make no network calls and raise no dialogs, which
        // is what makes them safe to run in a loop. `HERDX_UPDATE_CHECK` is a
        // developer saying otherwise, and is also the only way to see this
        // happen on the day a release is already installed.
        guard !AppDelegate.isHeadless || Updates.forced else { return }
        guard let running = Updates.runningVersion else { return }
        guard Updates.forced || Updates.isDue(lastChecked: Updates.lastChecked) else { return }
        Updates.noteChecked()
        Updates.fetchLatest { [weak self] release in
            MainActor.assumeIsolated {
                guard let self, let release,
                    Updates.isNewer(release.version, than: running)
                else { return }
                self.offer(release, running: running)
            }
        }
    }

    /// One sentence and two buttons. There is no updater in this app, so the
    /// most it can honestly do is open the page the download is on.
    private func offer(_ release: Updates.Release, running: String) {
        let alert = NSAlert()
        alert.messageText = "HerdX \(release.version.hasPrefix("v") ? String(release.version.dropFirst()) : release.version) is available"
        alert.informativeText = "You are running \(running)."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        // A sheet, not a dialog in the middle of the screen: it belongs to this
        // window, and a launch that puts a free-floating box over whatever else
        // is on screen is the behaviour this notice is trying not to become.
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(release.page)
        }
    }

    /// Dev affordance: `HERDX_CAPTURE=/path.png` renders the window and exits.
    ///
    /// The window is never ordered on-screen and the app never activates, so
    /// this does not interrupt whatever you are doing. It also sidesteps
    /// `screencapture -R`, which picks the wrong display on multi-monitor setups.
    private var capturePath: String? {
        ProcessInfo.processInfo.environment["HERDX_CAPTURE"]
    }

    /// Dev affordance: `HERDX_PROBE_LOCK=<seconds>` reports, once a second,
    /// whether HerdX thinks the screen is locked.
    ///
    /// The only way to see the locked answer is to be looking at a locked
    /// screen, which is the one moment nothing can be read off this one. So it
    /// prints to stdout for that long and leaves the transcript behind: start
    /// it, lock the screen, unlock it, and read what it made of the interval.
    private func installLockProbeIfRequested() {
        guard
            let seconds = ProcessInfo.processInfo.environment["HERDX_PROBE_LOCK"]
                .flatMap(Double.init), seconds > 0
        else { return }
        print("probe: watching the lock for \(Int(seconds))s")
        let started = Date()
        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            let elapsed = Date().timeIntervalSince(started)
            // The gate the sounds actually pass through, not just the reading
            // underneath it — `audible=false` is the answer being checked.
            let audible = MainActor.assumeIsolated { self?.agentSounds.isAudible }
            print(
                "probe: t=\(Int(elapsed))s locked=\(AgentSounds.screenIsLocked())"
                    + " audible=\(audible.map(String.init(describing:)) ?? "gone")")
            fflush(stdout)
            if elapsed >= seconds {
                timer.invalidate()
                print("probe: done")
                fflush(stdout)
            }
        }
        // Common modes, or the timer stops dead for as long as a menu is open.
        RunLoop.main.add(tick, forMode: .common)
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

                // Types the text, which is what this probe is for and what it
                // has always said it did. Through `keyDown` rather than
                // `send(text:)`: the point is to exercise the AppKit half —
                // the responder, the key mapping, and the input context that
                // printable keys now go through — rather than the FFI call at
                // the end of it.
                if !probe.isEmpty {
                    self.window.makeFirstResponder(self.gridView)
                    print("probe: typing \(probe.count) characters")
                    for character in probe {
                        let text = String(character)
                        guard
                            let event = NSEvent.keyEvent(
                                with: .keyDown, location: .zero, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: self.window.windowNumber, context: nil,
                                characters: text, charactersIgnoringModifiers: text,
                                isARepeat: false, keyCode: 0)
                        else { continue }
                        self.gridView.keyDown(with: event)
                    }
                    print("probe: hasMarkedText=\(self.gridView.hasMarkedText())")
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
                // Any sheet, not only one this run asked for: the first-run
                // dialog puts itself up, and photographing the window behind it
                // would be a picture of the app looking fine.
                : (self.window.attachedSheet?.contentView ?? self.window.contentView)
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
