import AppKit

/// Keeps the display from sleeping, the way `caffeinate -d` does.
///
/// Not by running `caffeinate`. That tool is a thin wrapper over a power
/// assertion, and Foundation hands out the same one — so this asks for it
/// directly rather than keeping a child process alive to ask on our behalf.
/// Measured against `pmset -g assertions`: a held activity shows up as
/// `PreventUserIdleDisplaySleep`, which is exactly what `caffeinate -d` adds,
/// with a reason beside it saying who asked and why.
///
/// What it does *not* do is keep the Mac awake. `-d` prevents the display
/// going dark on its own; closing the lid still sleeps, and so does anything
/// else that is not idleness. Work on a remote machine was never at risk from
/// a dark screen anyway — what a dark screen costs you is seeing it, and the
/// lock that follows, which is also what silences the agent sounds.
@MainActor
final class StayAwake {
    /// When to hold the display awake.
    enum Mode: String, CaseIterable {
        /// Let the display sleep as the system decides.
        case never
        /// While any agent is working or waiting on you.
        case whileWorking = "while_working"
        /// For as long as HerdX is running, which is `caffeinate -d` with no
        /// conditions on it.
        case always

        var title: String {
            switch self {
            case .never: return "Never"
            case .whileWorking: return "While an agent is working"
            case .always: return "Always"
            }
        }
    }

    var mode: Mode = .never

    /// The assertion, while it is held. Nil means the display may sleep.
    private var token: NSObjectProtocol?
    /// What the held assertion says it is for, so an unchanged reason does
    /// not drop and retake it on every tick.
    private var heldReason: String?

    /// Whether an assertion is held, and what it says. For tests, and for the
    /// probe — `pmset` can confirm the system agrees, but not that this is why.
    var held: String? { heldReason }

    /// An agent worth staying awake for, or nil when there is none.
    ///
    /// Working *or* blocked. Blocked means it is waiting on you, which is the
    /// state where a dark screen costs the most: the screen lock that follows
    /// is what makes `AgentSounds` go quiet, so sleeping through a question is
    /// how you come back an hour later to an agent that asked one immediately.
    static func waitingOn(_ endpoints: [EndpointInfo]) -> String? {
        for endpoint in endpoints {
            for agent in endpoint.snapshot?.agents ?? [] {
                guard agent.agentStatus == .working || agent.agentStatus == .blocked else {
                    continue
                }
                let name = agent.name ?? agent.displayAgent ?? agent.agent ?? "an agent"
                let workspace = endpoint.snapshot?.workspaces
                    .first { $0.workspaceID == agent.workspaceID }?.label
                return [name, "is", "\(agent.agentStatus)"].joined(separator: " ")
                    + (workspace.map { " in \($0)" } ?? "")
            }
        }
        return nil
    }

    /// Whether to hold the display awake, and the reason to give for it.
    ///
    /// Pure, so the rule can be read and tested without a power assertion to
    /// point it at.
    static func reason(for mode: Mode, waitingOn working: String?) -> String? {
        switch mode {
        case .never: return nil
        case .always: return "HerdX is set to keep the display awake"
        case .whileWorking: return working.map { "HerdX: \($0)" }
        }
    }

    /// Takes or drops the assertion to match `mode` and what the agents are
    /// doing. Called every tick; does nothing when nothing has changed.
    func update(endpoints: [EndpointInfo]) {
        apply(Self.reason(for: mode, waitingOn: Self.waitingOn(endpoints)))
    }

    /// Releases it, for a window going away.
    func release() { apply(nil) }

    private func apply(_ reason: String?) {
        guard reason != heldReason else { return }
        if let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
        heldReason = reason
        guard let reason else { return }
        // `idleDisplaySleepDisabled` alone: the system may still sleep, and
        // deciding otherwise on somebody's behalf is a bigger promise than
        // this setting makes.
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled], reason: reason)
    }

    // No `deinit` releasing the assertion. A power assertion belongs to the
    // process that took it and goes when the process does — which is the whole
    // mechanism `caffeinate` works by — so there is nothing here that outlives
    // us, and reaching for the token from a nonisolated deinit is a race the
    // compiler is right to refuse.
}
