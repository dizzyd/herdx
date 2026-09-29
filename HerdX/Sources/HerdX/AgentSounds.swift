import AppKit

/// Plays herdr's two agent sounds.
///
/// Nothing on the wire says "play a sound": the server sends agent state, and
/// herdr's own client watches that state and decides. So this client has to
/// decide too, by the same rules (`app/actions.rs` upstream) — an agent that
/// becomes blocked always asks for you, and one that finishes only makes a
/// noise if you were not already looking at it.
///
/// The statuses need reading carefully. herdr's detector has one Idle, but the
/// wire splits it: `done` is finished-and-unseen, `idle` is finished-and-seen.
/// A completion is therefore a move to either *from* working or blocked — not
/// the `done` → `idle` that follows merely noticing one.
@MainActor
final class AgentSounds {
    /// Whether to play at all. Tracking continues either way, so turning sound
    /// back on does not then fire for every agent that changed while it was off.
    var isEnabled = true

    /// Whether the screen is locked, asked afresh each time a sound is due.
    ///
    /// Overridden in tests, which have no screen to lock.
    var screenIsLocked: () -> Bool = AgentSounds.screenIsLocked

    /// Whether a cue would actually be worth making: sounds on, and somebody
    /// there to hear them.
    ///
    /// A locked screen means the person is not at the machine, and an agent
    /// finishing to an empty room is just noise in the room. Like `isEnabled`
    /// this only silences — tracking carries on, so unlocking does not then
    /// play back everything that happened while you were away.
    var isAudible: Bool { isEnabled && !screenIsLocked() }

    private enum Cue: String {
        case done, request
    }

    /// Last seen status per agent, per machine.
    ///
    /// Keyed by endpoint as well as pane: pane ids are only unique within a
    /// server, and two machines really do both have a `w1:p1`.
    private var previous: [Int: [String: Snapshot.AgentStatus]] = [:]
    private var players: [Cue: NSSound] = [:]

    /// Notes what a machine's agents are doing, and plays for what changed.
    ///
    /// `focused` means this machine's window is the one in front — the app is
    /// active and this is the endpoint on screen — which is what decides
    /// whether finishing is worth a sound.
    func update(_ snapshot: Snapshot, endpoint: Int, focused: Bool) {
        let before = previous[endpoint] ?? [:]
        var now: [String: Snapshot.AgentStatus] = [:]
        for agent in snapshot.agents {
            now[agent.paneID] = agent.agentStatus
        }
        // Replaced rather than merged, so an agent that goes away takes its
        // entry with it instead of sitting in here for the life of the app.
        previous[endpoint] = now

        for agent in snapshot.agents {
            // First sight of an agent is not a change. Attaching to a session
            // full of finished work should not be a fanfare.
            guard let was = before[agent.paneID], was != agent.agentStatus else { continue }
            switch agent.agentStatus {
            case .blocked:
                play(.request)
            case .done, .idle:
                guard was == .working || was == .blocked else { continue }
                // herdr says nothing about work finishing in front of you: the
                // sound is for the tab you are not looking at.
                let watching = focused && agent.tabID == snapshot.focusedTabID
                if !watching { play(.done) }
            case .working, .unknown:
                break
            }
        }
    }

    /// Forgets a machine's agents, so reattaching starts from silence.
    func forget() {
        previous = [:]
    }

    private func play(_ cue: Cue) {
        guard isAudible else { return }
        if players[cue] == nil {
            // herdr's own audio, shipped in the bundle, so the two clients make
            // the same noise for the same thing. Absent — an unbundled `swift
            // run` — is not worth complaining about every time an agent moves.
            guard
                let url = Bundle.main.url(
                    forResource: cue.rawValue, withExtension: "mp3", subdirectory: "sounds"),
                let sound = NSSound(contentsOf: url, byReference: true)
            else { return }
            players[cue] = sound
        }
        // Restarted rather than overlapped: two agents finishing together is
        // one notification, not a chord.
        players[cue]?.stop()
        players[cue]?.play()
    }

    /// macOS's own answer, rather than watching for `com.apple.screenIsLocked`.
    ///
    /// A notification is a thing you can miss — the screen locked before the
    /// app launched, or a distributed notification dropped — and a missed one
    /// leaves the wrong belief for as long as the screen stays that way. This
    /// is asked only when a sound is already due, so the cost does not matter.
    nonisolated static func screenIsLocked() -> Bool {
        isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    /// Unlocked, the key is not there at all — so absent means unlocked, and
    /// so does a session dictionary that could not be read. Locked, it arrives
    /// as a `CFBoolean` alongside the session's other flags, which is why this
    /// goes through `NSNumber` rather than asking for a `Bool` or an `Int`.
    nonisolated static func isLocked(session: [String: Any]?) -> Bool {
        (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }
}
