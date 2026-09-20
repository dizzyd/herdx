import Foundation

/// How long each workspace has been doing nothing.
///
/// A clock this client keeps itself, for the same reason `AgentPriority` keeps
/// one: herdr's snapshot carries no time at all, and `state_change_seq` is a
/// counter — a quiet night does not move it, so a difference of three could be
/// a minute ago or a week ago. The only way to know how long a workspace has
/// been quiet is to notice when it stopped.
///
/// Deliberately **not** persisted. Restoring it would mean an app that has been
/// closed over a weekend wakes up believing every workspace has been idle for
/// three days, and hibernating the lot on launch. Forgetting on relaunch only
/// ever delays hibernation, which is the direction this should fail in.
struct WorkspaceActivity {
    /// How long a workspace must be quiet before it is a candidate.
    ///
    /// Longer than `AgentPriority.longIdleAfter`, which only reorders a list:
    /// this ends processes. Eight hours is a working day — long enough that a
    /// workspace reaching it was not touched today at all.
    static let idleAfter: TimeInterval = 8 * 60 * 60

    private struct Activity {
        var at: Date
        /// False while all this records is when the workspace was first seen.
        ///
        /// A workspace already quiet when the app started has been quiet for an
        /// unknown time — five minutes or five days, and nothing on the wire
        /// says which. `AgentPriority` records that guess as a guess and lets
        /// it settle a row in the middle of a list; here the stakes are a
        /// process, so an unwitnessed silence never counts at all.
        var witnessed: Bool
    }

    private var activity: [String: Activity] = [:]
    /// Last seen agent status per pane, per endpoint, so a *change* can be told
    /// from a state that was already true when this client attached.
    private var previous: [Int: [String: Snapshot.AgentStatus]] = [:]
    /// Last seen pane count per workspace, so splitting or closing a pane
    /// counts as use even when no agent is involved.
    private var shape: [Int: [String: Int]] = [:]

    private func key(_ workspaceID: String, on endpoint: Int) -> String {
        "\(endpoint):\(workspaceID)"
    }

    /// Records what each workspace is doing. Call for every endpoint whenever
    /// snapshots land.
    ///
    /// `watching` is whether this machine is actually in front of you — the app
    /// is active and this is the endpoint on screen — which is what makes
    /// looking at a workspace count as using it.
    ///
    /// `now` is a parameter so the threshold can be tested without waiting
    /// eight hours for it.
    mutating func observe(
        snapshot: Snapshot, endpoint: Int, watching: Bool, now: Date = Date()
    ) {
        // Nil, not empty: never having observed this machine is different from
        // having observed it with nothing on it.
        let beforeStatus = previous[endpoint]
        let beforeShape = shape[endpoint]

        var agentsByWorkspace: [String: [Snapshot.Agent]] = [:]
        for agent in snapshot.agents {
            agentsByWorkspace[agent.workspaceID, default: []].append(agent)
        }
        var panesByWorkspace: [String: Int] = [:]
        let workspaceOfTab = Dictionary(
            snapshot.tabs.map { ($0.tabID, $0.workspaceID) }, uniquingKeysWith: { a, _ in a })
        for pane in snapshot.panes {
            guard let workspace = workspaceOfTab[pane.tabID] else { continue }
            panesByWorkspace[workspace, default: 0] += 1
        }

        for workspace in snapshot.workspaces {
            let id = workspace.workspaceID
            let agents = agentsByWorkspace[id] ?? []

            // Three readings of "in use", and the clock needs all three.
            // Running has to be checked every tick rather than on a transition,
            // because nothing moves while an agent works — so an hour of work
            // would otherwise read as an hour of silence.
            let running = agents.contains { $0.agentStatus == .working || $0.agentStatus == .blocked }
            let statusChanged = agents.contains { agent in
                guard let was = beforeStatus?[agent.paneID] else { return false }
                return was != agent.agentStatus
            }
            // A pane appearing or going away is someone working, and it is the
            // only signal a workspace with no agent in it ever gives.
            let shapeChanged =
                beforeShape.map { $0[id] != panesByWorkspace[id] } ?? false
            // Looking at it counts: a workspace you have open is one you are
            // working in, whether or not anything is running.
            let looking = watching && workspace.focused

            var record = activity[key(id, on: endpoint)] ?? Activity(at: now, witnessed: false)
            if running || statusChanged || shapeChanged || looking {
                record.at = now
                record.witnessed = true
            }
            activity[key(id, on: endpoint)] = record
        }

        previous[endpoint] = Dictionary(
            snapshot.agents.map { ($0.paneID, $0.agentStatus) }, uniquingKeysWith: { a, _ in a })
        shape[endpoint] = panesByWorkspace

        // A workspace that is gone keeps nothing here, or a reused id inherits
        // its predecessor's silence.
        let live = Set(snapshot.workspaces.map { key($0.workspaceID, on: endpoint) })
        let mine = "\(endpoint):"
        activity = activity.filter { !$0.key.hasPrefix(mine) || live.contains($0.key) }
    }

    /// How long a workspace has been quiet, or nil when that is not known —
    /// which includes quiet since before this client attached.
    func quietFor(_ workspaceID: String, on endpoint: Int, now: Date = Date()) -> TimeInterval? {
        guard let record = activity[key(workspaceID, on: endpoint)], record.witnessed else {
            return nil
        }
        return now.timeIntervalSince(record.at)
    }

    /// The workspaces that may be hibernated, quietest first.
    ///
    /// Every rule here is a refusal, because the cost of hibernating something
    /// that was in use is far higher than the cost of leaving something running.
    func candidates(
        in snapshot: Snapshot, on endpoint: Int, now: Date = Date(),
        after: TimeInterval = WorkspaceActivity.idleAfter
    ) -> [String] {
        var agentsByWorkspace: [String: [Snapshot.Agent]] = [:]
        for agent in snapshot.agents {
            agentsByWorkspace[agent.workspaceID, default: []].append(agent)
        }

        return snapshot.workspaces.filter { workspace in
            // Where you are is never a candidate, however long the clock says.
            guard !workspace.focused else { return false }
            let agents = agentsByWorkspace[workspace.workspaceID] ?? []
            // Only workspaces with an agent in them, for now. A workspace of
            // plain shells has no conversation to preserve — only a cwd and a
            // layout — so ending it buys little and surprises somebody.
            guard !agents.isEmpty else { return false }
            guard !agents.contains(where: { $0.agentStatus == .working || $0.agentStatus == .blocked })
            else { return false }
            guard let quiet = quietFor(workspace.workspaceID, on: endpoint, now: now) else {
                return false
            }
            return quiet >= after
        }
        .sorted {
            (quietFor($0.workspaceID, on: endpoint, now: now) ?? 0)
                > (quietFor($1.workspaceID, on: endpoint, now: now) ?? 0)
        }
        .map(\.workspaceID)
    }

    /// Drops everything, for a session being stood up again.
    ///
    /// The keys carry an endpoint *index*, and the machine at a given index is
    /// not the same machine after a session switch — so carrying this across a
    /// rebuild would answer questions about one server with another's history.
    mutating func forget() {
        activity = [:]
        previous = [:]
        shape = [:]
    }
}
