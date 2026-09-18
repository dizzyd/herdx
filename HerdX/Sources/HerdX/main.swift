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
    /// Held so a theme change can recolour their dividers.
    private var windowSplit: ChromeSplitView?
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
    /// The appearance the current theme was resolved from.
    private var appliedSystemIsDark: Bool?
    private let copyModeStatus = CopyModeStatusView()
    private let tabBar = TabBarView()
    private let help = HelpSheet()

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = Preferences.current
        gridView = TerminalGridView(font: preferences.font)

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
            self.focusTerminal()
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


        copyModeStatus.translatesAutoresizingMaskIntoConstraints = false

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
        appliedSystemIsDark = systemIsDark
        // Two themes and one palette: `window` is the light/dark appearance the
        // Mac controls follow, `terminal` is what the grid is painted in, and
        // the palette is the chrome derived from the terminal so the window
        // reads as one surface.
        let windowTheme = preferences.theme(matching: systemIsDark)
        terminalTheme = preferences.terminalTheme(matching: systemIsDark)

        gridView.theme = terminalTheme
        gridView.apply(
            panePadding: preferences.panePadding, labelSize: preferences.paneLabelSize)

        switch preferences.appearance {
        case .system: window.appearance = nil
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        case .light: window.appearance = NSAppearance(named: .aqua)
        }
        copyModeStatus.apply(theme: windowTheme)
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

        var labels: [String: String] = [:]
        for pane in snapshot.panes {
            var parts: [String] = []
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

        default: return nil
        }
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

    private func cyclePane(by step: Int, session: HerdrSession) {
        let panes = gridView.panes
        guard panes.count > 1, let current = gridView.focusedPane,
            let at = panes.firstIndex(where: { $0.id == current })
        else { return }
        let next = panes[(at + step + panes.count) % panes.count]
        invoke(.focusPane(next.id), session: session)
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
            sidebar.isHidden.toggle()
            return
        }
        if case .help = command {
            help.show(over: window, keymap: chords.keymap) { action in
                self.handler(for: action, session: session) != nil
            }
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

                let made = self.window.makeFirstResponder(self.gridView)
                print("probe: makeFirstResponder=\(made)")

                // `HERDX_PROBE_ARM` leaves the chord prefix armed, so the
                // indicator can be photographed.
                if ProcessInfo.processInfo.environment["HERDX_PROBE_ARM"] != nil {
                    self.gridView.prefixArmed = true
                }

                for character in probe {
                    guard
                        let event = NSEvent.keyEvent(
                            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                            windowNumber: self.window.windowNumber, context: nil,
                            characters: String(character),
                            charactersIgnoringModifiers: String(character),
                            isARepeat: false, keyCode: 0)
                    else { continue }
                    self.gridView.keyDown(with: event)
                }
                print("probe: sent \(probe.count) keys")
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
            let helpWanted = environment["HERDX_CAPTURE_HELP"] != nil
            if settings { self.showPreferences(nil) }
            if helpWanted, let session = self.session {
                self.invoke(.help, session: session)
            }
            let target: NSView? =
                settings
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
            if let data = self.snapshot(of: view)?
                .representation(using: .png, properties: [:])
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
