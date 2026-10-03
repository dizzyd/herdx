import Foundation

/// Whether a quiet workspace may have its processes ended, and what to write
/// down if it may.
///
/// Pure, and deliberately apart from the requests that feed it: this is the
/// part that decides to end somebody's processes, and it should be provable
/// without a server to point it at.
///
/// Every rule is a refusal. Leaving a workspace running costs a little memory;
/// hibernating one that was in use costs work that cannot be got back, so the
/// two mistakes are not worth the same and the rules are not balanced.
enum HibernationPlan {
    struct Refusal: Error, Equatable {
        let reason: String
    }

    /// What `layout.apply` will take, from herdr's `MAX_LAYOUT_PANES` and
    /// `MAX_LAYOUT_DEPTH`.
    ///
    /// Copied rather than asked for: there is no method that reports them, and
    /// the alternative is finding out after the workspace has been closed.
    /// `HibernationPlanTests` carries herdr's own boundary so a change
    /// upstream fails here rather than at somebody's next revive.
    static let maxRestorablePanes = 24
    static let maxRestorableDepth = 16

    static func plan(
        workspace: Snapshot.Workspace,
        tabs: [Snapshot.Tab],
        endpointID: String,
        panes: [Reply.PaneEntry],
        processes: [String: Reply.Info],
        layouts: [String: Reply.Layout],
        at: Date = Date()
    ) -> Result<Hibernated, Refusal> {
        let agents = panes.filter(\.holdsAgent)

        // A workspace of plain shells has no conversation to preserve — only a
        // cwd and a layout — so ending it buys little and surprises somebody.
        guard !agents.isEmpty else {
            return .failure(Refusal(reason: "no agent to bring back"))
        }

        // Asked again rather than trusted from the sweep, which may have
        // chosen this workspace hours ago.
        //
        // Not the last word, though: this reading is taken alongside the
        // layout and process queries, and the close goes out after all of
        // them. `Hibernator.confirmStillQuiet` takes one more immediately
        // before closing, and says there what that can and cannot promise.
        if let busy = agents.first(where: {
            $0.agentStatus == .working || $0.agentStatus == .blocked
        }) {
            return .failure(Refusal(reason: "\(busy.agentName) is \(busy.agentStatus)"))
        }

        if let unresumable = agents.first(where: { $0.agentSession == nil }) {
            return .failure(
                Refusal(
                    reason: "\(unresumable.agentName) in \(unresumable.paneID) has no session to "
                        + "resume, so it would come back as a bare shell"))
        }

        var storedTabs: [Hibernated.Tab] = []
        var placed: Set<String> = []
        // Panes one of the rules has actually looked at.
        var judged: Set<String> = []

        for tab in tabs {
            guard let layout = layouts[tab.tabID] else {
                return .failure(Refusal(reason: "could not read the layout of \(tab.tabID)"))
            }
            let leaves = layout.root.leaves

            // herdr's `layout.apply` refuses a tree its own `layout.export`
            // was perfectly willing to hand over: more than 24 leaves, or
            // deeper than 16. Splitting panes enforces neither, so a workspace
            // can be built that cannot be rebuilt.
            //
            // Caught here rather than discovered on the way back, because by
            // then the workspace is gone: every revive is refused
            // `invalid_layout` and rolls back, leaving a row that can never
            // restore and a record that is the only thing still pointing at
            // those conversations.
            if leaves.count > maxRestorablePanes {
                return .failure(
                    Refusal(
                        reason: "\(tab.tabID) has \(leaves.count) panes, and herdr will not "
                            + "rebuild more than \(maxRestorablePanes)"))
            }
            if layout.root.depth > maxRestorableDepth {
                return .failure(
                    Refusal(
                        reason: "\(tab.tabID) is split \(layout.root.depth) deep, and herdr "
                            + "will not rebuild deeper than \(maxRestorableDepth)"))
            }

            // A pane launched with an argv is that process, with no shell under
            // it. It cannot be judged idle and would not come back as itself,
            // so its workspace is left alone rather than half-restored.
            if let commanded = leaves.first(where: { $0.pane.command?.isEmpty == false }) {
                let what = commanded.pane.command?.first ?? "a command"
                return .failure(Refusal(reason: "a pane is running \(what) rather than a shell"))
            }

            let agentPanes = Set(agents.map(\.paneID))
            for leaf in leaves {
                guard let paneID = leaf.pane.paneID else {
                    return .failure(Refusal(reason: "the layout of \(tab.tabID) has an unnamed pane"))
                }
                guard !agentPanes.contains(paneID) else { continue }
                // Panes without an agent are judged by what is running in them:
                // a build, a server or a REPL is somebody's work whether or not
                // herdr calls it an agent.
                guard let info = processes[paneID] else {
                    return .failure(Refusal(reason: "could not tell what is running in \(paneID)"))
                }
                guard info.isIdleShell else {
                    return .failure(
                        Refusal(reason: "\(info.runningDescription) is running in \(paneID)"))
                }
                judged.insert(paneID)
            }

            var storedAgents: [Hibernated.Agent] = []
            for agent in agents {
                guard let leaf = leaves.first(where: { $0.pane.paneID == agent.paneID }),
                    let session = agent.agentSession
                else { continue }
                storedAgents.append(
                    Hibernated.Agent(
                        path: leaf.path, source: session.source, agent: session.agent,
                        kind: session.kind, value: session.value))
                placed.insert(agent.paneID)
                judged.insert(agent.paneID)
            }

            storedTabs.append(
                Hibernated.Tab(
                    label: tab.label, zoomed: layout.zoomed,
                    // Stored without commands as well as applied without them,
                    // so a record made today cannot revive into a pane whose
                    // idleness can never be judged again.
                    root: layout.root.withoutCommands,
                    focused: leaves.first { $0.pane.paneID == layout.focusedPaneID }?.path,
                    agents: storedAgents))
        }

        // An agent whose pane is in no exported tree means the two readings
        // disagree about the workspace, and closing it would strand a
        // conversation nothing points at any more.
        if let stranded = agents.first(where: { !placed.contains($0.paneID) }) {
            return .failure(
                Refusal(reason: "\(stranded.paneID) holds an agent but is in no tab's layout"))
        }

        // And every other pane the workspace reports must have been looked at
        // by one of the rules above. The tabs, the layouts and the process
        // readings all come from the snapshot, while the pane list is fetched
        // after it — so a tab another client opened in between appears here
        // and nowhere else. Nothing above would have judged it, it would not
        // be written down, and closing the workspace would end whatever is
        // running in it. Two readings that disagree are not a reading.
        if let unplaced = panes.first(where: { !judged.contains($0.paneID) }) {
            return .failure(
                Refusal(
                    reason: "\(unplaced.paneID) is in the workspace but in no tab's layout, so "
                        + "what is running in it is unknown"))
        }

        return .success(
            Hibernated(
                id: UUID(), endpointID: endpointID, number: workspace.number,
                label: workspace.label, cwd: cwd(of: layouts) ?? NSHomeDirectory(),
                branch: workspace.branch, at: at, tabs: storedTabs))
    }

    /// Where the workspace should be recreated.
    ///
    /// The first pane's directory, because `workspace.create` takes one cwd and
    /// the layout puts every other pane back in its own.
    private static func cwd(of layouts: [String: Reply.Layout]) -> String? {
        layouts.values.sorted { $0.tabID < $1.tabID }
            .lazy.compactMap { $0.root.leaves.first?.pane.cwd }.first
    }
}
