import XCTest

@testable import HerdX

/// The agents list bands rows by how recently each agent did anything, which is
/// a clock this client keeps itself — herdr's snapshot carries none, and
/// `state_change_seq` is a counter that stands still all night.
final class AgentBandingTests: XCTestCase {
    private struct Row {
        var paneID: String
        var tabID: String = "w1:t1"
        var status: String
        var seq: UInt64 = 1
    }

    private func snapshot(_ rows: [Row], focusedTab: String = "w1:t1") -> Snapshot {
        let agents = rows.map { row in
            """
            {
              "pane_id": "\(row.paneID)",
              "workspace_id": "w1",
              "tab_id": "\(row.tabID)",
              "agent_status": "\(row.status)",
              "state_change_seq": \(row.seq),
              "focused": false
            }
            """
        }.joined(separator: ",")
        let json = """
            {
              "boot_id": "boot",
              "revision": 1,
              "focused_tab_id": "\(focusedTab)",
              "workspaces": [],
              "tabs": [],
              "panes": [],
              "agents": [\(agents)]
            }
            """
        return try! JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    private func agent(_ snapshot: Snapshot, _ paneID: String) -> Snapshot.Agent {
        snapshot.agents.first { $0.paneID == paneID }!
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func later(_ hours: Double) -> Date { start.addingTimeInterval(hours * 3600) }

    // MARK: - The clock only ever sorts agents that are already idle

    func testAnAgentStillWorkingIsActiveHoweverLongItHasBeenRunning() {
        var priority = AgentPriority()
        let running = snapshot([Row(paneID: "w1:p1", status: "working")])
        priority.observe(snapshot: running, endpoint: 0, watching: false, now: start)
        priority.observe(snapshot: running, endpoint: 0, watching: false, now: later(9))

        XCTAssertEqual(
            priority.tier(agent(running, "w1:p1"), on: 0, now: later(9)), .active,
            "a long-running agent is the opposite of idle; the counter does not move while it works")
    }

    func testAnAgentBlockedSinceYesterdayIsStillActive() {
        var priority = AgentPriority()
        let blocked = snapshot([Row(paneID: "w1:p1", status: "blocked")])
        priority.observe(snapshot: blocked, endpoint: 0, watching: false, now: start)

        XCTAssertEqual(
            priority.tier(agent(blocked, "w1:p1"), on: 0, now: later(30)), .active,
            "it is still asking for you; ageing it down hides the one row that matters")
    }

    func testAFinishNobodyHasLookedAtIsActive() {
        var priority = AgentPriority()
        priority.observe(
            snapshot: snapshot([Row(paneID: "w1:p1", status: "working")]),
            endpoint: 0, watching: false, now: start)
        let done = snapshot([Row(paneID: "w1:p1", status: "idle", seq: 2)])
        priority.observe(snapshot: done, endpoint: 0, watching: false, now: later(8))

        XCTAssertEqual(
            priority.tier(agent(done, "w1:p1"), on: 0, now: later(20)), .active,
            "unseen means it is waiting for you, which is not the same as abandoned")
    }

    // MARK: - The rank and the row agree with the dot

    func testAnAgentThisClientHasNeverLookedAtDoesNotOutrankOneThatIsWorking() {
        var priority = AgentPriority()
        // Both were already in this state when the app attached, so nothing was
        // witnessed and the server has not called either finish unseen.
        let both = snapshot([
            Row(paneID: "w1:p1", status: "idle", seq: 1),
            Row(paneID: "w1:p2", status: "working", seq: 2),
        ])
        priority.observe(snapshot: both, endpoint: 0, watching: false, now: start)

        let ordered = priority.ordered(
            both.agents.map { (0, $0) }, agent: { $0.1 }, endpoint: { $0.0 }, now: start)

        XCTAssertEqual(
            ordered.map { $0.1.paneID }, ["w1:p2", "w1:p1"],
            "ranking off the wire put every agent this client had never focused into the "
                + "finished-unseen rank, above the one actually running")
    }

    func testARowSaysWhatItsDotSays() {
        var priority = AgentPriority()
        let quiet = snapshot([Row(paneID: "w1:p1", status: "idle")])
        priority.observe(snapshot: quiet, endpoint: 0, watching: false, now: start)
        let row = agent(quiet, "w1:p1")

        XCTAssertEqual(priority.displayStatus(row, on: 0), .idle)
        XCTAssertEqual(
            priority.reason(row, on: 0), "idle",
            "\"waiting\" beside a plain idle dot is the disagreement displayStatus settles")
    }

    func testAFinishWatchedWhileYouWereAwayStillSaysSo() {
        var priority = AgentPriority()
        priority.observe(
            snapshot: snapshot([Row(paneID: "w1:p1", status: "working")]),
            endpoint: 0, watching: false, now: start)
        let done = snapshot([Row(paneID: "w1:p1", status: "idle", seq: 2)])
        priority.observe(snapshot: done, endpoint: 0, watching: false, now: later(1))

        XCTAssertEqual(priority.reason(agent(done, "w1:p1"), on: 0), "finished")
    }

    // MARK: - Ageing down

    func testAnAgentJustLookedAtIsIdleAndOnlyLaterLongIdle() {
        var priority = AgentPriority()
        let quiet = snapshot([Row(paneID: "w1:p1", status: "idle")])
        // Watched with its tab in front, so it counts as seen and the row drops
        // to the plain idle rank the clock is allowed to sort.
        priority.observe(snapshot: quiet, endpoint: 0, watching: true, now: start)
        let row = agent(quiet, "w1:p1")

        XCTAssertEqual(priority.tier(row, on: 0, now: later(1)), .idle)
        XCTAssertEqual(
            priority.tier(row, on: 0, now: later(3.9)), .idle,
            "still this morning's work")
        XCTAssertEqual(
            priority.tier(row, on: 0, now: later(4.1)), .longIdle,
            "past the threshold it is background, not work in hand")
    }

    func testLookingAtAnAgentMakesItRecentAgain() {
        var priority = AgentPriority()
        let quiet = snapshot([Row(paneID: "w1:p1", status: "idle")])
        priority.observe(snapshot: quiet, endpoint: 0, watching: true, now: start)
        XCTAssertEqual(priority.tier(agent(quiet, "w1:p1"), on: 0, now: later(6)), .longIdle)

        priority.observe(snapshot: quiet, endpoint: 0, watching: true, now: later(6))

        XCTAssertEqual(
            priority.tier(agent(quiet, "w1:p1"), on: 0, now: later(6)), .active,
            "a pane you have open is one you are working in, running or not")
        XCTAssertEqual(
            priority.tier(agent(quiet, "w1:p1"), on: 0, now: later(7)), .idle,
            "and half an hour after you left it, it is not any more")
    }

    func testAnAgentAlreadyIdleAtLaunchIsNotClaimedToBeEitherFreshOrStale() {
        var priority = AgentPriority()
        let quiet = snapshot([Row(paneID: "w1:p1", status: "idle")])
        // Never watched, so nothing was witnessed: all that is known is when we
        // started looking.
        priority.observe(snapshot: quiet, endpoint: 0, watching: false, now: start)
        let row = agent(quiet, "w1:p1")

        XCTAssertEqual(
            priority.tier(row, on: 0, now: start), .idle,
            "it may have been idle for a week, but nothing on the wire says so")
        XCTAssertNil(
            priority.quietFor(row, on: 0, now: later(9)),
            "a guessed age must not be shown as a fact")
    }

    func testClickingAFinishedAgentDoesNotTakeItOutOfTheWorkArea() {
        var priority = AgentPriority()
        let running = snapshot([Row(paneID: "w1:p1", status: "working")])
        priority.observe(snapshot: running, endpoint: 0, watching: true, now: start)
        // It finishes while you are elsewhere, so it is asking for you.
        let finished = snapshot([Row(paneID: "w1:p1", status: "idle", seq: 2)])
        priority.observe(snapshot: finished, endpoint: 0, watching: false, now: later(1))
        let row = agent(finished, "w1:p1")
        XCTAssertEqual(priority.tier(row, on: 0, now: later(1)), .active)

        // You click it: its tab comes to the front with the app active, which
        // is what counts as having seen it.
        priority.observe(snapshot: finished, endpoint: 0, watching: true, now: later(1))

        XCTAssertEqual(
            priority.tier(row, on: 0, now: later(1)), .active,
            "reading the band off attention state moved a finished agent out of the work "
                + "area at the moment you started working on it")
        XCTAssertEqual(
            priority.reason(row, on: 0), "idle",
            "it is no longer asking for anything, which is a different question from where "
                + "it belongs")
        XCTAssertEqual(
            priority.tier(row, on: 0, now: later(2)), .idle,
            "it leaves the work area on the clock, once you have moved on")
    }

    // MARK: - What the row says

    func testAgeIsCoarseBecauseTheListRebuildsWhenTheTextChanges() {
        var priority = AgentPriority()
        priority.observe(
            snapshot: snapshot([Row(paneID: "w1:p1", status: "working")]),
            endpoint: 0, watching: true, now: start)
        let quiet = snapshot([Row(paneID: "w1:p1", status: "idle", seq: 2)])
        priority.observe(snapshot: quiet, endpoint: 0, watching: true, now: start)
        let row = agent(quiet, "w1:p1")

        XCTAssertNil(
            priority.quietFor(row, on: 0, now: later(0.75)),
            "a caption counting minutes rebuilds the list every minute")
        XCTAssertEqual(priority.quietFor(row, on: 0, now: later(3)), "3h")
        XCTAssertEqual(priority.quietFor(row, on: 0, now: later(50)), "2d")
    }

    func testAnActiveAgentIsNotGivenAnAge() {
        var priority = AgentPriority()
        let running = snapshot([Row(paneID: "w1:p1", status: "working")])
        priority.observe(snapshot: running, endpoint: 0, watching: true, now: start)

        XCTAssertNil(
            priority.quietFor(agent(running, "w1:p1"), on: 0, now: later(5)),
            "\"working 5h\" reads as a complaint about an agent that is fine")
    }

    // MARK: - Order

    func testTheListIsBandedAndThenOrderedByTheClock() {
        var priority = AgentPriority()
        let rows = [
            Row(paneID: "w1:p1", status: "idle", seq: 1),
            Row(paneID: "w1:p2", status: "idle", seq: 2),
            Row(paneID: "w1:p3", status: "working", seq: 3),
        ]
        let first = snapshot(rows)
        priority.observe(snapshot: first, endpoint: 0, watching: true, now: start)
        // p2 is touched again four hours on; p1 is left alone and ages out.
        priority.observe(
            snapshot: snapshot([rows[1]], focusedTab: "w1:t1"), endpoint: 1,
            watching: true, now: later(5))
        let now = later(5.5)

        let all = first.agents.map { (0, $0) }
            + [(1, agent(snapshot([rows[1]]), "w1:p2"))]
        let ordered = priority.ordered(all, agent: { $0.1 }, endpoint: { $0.0 }, now: now)

        XCTAssertEqual(
            ordered.map { "\($0.0):\($0.1.paneID)" },
            ["0:w1:p3", "1:w1:p2", "0:w1:p2", "0:w1:p1"],
            "working first, then the one touched recently, then the two left behind — which "
                + "went quiet at the same moment, so the counter breaks the tie")
    }

    func testRecencyBeatsACounterFromAnotherMachine() {
        var priority = AgentPriority()
        let old = snapshot([Row(paneID: "w1:p1", status: "idle", seq: 900)])
        let fresh = snapshot([Row(paneID: "w1:p1", status: "idle", seq: 3)])
        priority.observe(snapshot: old, endpoint: 0, watching: true, now: start)
        priority.observe(snapshot: fresh, endpoint: 1, watching: true, now: later(1))

        let ordered = priority.ordered(
            [(0, agent(old, "w1:p1")), (1, agent(fresh, "w1:p1"))],
            agent: { $0.1 }, endpoint: { $0.0 }, now: later(1))

        XCTAssertEqual(
            ordered.map(\.0), [1, 0],
            "one server's counter says nothing about another's; ordering by it sorted by "
                + "which machine had been busier")
    }

    // MARK: - Two clocks, because one answered the wrong question

    /// Ticks the endpoints the way `main.swift` does: in a loop, each taking
    /// its own reading of the clock a moment after the last.
    private func tick(
        _ priority: inout AgentPriority, _ snapshots: [Snapshot], at moment: Date
    ) {
        for (index, snapshot) in snapshots.enumerated() {
            priority.observe(
                snapshot: snapshot, endpoint: index, watching: false,
                now: moment.addingTimeInterval(Double(index) / 1000))
        }
    }

    func testTheAgentThatJustBlockedIsAboveTheOneBlockedSinceYesterday() {
        var priority = AgentPriority()
        let working = snapshot([Row(paneID: "w1:p1", status: "working", seq: 1)])
        let justBlocked = snapshot([Row(paneID: "w1:p1", status: "blocked", seq: 2)])
        // A high counter, so the machine that has been quiet is also the one
        // whose counter would win if the counter were doing the deciding.
        let blockedYesterday = snapshot([Row(paneID: "w1:p1", status: "blocked", seq: 900)])

        var moment = start
        while moment < later(24) {
            tick(&priority, [working, blockedYesterday], at: moment)
            moment = moment.addingTimeInterval(3600)
        }
        let now = later(24)
        tick(&priority, [justBlocked, blockedYesterday], at: now)

        let ordered = priority.ordered(
            [(0, agent(justBlocked, "w1:p1")), (1, agent(blockedYesterday, "w1:p1"))],
            agent: { $0.1 }, endpoint: { $0.0 }, now: now)

        XCTAssertEqual(
            ordered.map(\.0), [0, 1],
            "ordering these on the liveness clock sorted them by which machine was polled "
                + "last, because it is restamped every tick an agent spends blocked")
    }

    func testAnAgentThatKeepsRunningDoesNotClimbOverOneThatStartedLater() {
        var priority = AgentPriority()
        let idle = snapshot([Row(paneID: "w1:p1", status: "idle", seq: 1)])
        let running = snapshot([Row(paneID: "w1:p1", status: "working", seq: 2)])

        // Endpoint 0 starts working first and keeps at it; endpoint 1 starts an
        // hour later. Endpoint 1 is the fresher of the two from then on.
        tick(&priority, [idle, idle], at: start)
        tick(&priority, [running, idle], at: later(1))
        tick(&priority, [running, running], at: later(2))
        let now = later(5)
        tick(&priority, [running, running], at: now)

        let ordered = priority.ordered(
            [(0, agent(running, "w1:p1")), (1, agent(running, "w1:p1"))],
            agent: { $0.1 }, endpoint: { $0.0 }, now: now)

        XCTAssertEqual(
            ordered.map(\.0), [1, 0],
            "the one that started most recently is the news, and its liveness clock reads "
                + "\"now\" just like the other's")
    }

    func testAnAgentThatLaunchesStraightIntoBlockedCountsAsHavingJustChanged() {
        var priority = AgentPriority()
        let empty = snapshot([])
        let early = snapshot([Row(paneID: "w1:p1", status: "blocked", seq: 900)])
        // Endpoint 1 has been blocked since before anything else existed.
        tick(&priority, [empty, early], at: start)

        // A pane appears on endpoint 0 already blocked — an agent started and
        // stopped for input before a single tick saw it running, so there is no
        // transition to watch, only an arrival.
        let born = snapshot([Row(paneID: "w1:p9", status: "blocked", seq: 2)])
        let now = later(3)
        tick(&priority, [born, early], at: now)

        let ordered = priority.ordered(
            [(0, agent(born, "w1:p9")), (1, agent(early, "w1:p1"))],
            agent: { $0.1 }, endpoint: { $0.0 }, now: now)

        XCTAssertEqual(
            ordered.map(\.0), [0, 1],
            "it never transitioned, but it plainly just started; treating arrival as a "
                + "non-event buried every agent that blocks on its first prompt")
    }

    func testTwoAgentsAlreadyBlockedAtLaunchFallBackToTheCounter() {
        var priority = AgentPriority()
        let low = snapshot([Row(paneID: "w1:p1", status: "blocked", seq: 4)])
        let high = snapshot([Row(paneID: "w1:p1", status: "blocked", seq: 9)])
        // Neither transition was watched, so there is no honest clock reading
        // for either — and first sight is just polling order wearing a clock.
        tick(&priority, [low, high], at: start)
        let now = later(2)
        tick(&priority, [low, high], at: now)

        let ordered = priority.ordered(
            [(0, agent(low, "w1:p1")), (1, agent(high, "w1:p1"))],
            agent: { $0.1 }, endpoint: { $0.0 }, now: now)

        XCTAssertEqual(
            ordered.map(\.0), [1, 0],
            "the counter is arbitrary across servers, but it is not a time we invented")
    }

    // MARK: - Walking the list from a key

    func testTheJumpAlwaysLandsOnWhateverMostNeedsYou() {
        XCTAssertEqual(AgentPriority.step(from: 4, by: 0, count: 6), 0)
        XCTAssertEqual(
            AgentPriority.step(from: 0, by: 0, count: 6), 0,
            "pressing it again where you already are is a no-op, not a cycle")
        XCTAssertEqual(
            AgentPriority.step(from: nil, by: 0, count: 6), 0,
            "it does not need to know where you were")
    }

    func testCyclingWrapsBothWays() {
        XCTAssertEqual(AgentPriority.step(from: 1, by: 1, count: 3), 2)
        XCTAssertEqual(AgentPriority.step(from: 2, by: 1, count: 3), 0)
        XCTAssertEqual(AgentPriority.step(from: 1, by: -1, count: 3), 0)
        XCTAssertEqual(
            AgentPriority.step(from: 0, by: -1, count: 3), 2,
            "Swift's modulo of a negative is negative, so this is where it wraps wrong")
    }

    func testCyclingFromSomewhereThatIsNotAnAgentStartsAtTheEnd() {
        XCTAssertEqual(
            AgentPriority.step(from: nil, by: 1, count: 3), 0,
            "forwards from nowhere is the first, as herdr does it")
        XCTAssertEqual(
            AgentPriority.step(from: nil, by: -1, count: 3), 2,
            "and backwards from nowhere is the last")
    }

    func testAnEmptyListGoesNowhere() {
        XCTAssertNil(AgentPriority.step(from: nil, by: 0, count: 0))
        XCTAssertNil(AgentPriority.step(from: nil, by: 1, count: 0))
        XCTAssertNil(
            AgentPriority.step(from: 0, by: -1, count: 0),
            "a modulo by zero here would trap rather than do nothing")
    }

    func testTheJumpLandsOnTheAgentThatIsAskingOverTheOneYouAreIn() {
        var priority = AgentPriority()
        let rows = [
            Row(paneID: "w1:p1", status: "idle", seq: 1),
            Row(paneID: "w1:p2", status: "blocked", seq: 2),
            Row(paneID: "w1:p3", status: "working", seq: 3),
        ]
        let live = snapshot(rows)
        priority.observe(snapshot: live, endpoint: 0, watching: true, now: start)

        let ordered = priority.ordered(
            live.agents.map { (0, $0) }, agent: { $0.1 }, endpoint: { $0.0 }, now: start)
        // Standing in the idle one, which is where the complaint started.
        let current = ordered.firstIndex { $0.1.paneID == "w1:p1" }
        let landing = AgentPriority.step(from: current, by: 0, count: ordered.count)!

        XCTAssertEqual(
            ordered[landing].1.paneID, "w1:p2",
            "blocked outranks working, and both outrank the idle pane you are sitting in")
    }

    // MARK: - Forgetting

    func testAPaneThatGoesAwayTakesItsAgeWithIt() {
        var priority = AgentPriority()
        priority.observe(
            snapshot: snapshot([Row(paneID: "w1:p1", status: "idle")]),
            endpoint: 0, watching: true, now: start)
        priority.observe(snapshot: snapshot([]), endpoint: 0, watching: true, now: later(1))

        let reused = snapshot([Row(paneID: "w1:p1", status: "idle", seq: 1)])
        priority.observe(snapshot: reused, endpoint: 0, watching: true, now: later(6))

        XCTAssertEqual(
            priority.tier(agent(reused, "w1:p1"), on: 0, now: later(6)), .active,
            "a new pane handed the same id would otherwise be born hours old, and land "
                + "straight in the bottom band")
    }
}
