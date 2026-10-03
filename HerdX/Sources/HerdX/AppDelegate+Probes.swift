import AppKit

/// The development affordances, kept out of the orchestration they observe.
///
/// All of these are read from the environment and do nothing without it; none
/// is reachable from the UI. They live here because a reader following what
/// the app actually does should not have to cross four hundred lines of
/// instrumentation to do it — and because when one of them is wrong, this is
/// where to look.
///
/// `AGENTS.md` carries the table of what each one is for. The registration
/// calls stay at their lifecycle points in `main.swift`, so the order they run
/// in is still visible where the app is set up.
extension AppDelegate {
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
    func installWakeProbeIfRequested() {
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

    /// Reports any prefix binding no keystroke can reach.
    ///
    /// Generated from the keymap rather than from a list here, so it keeps
    /// checking whatever the server sends. It exists because the matcher has
    /// twice been too strict about shift and made a binding unreachable —
    /// silently, since an armed prefix consumes the key either way.
    func reportUnreachableChords() {
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
    func installWorktreeProbeIfRequested() {
        guard let cwd = ProcessInfo.processInfo.environment["HERDX_PROBE_WORKTREE"] else { return }
        let delay = ProcessInfo.processInfo.environment["HERDX_PROBE_DELAY"]
            .flatMap(Double.init) ?? 6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.runWorktreeProbe(in: cwd) }
        }
    }

    func runWorktreeProbe(in cwd: String) {
        guard let session else { return print("probe: no session") }
        func say(_ text: String) {
            print("probe: \(text)")
            fflush(stdout)
        }
        func finish() {
            say("done")
            NSApp.terminate(nil)
        }

        guard let target = aimAtActiveEndpoint(session: session) else {
            return say("no machine to aim at")
        }
        // Its own workspace in the repo under test, so the probe never asks
        // about whatever the session happened to be sitting in.
        ask(.createWorkspace(cwd: cwd, label: "wtprobe"), Reply.WorkspaceCreated.self,
            target: target, failing: "workspace"
        ) { made in
            let workspace = made.workspace.workspaceID
            say("workspace=\(workspace) cwd=\(cwd)")
            let root = session.lastSnapshot?.worktreeDirectory
            say("worktree_directory=\(root ?? "nil")")

            self.ask(.worktreeList(workspace: workspace), Reply.WorktreeList.self,
                target: target, failing: "list"
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
                    Reply.WorktreeCreated.self, target: target,
                    failing: "create"
                ) { created in
                    // What the server did, against what we told the person it
                    // would do.
                    say("created tab=\(created.tab.tabID) at=\(created.worktree.path)")
                    say("path_matches_preview=\(created.worktree.path == predicted)")

                    self.ask(.worktreeList(workspace: workspace), Reply.WorktreeList.self,
                        target: target, failing: "relist"
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
                            Reply.WorktreeList.self, target: target,
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
                                        Reply.WorktreeList.self,
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
    func sendProbeRemoval(
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

    /// Dev affordance: `HERDX_CAPTURE=/path.png` renders the window and exits.
    ///
    /// The window is never ordered on-screen and the app never activates, so
    /// this does not interrupt whatever you are doing. It also sidesteps
    /// `screencapture -R`, which picks the wrong display on multi-monitor setups.
    var capturePath: String? {
        ProcessInfo.processInfo.environment["HERDX_CAPTURE"]
    }

    /// Dev affordance: `HERDX_PROBE_LOCK=<seconds>` reports, once a second,
    /// whether HerdX thinks the screen is locked.
    ///
    /// The only way to see the locked answer is to be looking at a locked
    /// screen, which is the one moment nothing can be read off this one. So it
    /// prints to stdout for that long and leaves the transcript behind: start
    /// it, lock the screen, unlock it, and read what it made of the interval.
    func installLockProbeIfRequested() {
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
    func installInputProbeIfRequested() {
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

    func installCaptureHookIfRequested() {
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
    func composited() -> NSBitmapImageRep? {
        guard
            let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                [.boundsIgnoreFraming, .bestResolution])
        else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }
}
