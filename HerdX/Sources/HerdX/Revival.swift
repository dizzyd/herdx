import AppKit

/// Puts a hibernated workspace back: the shape first, then the agents into it.
///
/// A class rather than a chain of nested closures because the sequence is long
/// and each step needs what the last one replied — the created workspace's tab,
/// then the pane ids `layout.apply` handed back, then one `agent.start` per
/// pane. Written as nesting it was unreadable by the third step.
///
/// The panes are made as plain shells and the agents submitted into them
/// afterwards, never as a `command` on the applied tree. A pane launched with
/// an argv *is* that process, with no shell under it, and then it reports its
/// foreground process group as its own shell pid — so a pane busy working would
/// read as idle, and the test that decides what may be hibernated next time
/// would quietly start lying.
@MainActor
final class Revival {
    struct Failure: Error, Equatable {
        let reason: String
        /// True when a half-made workspace is still there after this failed.
        ///
        /// Only then must the record be dropped — a row describing a workspace
        /// that is plainly running would be a lie. Ordinarily a failure undoes
        /// what it made and this stays false, so the record survives and the
        /// revive can be tried again.
        var workspaceExists = false
    }

    /// How long to wait for a freshly made pane to reach a prompt.
    ///
    /// Asked rather than slept through: `agent.start` refuses a pane that is
    /// not an available shell, and a fixed wait is either too short on a loaded
    /// machine or wasted on an idle one.
    private static let promptTries = 40
    private static let promptInterval: TimeInterval = 0.25
    /// How many readings in a row must agree before the pane counts as ready.
    ///
    /// One is not enough: a shell is momentarily alone in its process group
    /// *before* it has run its startup files, so a single reading taken at the
    /// wrong instant says "ready" and `agent.start` then lands in the middle of
    /// the startup it had not begun. Measured on a shell whose rc file
    /// initialises conda.
    private static let promptSettles = 3
    /// How long to wait for herdr to notice the agent afterwards.
    private static let agentTries = 40

    private let record: Hibernated
    private let socket: String?
    private let finish: (Result<Void, Error>) -> Void

    private var workspaceID: String?
    /// Each stored tab beside the tree that came back from applying it, which
    /// is where the new pane ids are.
    private var applied: [(tab: Hibernated.Tab, layout: Reply.Layout)] = []
    private var pendingAgents: [(pane: String, agent: Hibernated.Agent)] = []
    /// So a second failure on the way out does not close a second workspace.
    private var failed = false

    init(
        record: Hibernated, socket: String?,
        then finish: @escaping (Result<Void, Error>) -> Void
    ) {
        self.record = record
        self.socket = socket
        self.finish = finish
    }

    func start() {
        ask(.createWorkspace(cwd: record.cwd, label: record.label), Reply.WorkspaceCreated.self) {
            [weak self] created in
            guard let self else { return }
            self.workspaceID = created.workspace.workspaceID
            self.applyTab(0, intoExisting: created.tab.tabID)
        }
    }

    /// Applies one stored tab, then the next.
    ///
    /// The first replaces the tab the new workspace came with; the rest are
    /// added to it. Sent one at a time rather than together because each reply
    /// carries the pane ids that tab's agents have to be started in.
    private func applyTab(_ index: Int, intoExisting tabID: String?) {
        guard index < record.tabs.count else { return startAgents(0) }
        let tab = record.tabs[index]
        ask(
            .layoutApply(
                tab: tabID, workspace: tabID == nil ? workspaceID : nil, label: tab.label,
                // Stripped again on the way out. The stored tree should carry
                // no commands, but a record written by an older build might.
                root: tab.root.withoutCommands),
            Reply.LayoutApplied.self
        ) { [weak self] result in
            guard let self else { return }
            self.applied.append((tab: tab, layout: result.layout))
            self.applyTab(index + 1, intoExisting: nil)
        }
    }

    /// Matches each stored agent to the pane that is now in its place.
    private func startAgents(_ index: Int) {
        if index == 0 {
            for (tab, layout) in applied {
                for agent in tab.agents {
                    guard let pane = layout.root.leaf(at: agent.path)?.paneID else {
                        // The tree came back a different shape, which means the
                        // agent would be started somewhere it never was.
                        return fail("the layout came back without the pane \(agent.agent) was in")
                    }
                    pendingAgents.append((pane: pane, agent: agent))
                }
            }
        }
        guard index < pendingAgents.count else { return finishUp() }

        let next = pendingAgents[index]
        guard
            let line = AgentResume.commandLine(
                agent: next.agent.agent, kind: next.agent.kind, value: next.agent.value)
        else {
            return fail("\(next.agent.agent) has no resume form here")
        }
        waitForPrompt(in: next.pane, tries: Self.promptTries) { [weak self] ready in
            guard let self else { return }
            guard ready else {
                return self.fail(
                    "\(next.pane) never reached a prompt to start \(next.agent.agent) in")
            }
            self.ask(.paneSendText(pane: next.pane, text: line + "\n"), Reply.Empty.self) { _ in
                // A submitted line says nothing about whether it worked, so
                // wait for herdr to see an agent in the pane. Without this a
                // missing binary would be reported as a successful revive.
                self.waitForAgent(
                    in: next.pane, called: next.agent.agent, tries: Self.agentTries
                ) { appeared in
                    guard appeared else {
                        return self.fail("\(next.agent.agent) did not start in \(next.pane)")
                    }
                    self.startAgents(index + 1)
                }
            }
        }
    }

    /// Polls until herdr has an agent in the pane.
    ///
    /// `agent.start` used to answer this question, and answering it here is
    /// the price of submitting the line ourselves — which is what lets the
    /// command be cleared off the screen before the agent draws over it.
    private func waitForAgent(
        in pane: String, called agent: String, tries: Int, then act: @escaping (Bool) -> Void
    ) {
        guard tries > 0 else { return act(false) }
        LocalAPI.send(.paneGet(pane), socket: socket) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .success(let body) = result,
                    case .success(let info) = Reply.decode(Reply.PaneInfo.self, from: body),
                    info.pane.holdsAgent
                {
                    return act(true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.promptInterval) {
                    MainActor.assumeIsolated {
                        self.waitForAgent(
                            in: pane, called: agent, tries: tries - 1, then: act)
                    }
                }
            }
        }
    }

    /// Polls until the pane has been a shell at a prompt for several readings.
    private func waitForPrompt(
        in pane: String, tries: Int, settled: Int = 0, then act: @escaping (Bool) -> Void
    ) {
        guard tries > 0 else { return act(false) }
        LocalAPI.send(.paneProcessInfo(pane), socket: socket) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                var ready = false
                if case .success(let body) = result,
                    case .success(let info) = Reply.decode(Reply.ProcessInfo.self, from: body)
                {
                    ready = info.processInfo.isIdleShell
                }
                // A run of agreeing readings, not a single one — and the run
                // starts again from zero the moment the shell is busy.
                let agreed = ready ? settled + 1 : 0
                if agreed >= Self.promptSettles { return act(true) }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.promptInterval) {
                    MainActor.assumeIsolated {
                        self.waitForPrompt(
                            in: pane, tries: tries - 1, settled: agreed, then: act)
                    }
                }
            }
        }
    }

    /// Zoom and focus, neither of which is worth failing a revive over.
    ///
    /// `layout.apply` reports zoom on the way out and takes no parameter for it
    /// on the way in, so it is put back with `pane.zoom`. If either of these is
    /// refused the workspace is still back, with its agents in it.
    private func finishUp() {
        for (tab, layout) in applied where tab.zoomed {
            if let pane = layout.root.leaves.first?.pane.paneID {
                LocalAPI.send(.zoomPaneWithID(pane), socket: socket) { _ in }
            }
        }
        if let first = applied.first,
            let path = first.tab.focused,
            let pane = first.layout.root.leaf(at: path)?.paneID
        {
            LocalAPI.send(.focusPane(pane), socket: socket) { _ in }
        }
        finish(.success(()))
    }

    /// Gives up, putting back what was made on the way.
    ///
    /// The workspace is closed again rather than left standing. It is seconds
    /// old and holds nothing of anyone's, while the record is the only thing
    /// that still knows which conversations were in it — so the one to keep is
    /// the record. Leaving the husk and dropping the record was the first way
    /// round, and it cost two real workspaces their session ids.
    private func fail(_ reason: String) {
        guard !failed else { return }
        failed = true
        guard let workspaceID else {
            return finish(.failure(Failure(reason: reason)))
        }
        LocalAPI.send(.closeWorkspace(workspaceID), socket: socket) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                let undone: Bool
                if case .success(let body) = result,
                    case .success = Reply.decode(Reply.Empty.self, from: body)
                {
                    undone = true
                } else {
                    undone = false
                }
                self.finish(
                    .failure(
                        Failure(
                            reason: undone ? reason : "\(reason) (and it is still open)",
                            workspaceExists: !undone)))
            }
        }
    }

    private func ask<Result: Decodable>(
        _ command: Command, _ type: Result.Type, _ then: @escaping (Result) -> Void
    ) {
        LocalAPI.send(command, socket: socket) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Routed through `fail` so every way out carries whether the
                // workspace is already back.
                switch result {
                case .failure(let failure):
                    self.fail(failure.reason)
                case .success(let body):
                    switch Reply.decode(type, from: body) {
                    case .failure(let failure): self.fail("\(command.method): \(failure.text)")
                    case .success(let value): then(value)
                    }
                }
            }
        }
    }
}
