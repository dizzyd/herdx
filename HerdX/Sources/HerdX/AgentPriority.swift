import Foundation

/// Orders agents by how much they need you, the way herdr's own panel does.
///
/// The ranking is herdr's, copied rather than invented so the two clients
/// agree about what is most urgent:
///
///     blocked           4
///     finished, unseen  3
///     working           2
///     idle              1
///     unknown           0
///
/// Ties go to whichever changed state most recently, so the thing that just
/// started needing you sits above the thing that has needed you for an hour.
struct AgentPriority: Equatable {
    /// Compared on what is drawn, not on what is remembered.
    ///
    /// `previous` changes whenever any agent on any machine changes state, and
    /// the sidebar rebuilds itself whenever this value differs — which would
    /// destroy a row under the cursor as an unrelated machine's agent ticked
    /// over. Only `seen` and `finishedUnseen` can change what a dot shows.
    static func == (lhs: AgentPriority, rhs: AgentPriority) -> Bool {
        lhs.seen == rhs.seen && lhs.finishedUnseen == rhs.finishedUnseen
    }

    /// Which agents have been looked at since they last changed.
    ///
    /// herdr keeps this itself; the snapshot does not carry it, because it is
    /// about this client's attention rather than the session's state. So it is
    /// tracked here the only way it can be: an agent counts as seen once its
    /// *tab* has been the focused one at or after the change, with the app in
    /// front. By tab rather than by pane because that is what is on screen, and
    /// because the finish sound is suppressed on the same basis — the two are
    /// meant to be answering one question.
    /// Keyed by machine as well as pane: pane ids are only unique within a
    /// server, and two machines really do both have a `w1:p1`.
    private var seen: [String: UInt64] = [:]
    /// The last status seen for each agent, so a *change* can be told from a
    /// state that was already true when this client attached.
    ///
    /// Held per endpoint and replaced wholesale, not merged: a pane that goes
    /// away has to take its history with it, or the next pane handed the same
    /// id inherits it and appears to have finished something.
    private var previous: [Int: [String: Snapshot.AgentStatus]] = [:]
    /// Agents that finished while nobody was looking, by the change that did it.
    ///
    /// Witnessed rather than inferred: an agent that was already idle when the
    /// app started is not news, and without this every relaunch would light up
    /// every finished agent as though it had just happened.
    private var finishedUnseen: [String: UInt64] = [:]

    private func key(_ paneID: String, on endpoint: Int) -> String { "\(endpoint):\(paneID)" }

    /// Records what each machine's agents are doing, and what you have looked
    /// at. Call for every endpoint whenever snapshots land.
    ///
    /// `watching` is whether this machine's panes are actually in front of you —
    /// the app is active and this is the endpoint on screen. The server has its
    /// own idea of seen, but it counts a pane as looked at while the app sits
    /// behind an editor, which is how a finish you were away for arrives
    /// already acknowledged.
    mutating func observe(snapshot: Snapshot, endpoint: Int, watching: Bool) {
        let before = previous[endpoint] ?? [:]
        previous[endpoint] = Dictionary(
            snapshot.agents.map { ($0.paneID, $0.agentStatus) }, uniquingKeysWith: { first, _ in first })

        for agent in snapshot.agents {
            let id = key(agent.paneID, on: endpoint)
            let was = before[agent.paneID]
            let finished = agent.agentStatus == .idle || agent.agentStatus == .done
            if finished, was == .working || was == .blocked {
                finishedUnseen[id] = agent.stateChangeSeq
            }
            // Everything in the focused tab is on screen, which is the same
            // reason the finish sound stays quiet for it.
            if watching, agent.tabID == snapshot.focusedTabID {
                seen[id] = agent.stateChangeSeq
                finishedUnseen[id] = nil
            }
        }

        // A pane that is gone keeps nothing here. Left alone these grow for the
        // life of the process, and a reused id would read as its predecessor.
        let live = Set(snapshot.agents.map { key($0.paneID, on: endpoint) })
        let mine = "\(endpoint):"
        seen = seen.filter { !$0.key.hasPrefix(mine) || live.contains($0.key) }
        finishedUnseen = finishedUnseen.filter { !$0.key.hasPrefix(mine) || live.contains($0.key) }
    }

    /// Drops everything, for a session that is being stood up again.
    ///
    /// The keys carry an endpoint *index*, and the machine at a given index is
    /// not the same machine after a session switch or after the machines are
    /// attached — so carrying this across a rebuild would answer questions
    /// about one server with another server's history.
    mutating func forget() {
        seen = [:]
        previous = [:]
        finishedUnseen = [:]
    }

    func hasSeen(_ agent: Snapshot.Agent, on endpoint: Int) -> Bool {
        (seen[key(agent.paneID, on: endpoint)] ?? 0) >= agent.stateChangeSeq
    }

    /// The status to draw, rather than the one the wire carries.
    ///
    /// The server calls a finish *seen* as soon as its pane is the focused one
    /// in the session — which it can be while the app sits behind an editor and
    /// nobody is looking at all. So a finish you were away for arrives as
    /// `idle`, and the loud "ready" state never appears.
    ///
    /// This client already disagrees on that point everywhere except the dot:
    /// the row beside it says "waiting" for exactly these agents. `seen` here
    /// means the pane was in front of *you*, so an unseen finish is `done` and
    /// a seen one is `idle`, and the dot finally agrees with its own label.
    func displayStatus(_ agent: Snapshot.Agent, on endpoint: Int) -> Snapshot.AgentStatus {
        switch agent.agentStatus {
        case .idle, .done:
            if hasSeen(agent, on: endpoint) { return .idle }
            // `done` on the wire is the server's own "nobody has looked at
            // this", which is worth believing; beyond that, only a finish this
            // client watched happen counts.
            let witnessed = finishedUnseen[key(agent.paneID, on: endpoint)] == agent.stateChangeSeq
            return agent.agentStatus == .done || witnessed ? .done : .idle
        case .working, .blocked, .unknown: return agent.agentStatus
        }
    }

    /// What one dot says about a group of agents — a tab, a workspace, a whole
    /// machine — which is whatever the most urgent of them is saying.
    ///
    /// `fallback` covers a group with no agents in it at all, where the server's
    /// own status for the row is the only thing worth showing.
    func status(
        of agents: [Snapshot.Agent], on endpoint: Int, fallback: Snapshot.AgentStatus
    ) -> Snapshot.AgentStatus {
        guard !agents.isEmpty else { return fallback }
        let shown = agents.map { displayStatus($0, on: endpoint) }
        // The order is `rank`'s, which is herdr's: a finish nobody has seen
        // outranks work still in progress, because it is the one asking for
        // you. Checking working first would hide the very thing this is for.
        if shown.contains(.blocked) { return .blocked }
        if shown.contains(.done) { return .done }
        if shown.contains(.working) { return .working }
        // Not `.unknown`: a group whose agents are all unclassified still has
        // whatever the row itself reported, and falling through to unknown drew
        // an online machine the same grey as a disconnected one.
        return shown.contains(.idle) ? .idle : fallback
    }

    /// herdr's attention ranking.
    ///
    /// Ranked on the status that is drawn, not the one on the wire. These
    /// disagree, and taking the wire's word for it put every agent this client
    /// had never focused into the "finished, unseen" rank — so after a relaunch
    /// a machine's whole history of finished agents sorted *above* the one
    /// actually working. `displayStatus` already knows the difference between a
    /// finish that happened while you were away and one that was over before
    /// the app started.
    func rank(_ agent: Snapshot.Agent, on endpoint: Int) -> Int {
        switch displayStatus(agent, on: endpoint) {
        case .blocked: return 4
        case .done: return 3
        case .working: return 2
        case .idle: return 1
        case .unknown: return 0
        }
    }

    /// Orders whatever carries an agent, most in need of you first.
    ///
    /// Generic over the row rather than over agents alone: an agent has to be
    /// carried alongside the machine it is on, and re-finding that machine by
    /// pane id afterwards would match the wrong one.
    func ordered<Row>(
        _ rows: [Row], agent: (Row) -> Snapshot.Agent, endpoint: (Row) -> Int
    ) -> [Row] {
        rows.sorted { left, right in
            let a = rank(agent(left), on: endpoint(left))
            let b = rank(agent(right), on: endpoint(right))
            if a != b { return a > b }
            return agent(left).stateChangeSeq > agent(right).stateChangeSeq
        }
    }

    /// What a row says about why it is where it is.
    ///
    /// From the drawn status, like the dot it sits beside. Read off the wire it
    /// said "waiting" next to a plain idle dot, for every agent this client had
    /// simply never focused — which is the same disagreement `displayStatus`
    /// exists to settle.
    func reason(_ agent: Snapshot.Agent, on endpoint: Int) -> String {
        switch displayStatus(agent, on: endpoint) {
        case .blocked: return "needs you"
        case .working: return "working"
        case .done: return "finished"
        case .idle: return "idle"
        case .unknown: return ""
        }
    }
}
