import Foundation

/// Orders agents by how much they need you, the way herdr's own panel does.
///
/// The ranking is herdr's, copied rather than invented so the two clients
/// agree about what is most urgent:
///
///     blocked           4
///     idle, unseen      3
///     working           2
///     idle, seen        1
///     unknown           0
///
/// Ties go to whichever changed state most recently, so the thing that just
/// started needing you sits above the thing that has needed you for an hour.
struct AgentPriority {
    /// Which agents have been looked at since they last changed.
    ///
    /// herdr keeps this itself; the snapshot does not carry it, because it is
    /// about this client's attention rather than the session's state. So it is
    /// tracked here the only way it can be: an agent counts as seen once its
    /// pane has been the focused one at or after the change.
    /// Keyed by machine as well as pane: pane ids are only unique within a
    /// server, and two machines really do both have a `w1:p1`.
    private var seen: [String: UInt64] = [:]

    private func key(_ paneID: String, on endpoint: Int) -> String { "\(endpoint):\(paneID)" }

    /// Records what is on screen. Call whenever a snapshot lands.
    mutating func note(snapshot: Snapshot, endpoint: Int) {
        guard let focused = snapshot.focusedPaneID else { return }
        for agent in snapshot.agents where agent.paneID == focused {
            seen[key(agent.paneID, on: endpoint)] = agent.stateChangeSeq
        }
    }

    func hasSeen(_ agent: Snapshot.Agent, on endpoint: Int) -> Bool {
        (seen[key(agent.paneID, on: endpoint)] ?? 0) >= agent.stateChangeSeq
    }

    /// herdr's attention ranking.
    func rank(_ agent: Snapshot.Agent, on endpoint: Int) -> Int {
        switch agent.agentStatus {
        case .blocked: return 4
        case .working: return 2
        case .idle, .done: return hasSeen(agent, on: endpoint) ? 1 : 3
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
    func reason(_ agent: Snapshot.Agent, on endpoint: Int) -> String {
        switch agent.agentStatus {
        case .blocked: return "needs you"
        case .working: return "working"
        case .done: return hasSeen(agent, on: endpoint) ? "done" : "finished"
        case .idle: return hasSeen(agent, on: endpoint) ? "idle" : "waiting"
        case .unknown: return ""
        }
    }
}
