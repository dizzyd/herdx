import XCTest

@testable import HerdX

/// Every test here is really the same question: can this clock be talked into
/// hibernating something that was in use? The rules are all refusals, so the
/// interesting cases are the ones where it must say no.
final class WorkspaceActivityTests: XCTestCase {
    private struct Agent {
        var pane: String
        var workspace: String
        var status: String
        var seq: Int = 1
    }

    /// Built by decoding, so these exercise the real decoder rather than a
    /// hand-made value that agrees with it.
    private func snapshot(
        workspaces: [(id: String, focused: Bool)],
        agents: [Agent],
        panesPerWorkspace: Int = 1,
        focusedTab: String = "none"
    ) -> Snapshot {
        let workspaceJSON = workspaces.enumerated().map { index, workspace in
            """
            {"workspace_id": "\(workspace.id)", "number": \(index + 1),
             "label": "\(workspace.id)", "focused": \(workspace.focused),
             "agent_status": "idle"}
            """
        }.joined(separator: ",")
        let tabJSON = workspaces.enumerated().map { index, workspace in
            """
            {"tab_id": "\(workspace.id):t1", "workspace_id": "\(workspace.id)",
             "number": \(index + 1), "label": "1", "zoomed": false,
             "focused": false, "agent_status": "idle"}
            """
        }.joined(separator: ",")
        let paneJSON = workspaces.flatMap { workspace in
            (1...panesPerWorkspace).map { pane in
                """
                {"pane_id": "\(workspace.id):p\(pane)", "tab_id": "\(workspace.id):t1",
                 "focused": false}
                """
            }
        }.joined(separator: ",")
        let agentJSON = agents.map { agent in
            """
            {"pane_id": "\(agent.pane)", "workspace_id": "\(agent.workspace)",
             "tab_id": "\(agent.workspace):t1", "agent_status": "\(agent.status)",
             "state_change_seq": \(agent.seq), "focused": false}
            """
        }.joined(separator: ",")

        let json = """
            {"boot_id": "boot", "revision": 1, "focused_tab_id": "\(focusedTab)",
             "workspaces": [\(workspaceJSON)], "tabs": [\(tabJSON)],
             "panes": [\(paneJSON)], "agents": [\(agentJSON)]}
            """
        return try! JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    private let start = Date(timeIntervalSince1970: 1_758_000_000)
    private var later: Date { start.addingTimeInterval(9 * 60 * 60) }

    /// A workspace with one idle agent in it.
    private func quietSnapshot(focused: Bool = false, status: String = "idle") -> Snapshot {
        snapshot(
            workspaces: [(id: "w1", focused: focused)],
            agents: [Agent(pane: "w1:p1", workspace: "w1", status: status)])
    }

    func testSilenceFromBeforeWeAttachedNeverCounts() {
        var clock = WorkspaceActivity()
        clock.observe(snapshot: quietSnapshot(), endpoint: 0, watching: false, now: start)
        clock.observe(snapshot: quietSnapshot(), endpoint: 0, watching: false, now: later)

        XCTAssertEqual(
            clock.candidates(in: quietSnapshot(), on: 0, now: later), [],
            "idle since before we attached is unknown, not old — and the cost of "
                + "guessing wrong here is somebody's process")
        XCTAssertNil(clock.quietFor("w1", on: 0, now: later))
    }

    func testAWitnessedFinishStartsTheClock() {
        var clock = WorkspaceActivity()
        // Working, so the silence that follows has a beginning we saw.
        clock.observe(
            snapshot: quietSnapshot(status: "working"), endpoint: 0, watching: false, now: start)
        clock.observe(snapshot: quietSnapshot(), endpoint: 0, watching: false, now: start)

        XCTAssertEqual(
            clock.candidates(in: quietSnapshot(), on: 0, now: later), ["w1"],
            "a workspace that finished nine hours ago is what this is for")
        XCTAssertEqual(clock.quietFor("w1", on: 0, now: later) ?? 0, 9 * 60 * 60, accuracy: 1)
    }

    func testAWorkingAgentIsNeverACandidate() {
        var clock = WorkspaceActivity()
        clock.observe(
            snapshot: quietSnapshot(status: "working"), endpoint: 0, watching: false, now: start)

        XCTAssertEqual(
            clock.candidates(in: quietSnapshot(status: "working"), on: 0, now: later), [],
            "the clock cannot outvote what the agent is doing")
    }

    func testABlockedAgentIsNeverACandidate() {
        var clock = WorkspaceActivity()
        clock.observe(
            snapshot: quietSnapshot(status: "working"), endpoint: 0, watching: false, now: start)
        clock.observe(
            snapshot: quietSnapshot(status: "blocked"), endpoint: 0, watching: false, now: start)

        XCTAssertEqual(
            clock.candidates(in: quietSnapshot(status: "blocked"), on: 0, now: later), [],
            "blocked is waiting for you, not finished")
    }

    func testTheWorkspaceYouAreLookingAtIsNeverACandidate() {
        var clock = WorkspaceActivity()
        clock.observe(
            snapshot: quietSnapshot(status: "working"), endpoint: 0, watching: false, now: start)
        clock.observe(snapshot: quietSnapshot(), endpoint: 0, watching: false, now: start)

        XCTAssertEqual(
            clock.candidates(in: quietSnapshot(focused: true), on: 0, now: later), [],
            "where you are is not a candidate however long the clock says")
    }

    func testLookingAtAWorkspaceCountsAsUsingIt() {
        var clock = WorkspaceActivity()
        clock.observe(
            snapshot: quietSnapshot(status: "working"), endpoint: 0, watching: false, now: start)
        clock.observe(snapshot: quietSnapshot(), endpoint: 0, watching: false, now: start)
        // Eight hours later you open it and look at it, then move away.
        clock.observe(
            snapshot: quietSnapshot(focused: true), endpoint: 0, watching: true,
            now: start.addingTimeInterval(8 * 60 * 60))

        XCTAssertEqual(
            clock.candidates(in: quietSnapshot(), on: 0, now: later), [],
            "the clock restarts when you look at it, or a workspace you opened an hour "
                + "ago is hibernated out from under you")
    }

    func testAWorkspaceWithNoAgentIsLeftAlone() {
        var clock = WorkspaceActivity()
        let shells = snapshot(workspaces: [(id: "w1", focused: false)], agents: [])
        clock.observe(snapshot: shells, endpoint: 0, watching: true, now: start)
        clock.observe(snapshot: shells, endpoint: 0, watching: false, now: later)

        XCTAssertEqual(
            clock.candidates(in: shells, on: 0, now: later), [],
            "there is no conversation to preserve, so ending it only surprises somebody")
    }

    func testSplittingAPaneCountsAsUse() {
        var clock = WorkspaceActivity()
        clock.observe(
            snapshot: quietSnapshot(status: "working"), endpoint: 0, watching: false, now: start)
        clock.observe(snapshot: quietSnapshot(), endpoint: 0, watching: false, now: start)
        // A second pane appears eight hours in: somebody is working in there.
        let split = snapshot(
            workspaces: [(id: "w1", focused: false)],
            agents: [Agent(pane: "w1:p1", workspace: "w1", status: "idle")],
            panesPerWorkspace: 2)
        clock.observe(
            snapshot: split, endpoint: 0, watching: false,
            now: start.addingTimeInterval(8 * 60 * 60))

        XCTAssertEqual(
            clock.candidates(in: split, on: 0, now: later), [],
            "a pane turning up is the only signal some workspaces ever give")
    }

    func testAClosedWorkspaceLeavesNothingBehind() {
        var clock = WorkspaceActivity()
        clock.observe(
            snapshot: quietSnapshot(status: "working"), endpoint: 0, watching: false, now: start)
        clock.observe(
            snapshot: snapshot(workspaces: [], agents: []), endpoint: 0, watching: false, now: start)

        XCTAssertNil(
            clock.quietFor("w1", on: 0, now: later),
            "a reused workspace id would inherit its predecessor's silence")
    }

    func testCandidatesComeQuietestFirst() {
        var clock = WorkspaceActivity()
        let both = snapshot(
            workspaces: [(id: "w1", focused: false), (id: "w2", focused: false)],
            agents: [
                Agent(pane: "w1:p1", workspace: "w1", status: "working"),
                Agent(pane: "w2:p1", workspace: "w2", status: "working"),
            ])
        clock.observe(snapshot: both, endpoint: 0, watching: false, now: start)

        // w1 goes quiet first, w2 an hour later.
        let w1Quiet = snapshot(
            workspaces: [(id: "w1", focused: false), (id: "w2", focused: false)],
            agents: [
                Agent(pane: "w1:p1", workspace: "w1", status: "idle"),
                Agent(pane: "w2:p1", workspace: "w2", status: "working"),
            ])
        clock.observe(snapshot: w1Quiet, endpoint: 0, watching: false, now: start)

        let bothQuiet = snapshot(
            workspaces: [(id: "w1", focused: false), (id: "w2", focused: false)],
            agents: [
                Agent(pane: "w1:p1", workspace: "w1", status: "idle"),
                Agent(pane: "w2:p1", workspace: "w2", status: "idle"),
            ])
        clock.observe(
            snapshot: bothQuiet, endpoint: 0, watching: false,
            now: start.addingTimeInterval(60 * 60))

        XCTAssertEqual(clock.candidates(in: bothQuiet, on: 0, now: later), ["w1", "w2"])
    }

    func testForgettingLeavesNoHistoryForTheNextSession() {
        var clock = WorkspaceActivity()
        clock.observe(
            snapshot: quietSnapshot(status: "working"), endpoint: 0, watching: false, now: start)
        clock.observe(snapshot: quietSnapshot(), endpoint: 0, watching: false, now: start)
        clock.forget()

        XCTAssertNil(
            clock.quietFor("w1", on: 0, now: later),
            "endpoint 0 is a different machine after a session switch")
    }
}
