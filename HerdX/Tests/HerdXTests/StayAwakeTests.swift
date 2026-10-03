import XCTest

@testable import HerdX

/// When HerdX holds the display awake, and what it says it is for.
///
/// The assertion itself is the system's to grant, and `pmset` can confirm it
/// was granted — but not that it was granted for the right reason, or dropped
/// when the reason went away. That part is a rule, and this is the rule.
@MainActor
final class StayAwakeTests: XCTestCase {
    private func endpoint(_ agents: [(String, String)], label: String = "herdx")
        -> EndpointInfo
    {
        let entries = agents.enumerated().map { index, agent in
            """
            {"pane_id":"w1:p\(index + 1)","workspace_id":"w1","tab_id":"w1:t1",
             "agent":"\(agent.0)","agent_status":"\(agent.1)",
             "state_change_seq":\(index + 1),"focused":false}
            """
        }
        let snapshot = try! JSONDecoder().decode(
            Snapshot.self,
            from: Data(
                """
                {"boot_id":"boot","revision":1,
                 "workspaces":[{"workspace_id":"w1","number":1,"label":"\(label)",
                                "focused":true,"agent_status":"idle"}],
                 "tabs":[],"panes":[],
                 "agents":[\(entries.joined(separator: ","))]}
                """.utf8))
        return EndpointInfo(
            index: 0, id: "local", label: "Local", status: .online, isRemote: false,
            error: nil, needsInstall: false, snapshot: snapshot)
    }

    func testNeverHoldsNothingHoweverBusyThingsAre() {
        let busy = StayAwake.waitingOn([endpoint([("claude", "working")])])
        XCTAssertNil(StayAwake.reason(for: .never, waitingOn: busy))
    }

    func testAlwaysHoldsEvenWithNothingRunning() {
        XCTAssertNotNil(StayAwake.reason(for: .always, waitingOn: nil))
    }

    func testWhileWorkingHoldsOnlyWhenSomethingIs() {
        XCTAssertNil(
            StayAwake.reason(
                for: .whileWorking, waitingOn: StayAwake.waitingOn([endpoint([("claude", "idle")])])
            ))
        XCTAssertNotNil(
            StayAwake.reason(
                for: .whileWorking,
                waitingOn: StayAwake.waitingOn([endpoint([("claude", "working")])])))
    }

    /// Blocked counts. It means the agent is waiting on you, and a dark screen
    /// locks — which is also what silences the sound that would have told you.
    func testAnAgentWaitingOnYouIsWorthStayingAwakeFor() {
        XCTAssertNotNil(
            StayAwake.waitingOn([endpoint([("claude", "blocked")])]),
            "the screen would have gone dark on an agent asking a question")
    }

    /// `done` is finished-and-unseen. Finished is finished — the display can
    /// sleep, and the sound and the notification are what tell you.
    func testAFinishedAgentIsNotWorthStayingAwakeFor() {
        XCTAssertNil(StayAwake.waitingOn([endpoint([("claude", "done")])]))
        XCTAssertNil(StayAwake.waitingOn([endpoint([("claude", "idle")])]))
    }

    /// Any machine, not just the one on screen. Watching a remote agent work
    /// is the case this exists for.
    func testAnAgentOnAnotherMachineCounts() {
        var remote = endpoint([("claude", "working")], label: "augur")
        remote = EndpointInfo(
            index: 3, id: "vsdev", label: "vsdev", status: .online, isRemote: true,
            error: nil, needsInstall: false, snapshot: remote.snapshot)
        let reason = StayAwake.waitingOn([endpoint([("claude", "idle")]), remote])
        XCTAssertNotNil(reason)
        XCTAssertEqual(reason?.contains("augur"), true, "the reason should say where: \(reason!)")
    }

    /// The reason is what `pmset -g assertions` shows beside the assertion, so
    /// it has to say who asked and why rather than just that somebody did.
    func testTheReasonNamesTheAgentAndTheRepo() {
        let reason = StayAwake.reason(
            for: .whileWorking,
            waitingOn: StayAwake.waitingOn([endpoint([("claude", "working")])]))
        XCTAssertEqual(reason, "HerdX: claude is working in herdx")
    }

    func testNoEndpointsIsNothingToStayAwakeFor() {
        XCTAssertNil(StayAwake.waitingOn([]))
    }

    /// Taking and dropping it is driven off the reason changing, so an
    /// unchanged reason must not churn the assertion every tick.
    func testTheAssertionIsHeldAndReleasedWithTheReason() {
        let awake = StayAwake()
        awake.mode = .whileWorking
        XCTAssertNil(awake.held)

        awake.update(endpoints: [endpoint([("claude", "working")])])
        let first = awake.held
        XCTAssertNotNil(first)

        awake.update(endpoints: [endpoint([("claude", "working")])])
        XCTAssertEqual(awake.held, first, "the same reason retook the assertion")

        awake.update(endpoints: [endpoint([("claude", "idle")])])
        XCTAssertNil(awake.held, "the display was held awake with nothing running")
    }

    /// Turning the setting off lets go of one already held, rather than
    /// waiting for the agents to finish.
    func testTurningItOffReleasesWhatIsHeld() {
        let awake = StayAwake()
        awake.mode = .always
        awake.update(endpoints: [])
        XCTAssertNotNil(awake.held)

        awake.mode = .never
        awake.update(endpoints: [])
        XCTAssertNil(awake.held)
    }

    /// Off unless it is turned on: holding a Mac's display awake is not
    /// something to inherit by upgrading.
    func testTheDefaultIsNever() {
        let defaults = UserDefaults(suiteName: "dev.herdr.herdx.tests.\(UUID().uuidString)")!
        XCTAssertEqual(Preferences.load(from: defaults).stayAwake, .never)
    }

    /// The stored form is the raw value, so a setting survives a relaunch.
    func testTheChoiceSurvivesBeingSaved() {
        let suite = "dev.herdr.herdx.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var preferences = Preferences.load(from: defaults)
        preferences.stayAwake = .whileWorking
        preferences.save(to: defaults)
        XCTAssertEqual(Preferences.load(from: defaults).stayAwake, .whileWorking)
    }
}
