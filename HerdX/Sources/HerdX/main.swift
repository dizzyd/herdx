import AppKit

/// HerdX: a native macOS client for herdr.
///
/// The server owns terminal emulation and sends composed cell grids plus a
/// structured description of the workspace tree, so this app is a renderer and
/// an input source, not a terminal emulator.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSSplitViewDelegate
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
    /// The appearance the current theme was resolved from.
    private var appliedSystemIsDark: Bool?
    private let copyModeStatus = ModeStatus()
    private let tabBar = TabBarView()
    private let help = HelpSheet()
    private let prompt = Prompt()
    private let picker = Picker()
    private lazy var machinesWindow = MachinesWindowController(
        onChange: { [weak self] in self?.reattachMachines() },
        onInstall: { [weak self] target in self?.installHerdr(on: target) })

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
        window.titleVisibility = .hidden



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
            window.subtitle = "waiting for herdr… (\(lastConnectError ?? "no server"))"
            reconnect()
        }

        buildMenu()
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
        appliedSystemIsDark = systemIsDark
        // The Mac light/dark appearance is set on the window below and the
        // controls follow it; everything this app paints itself comes from the
        // terminal theme and the chrome derived from it, so that the window
        // reads as one surface rather than two.
        terminalTheme = preferences.terminalTheme(matching: systemIsDark)

        gridView.theme = terminalTheme
        gridView.apply(
            panePadding: preferences.panePadding, labelSize: preferences.paneLabelSize)

        switch preferences.appearance {
        case .system: window.appearance = nil
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        case .light: window.appearance = NSAppearance(named: .aqua)
        }
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
                    self.gridView.apply(
                        font: updated.font, lineHeight: updated.lineHeight)
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
        window.subtitle = ""
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
        let online = Set(session.endpoints.filter { $0.status == .online }.map(\.index))
        if !online.subtracting(themedEndpoints).isEmpty {
            themedEndpoints = online
            publish(theme: terminalTheme, force: true)
        } else if online != themedEndpoints {
            // A machine that dropped is told again when it returns.
            themedEndpoints = online
        }

        offerInstallIfNeeded(session)
        sidebar.update(endpoints: session.endpoints, active: session.activeEndpoint)
        tabBar.update(with: session.lastSnapshot)
        gridView.paneLabels = Self.paneLabels(from: session.lastSnapshot)

        if snapshotsChanged {
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

    @objc private func showMachines(_ sender: Any?) {
        machinesWindow.present()
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
            guard let target = Machines.all().first(where: { $0.id == endpoint.id })?.target
            else { continue }

            let alert = NSAlert()
            alert.messageText = "Set herdr up on “\(endpoint.label)”?"
            alert.informativeText =
                "\(target) is reachable but has no herdr installed, so HerdX cannot "
                + "attach to it.\n\nHerdX will open a terminal running:\n\n"
                + "    herdr --remote \(target)\n\n"
                + "herdr downloads the build matching that machine and asks you to "
                + "confirm before changing anything."
            alert.addButton(withTitle: "Open Terminal")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn {
                installHerdr(on: target)
            }
        }
    }

    /// Opens a local tab running herdr's own remote installer.
    ///
    /// A pane rather than a background command: herdr refuses to install
    /// unless stdin is a terminal, because approving a binary onto another
    /// machine is a decision it wants a person to make. A pane is a terminal,
    /// so its prompt arrives where you can answer it.
    private func installHerdr(on target: String) {
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
            session.send(text: "herdr --remote \(Self.shellQuoted(target))\n", to: pane)
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

    /// Single-quoted for the shell the pane is running.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Rebuilds the session so a change to the catalog takes effect.
    ///
    /// Endpoints are resolved once, when the session is created, so a machine
    /// added or removed is not something the running session can be told
    /// about — it has to be stood up again.
    private func reattachMachines() {
        gridView.forgetSurface()
        gridView.session = nil
        session = nil
        themedEndpoints = []
        publishedTheme = nil
        if !connect() {
            window.subtitle = "waiting for herdr… (\(lastConnectError ?? "no server"))"
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
                machinesWanted
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
