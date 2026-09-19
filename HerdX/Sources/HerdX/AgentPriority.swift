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
///
/// Rank alone is not enough once a machine has been up for a week: everything
/// finished settles into one long undifferentiated tail of "idle", and the two
/// agents you were working on this morning are somewhere in it. So agents are
/// also banded by when they were last doing something — see `Tier` — which is a
/// clock this client has to keep itself, because the snapshot carries none.
struct AgentPriority: Equatable {
    /// How long an agent must go untouched before it stops counting as work in
    /// hand.
    ///
    /// Hours, not minutes. The point of the band is to separate what you are
    /// working on today from what you finished last week, and a threshold short
    /// enough to fire over lunch would reorder the list while you were reading
    /// it. Four is the near end of what feels right — long enough to survive a
    /// morning spent elsewhere, short enough that yesterday's agents are below
    /// the fold by the time you sit down.
    static let longIdleAfter: TimeInterval = 4 * 60 * 60

    /// How long after you last touched an agent it still counts as where you
    /// are working.
    ///
    /// The top band is the live work area, not a list of complaints, and an
    /// agent you are dealing with belongs in it whether or not it still wants
    /// anything. Without this the band was read off attention state, so
    /// clicking a finished agent dropped it out of the band at the very moment
    /// you started working on it — the one interaction that proves it belongs
    /// there. Half an hour is long enough to click away and come back.
    static let activeFor: TimeInterval = 30 * 60

    /// Which band of the agents list a row belongs in.
    ///
    /// Deliberately not folded into `rank`: rank answers "what needs me", and
    /// the clock must never override that. An agent blocked since yesterday is
    /// still blocked, so only agents drawn as idle are ever aged down.
    enum Tier: Int, Comparable {
        /// Work in hand: running, asking for you, or touched a moment ago.
        case active = 2
        /// Idle, but recently enough to still be what you are doing.
        case idle = 1
        /// Idle for long enough to be background rather than work in hand.
        case longIdle = 0

        var title: String {
            switch self {
            case .active: return "Active"
            case .idle: return "Idle"
            case .longIdle: return "Long idle"
            }
        }

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// When an agent was last doing something, and whether that was watched.
    private struct Activity {
        /// When the agent was last in use, by any of the three readings of it.
        ///
        /// A liveness clock: it is pushed forward on every tick an agent spends
        /// running, which is what makes an hour's work stop reading as an hour
        /// of silence. That also makes it useless for asking which of two
        /// running agents started most recently — see `changedAt`.
        var at: Date
        /// False when all this records is when the agent was first seen.
        ///
        /// An agent already idle when the app started has been idle for an
        /// unknown time — five minutes or five days, and nothing on the wire
        /// says which. Guessing "just now" would float every stale agent to the
        /// top of the list after every relaunch, and guessing "ages ago" would
        /// bury the one you quit the app in the middle of. So the guess is
        /// recorded as a guess: it places the row in the middle band and says
        /// nothing about age, and ages out on its own if it stays quiet.
        var witnessed: Bool
        /// When the agent's state last changed, as watched from here.
        ///
        /// Kept apart from `at` because the two answer different questions, and
        /// using the liveness clock for both got the wrong answer: `at` is
        /// restamped every tick for a running agent, and the endpoints are
        /// observed in a loop, each taking its own reading of the clock a
        /// moment after the last. So two agents blocked on two machines were
        /// ordered by which machine was polled last — putting yesterday's block
        /// above one that happened a second ago.
        ///
        /// Nil until a change is actually witnessed — which includes a pane
        /// turning up on a machine already being watched, because an agent that
        /// launches straight into blocked never transitions but has plainly
        /// just started.
        ///
        /// Nil therefore means one thing: it has been this way since before
        /// this client attached. That is not "unknown" — it is older than
        /// anything witnessed since, which is what lets the ordering put a
        /// witnessed change above it.
        var changedAt: Date?
    }

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
    /// When each agent was last doing something.
    ///
    /// Kept here because there is nowhere else to get it: herdr's snapshot has
    /// no clock in it at all, and `state_change_seq` is a counter — a quiet
    /// night moves it not at all, so a difference of three could be a minute
    /// ago or a week ago. The only way to know how long an agent has been quiet
    /// is to notice when it stopped, which means writing down the time as
    /// snapshots go by.
    private var activity: [String: Activity] = [:]

    private func key(_ paneID: String, on endpoint: Int) -> String { "\(endpoint):\(paneID)" }

    /// Records what each machine's agents are doing, and what you have looked
    /// at. Call for every endpoint whenever snapshots land.
    ///
    /// `watching` is whether this machine's panes are actually in front of you —
    /// the app is active and this is the endpoint on screen. The server has its
    /// own idea of seen, but it counts a pane as looked at while the app sits
    /// behind an editor, which is how a finish you were away for arrives
    /// already acknowledged.
    ///
    /// `now` is a parameter so the banding can be tested without waiting four
    /// hours for it.
    mutating func observe(snapshot: Snapshot, endpoint: Int, watching: Bool, now: Date = Date()) {
        // Nil, not empty: never having observed this machine is different from
        // having observed it with no agents on it, and a pane that turns up on
        // a machine already being watched really did just appear.
        let before = previous[endpoint]
        previous[endpoint] = Dictionary(
            snapshot.agents.map { ($0.paneID, $0.agentStatus) }, uniquingKeysWith: { first, _ in first })

        for agent in snapshot.agents {
            let id = key(agent.paneID, on: endpoint)
            let was = before?[agent.paneID]
            let finished = agent.agentStatus == .idle || agent.agentStatus == .done
            if finished, was == .working || was == .blocked {
                finishedUnseen[id] = agent.stateChangeSeq
            }
            // Everything in the focused tab is on screen, which is the same
            // reason the finish sound stays quiet for it.
            let looking = watching && agent.tabID == snapshot.focusedTabID
            if looking {
                seen[id] = agent.stateChangeSeq
                finishedUnseen[id] = nil
            }

            // Three different things count as an agent being in use, and the
            // list needs all three. Running is the obvious one — and it has to
            // be checked every tick rather than on a transition, because the
            // counter does not move while an agent works, so an hour's work
            // would otherwise read as an hour of silence. Changing state covers
            // the moment it stopped, which is the time "idle 3h" is counted
            // from. And looking at it counts too: the list is meant to answer
            // "what am I working on", and a pane you have open is one of them
            // whether or not anything is running in it.
            let running = agent.agentStatus == .working || agent.agentStatus == .blocked
            let changed = was != nil && was != agent.agentStatus
            var record = activity[id] ?? Activity(at: now, witnessed: false)
            // The transition is noted on its own, and only when one is actually
            // watched: this is the moment an agent started needing you, and it
            // must not drift forward for every tick it goes on needing you.
            let appeared = before != nil && was == nil
            if changed || appeared { record.changedAt = now }
            if running || changed || looking {
                record.at = now
                record.witnessed = true
            }
            activity[id] = record
        }

        // A pane that is gone keeps nothing here. Left alone these grow for the
        // life of the process, and a reused id would read as its predecessor.
        let live = Set(snapshot.agents.map { key($0.paneID, on: endpoint) })
        let mine = "\(endpoint):"
        seen = seen.filter { !$0.key.hasPrefix(mine) || live.contains($0.key) }
        finishedUnseen = finishedUnseen.filter { !$0.key.hasPrefix(mine) || live.contains($0.key) }
        activity = activity.filter { !$0.key.hasPrefix(mine) || live.contains($0.key) }
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
        activity = [:]
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

    /// Whether an agent is asking for anything.
    ///
    /// One that is not still has a place in the top band, by the clock — but
    /// one that is stays there however long it has been asking, which is the
    /// floor under everything the clock decides.
    private static func isQuiet(_ status: Snapshot.AgentStatus) -> Bool {
        switch status {
        case .working, .blocked, .done: return false
        case .idle, .unknown: return true
        }
    }

    /// Which band an agent belongs in.
    ///
    /// The bands are recency, with one floor under them: an agent that is
    /// running, or that is asking for you, is where you are working whatever
    /// the clock says. Everything else is placed on how long ago you last had
    /// anything to do with it — including an agent that has finished and been
    /// seen, which is not asking for anything but is very often the thing in
    /// front of you.
    func tier(_ agent: Snapshot.Agent, on endpoint: Int, now: Date = Date()) -> Tier {
        guard Self.isQuiet(displayStatus(agent, on: endpoint)) else { return .active }
        // An agent nothing is known about yet sits in the middle band rather
        // than at the bottom: claiming it is stale is a claim, and this cannot
        // back it up. Nor is it put in the top band, which is for work in hand.
        guard let last = activity[key(agent.paneID, on: endpoint)] else { return .idle }
        let quiet = now.timeIntervalSince(last.at)
        // Only a time we actually watched may promote. First sight records when
        // this client attached, which is a guess about an agent that may have
        // been idle for a week — and reading it as "touched just now" would put
        // every one of them in the work area for half an hour after a relaunch.
        if last.witnessed, quiet < Self.activeFor { return .active }
        return quiet >= Self.longIdleAfter ? .longIdle : .idle
    }

    /// How long an agent has been quiet, for the row to say so — or nothing,
    /// when it has not been quiet long enough to be worth saying.
    ///
    /// Coarse on purpose, and never in minutes. The sidebar rebuilds itself
    /// when the text of a row changes, and a caption counting minutes is a list
    /// that rebuilds every minute — which destroys the row under the pointer
    /// mid-click. Rounded to hours it changes at most hourly, and an agent
    /// quiet for less than an hour is recent by any reading, so the caption has
    /// nothing to add.
    func quietFor(_ agent: Snapshot.Agent, on endpoint: Int, now: Date = Date()) -> String? {
        guard Self.isQuiet(displayStatus(agent, on: endpoint)),
            let last = activity[key(agent.paneID, on: endpoint)], last.witnessed
        else { return nil }
        let hours = Int(now.timeIntervalSince(last.at) / 3600)
        guard hours >= 1 else { return nil }
        return hours < 24 ? "\(hours)h" : "\(hours / 24)d"
    }

    /// The moment a tie in the ordering turns on, or nothing when this client
    /// never watched it happen.
    ///
    /// Nothing rather than a guess: the only time available for an agent that
    /// has never changed under our watch is when we first saw it, and the
    /// endpoints are first seen a millisecond apart in polling order — so
    /// falling back to it would sort by which machine attached last while
    /// looking like it had sorted by recency.
    private func tiebreak(
        _ agent: Snapshot.Agent, on endpoint: Int, transition: Bool
    ) -> Date? {
        guard let record = activity[key(agent.paneID, on: endpoint)] else { return nil }
        if transition { return record.changedAt }
        return record.witnessed ? record.at : nil
    }

    /// Orders whatever carries an agent, most in need of you first.
    ///
    /// Generic over the row rather than over agents alone: an agent has to be
    /// carried alongside the machine it is on, and re-finding that machine by
    /// pane id afterwards would match the wrong one.
    ///
    /// The result is in band order as well as rank order, so a caller can walk
    /// it once and put a heading in wherever the band changes.
    func ordered<Row>(
        _ rows: [Row], agent: (Row) -> Snapshot.Agent, endpoint: (Row) -> Int,
        now: Date = Date()
    ) -> [Row] {
        rows.sorted { left, right in
            let leftTier = tier(agent(left), on: endpoint(left), now: now)
            let rightTier = tier(agent(right), on: endpoint(right), now: now)
            if leftTier != rightTier { return leftTier > rightTier }
            let a = rank(agent(left), on: endpoint(left))
            let b = rank(agent(right), on: endpoint(right))
            if a != b { return a > b }
            // Within a band, whatever happened most recently — but "most
            // recently" means a different clock in each band, and reading it
            // off the wrong one is how a day-old block sorted above a fresh
            // one. An active agent is ordered by when it *became* active, since
            // its liveness clock says "now" for as long as it runs; a quiet one
            // by when you last had anything to do with it, which is the whole
            // question that band is asking.
            //
            // Both fall back to `state_change_seq`, which is only meaningful
            // within one server — but that is the honest answer when this
            // client never watched either agent change, and it is still right
            // for two agents on the same machine.
            let byTransition = leftTier == .active
            let leftWhen = tiebreak(agent(left), on: endpoint(left), transition: byTransition)
            let rightWhen = tiebreak(agent(right), on: endpoint(right), transition: byTransition)
            switch (leftWhen, rightWhen) {
            case let (left?, right?) where left != right: return left > right
            // One side watched and the other not is still an answer, and the
            // useful one: anything this client watched happen, happened after it
            // attached, and anything it did not has been that way since before.
            case (.some, .none): return true
            case (.none, .some): return false
            default: return agent(left).stateChangeSeq > agent(right).stateChangeSeq
            }
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
