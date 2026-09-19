import XCTest

@testable import HerdX

/// What the agents list makes of a snapshot, which is not always what the wire
/// said: this client and the server disagree about who has looked at what.
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

    // MARK: - The rank and the row agree with the dot

    func testAnAgentThisClientHasNeverLookedAtDoesNotOutrankOneThatIsWorking() {
        var priority = AgentPriority()
        // Both were already in this state when the app attached, so nothing was
        // witnessed and the server has not called either finish unseen.
        let both = snapshot([
            Row(paneID: "w1:p1", status: "idle", seq: 1),
            Row(paneID: "w1:p2", status: "working", seq: 2),
        ])
        priority.observe(snapshot: both, endpoint: 0, watching: false)

        let ordered = priority.ordered(
            both.agents.map { (0, $0) }, agent: { $0.1 }, endpoint: { $0.0 })

        XCTAssertEqual(
            ordered.map { $0.1.paneID }, ["w1:p2", "w1:p1"],
            "ranking off the wire put every agent this client had never focused into the "
                + "finished-unseen rank, above the one actually running")
    }

    func testARowSaysWhatItsDotSays() {
        var priority = AgentPriority()
        let quiet = snapshot([Row(paneID: "w1:p1", status: "idle")])
        priority.observe(snapshot: quiet, endpoint: 0, watching: false)
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
            endpoint: 0, watching: false)
        let done = snapshot([Row(paneID: "w1:p1", status: "idle", seq: 2)])
        priority.observe(snapshot: done, endpoint: 0, watching: false)

        XCTAssertEqual(priority.reason(agent(done, "w1:p1"), on: 0), "finished")
    }
}
