import AppKit
import XCTest

@testable import HerdX

/// Two agents in one repo — a coder and a reviewer — are one thing to keep
/// track of, and the priority list used to scatter them.
///
/// Rows were titled by agent, so running one kind per repo gave a column of
/// rows all called "claude"; and because the bands are by tier, a pair split
/// the moment one of them went quiet. The pair is now drawn together without
/// moving where the urgent one sits, which is the part the alerting relies on.
@MainActor
final class SidebarAgentGroupTests: XCTestCase {
    private func sidebar() -> SidebarView {
        let view = SidebarView(frame: .zero)
        view.arrangement = .priority
        return view
    }

    /// One workspace per entry, each with its agents as `(kind, status)`.
    private func snapshot(_ workspaces: [(id: String, label: String, agents: [(String, String)])])
        -> Snapshot
    {
        var spaces: [String] = []
        var panes: [String] = []
        var agents: [String] = []
        var number = 1
        for workspace in workspaces {
            spaces.append(
                """
                {"workspace_id":"\(workspace.id)","number":\(number),
                 "label":"\(workspace.label)","focused":false,"agent_status":"idle",
                 "active_tab_id":"\(workspace.id):t1"}
                """)
            for (index, agent) in workspace.agents.enumerated() {
                let pane = "\(workspace.id):p\(index + 1)"
                panes.append(
                    """
                    {"pane_id":"\(pane)","workspace_id":"\(workspace.id)",
                     "tab_id":"\(workspace.id):t1","focused":false,
                     "agent_status":"\(agent.1)"}
                    """)
                agents.append(
                    """
                    {"pane_id":"\(pane)","workspace_id":"\(workspace.id)",
                     "tab_id":"\(workspace.id):t1","agent":"\(agent.0)",
                     "agent_status":"\(agent.1)","state_change_seq":\(index + 1),
                     "focused":false}
                    """)
            }
            number += 1
        }
        let json = """
            {"boot_id":"boot","revision":1,
             "workspaces":[\(spaces.joined(separator: ","))],
             "tabs":[],
             "panes":[\(panes.joined(separator: ","))],
             "agents":[\(agents.joined(separator: ","))]}
            """
        return try! JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    private func endpoint(
        _ snapshot: Snapshot, index: Int = 0, id: String = "local", label: String = "Local"
    ) -> EndpointInfo {
        EndpointInfo(
            index: index, id: id, label: label, status: .online, isRemote: false,
            error: nil, needsInstall: false, snapshot: snapshot)
    }

    private func rows(_ view: SidebarView) -> [SidebarRow] {
        view.builtRows.compactMap { $0 as? SidebarRow }
    }

    private func headings(_ view: SidebarView) -> [String] {
        view.builtRows.compactMap { $0 as? SidebarSection }.map(\.title)
    }

    /// The lead row says which repo; the sibling under it says which agent.
    func testTheLeadNamesTheRepoAndTheSiblingNamesItself() {
        let view = sidebar()
        let snapshot = self.snapshot([
            (id: "w1", label: "herdx", agents: [("claude", "working"), ("omp", "done")])
        ])
        view.priority.observe(snapshot: snapshot, endpoint: 0, watching: false)
        view.update(endpoints: [endpoint(snapshot)], active: 0, hibernated: [])

        let drawn = rows(view)
        XCTAssertEqual(drawn.count, 2)
        XCTAssertEqual(
            drawn[0].title, "herdx",
            "the lead row must say which repo; a column of rows called claude says nothing")
        XCTAssertTrue(
            drawn[0].subtitle.contains("omp") || drawn[0].subtitle.contains("claude"),
            "the lead row must still say which agent it is: \(drawn[0].subtitle)")
        XCTAssertFalse(
            drawn[1].title.contains("herdx"), "the sibling repeats the repo it is drawn under")
    }

    /// The sibling is drawn a step in, which is what shows the two belong
    /// together without spending a line on a heading.
    func testASiblingIsIndentedAndItsLeadIsNot() {
        let view = sidebar()
        let snapshot = self.snapshot([
            (id: "w1", label: "herdx", agents: [("claude", "working"), ("omp", "done")])
        ])
        view.priority.observe(snapshot: snapshot, endpoint: 0, watching: false)
        view.update(endpoints: [endpoint(snapshot)], active: 0, hibernated: [])

        let drawn = rows(view)
        XCTAssertFalse(drawn[0].isUnderLead, "the lead was indented")
        XCTAssertTrue(drawn[1].isUnderLead, "the sibling was not indented, so the pair reads flat")
    }

    /// The whole point: a quiet partner is drawn beside its urgent one rather
    /// than banished to its own band, and the urgent one does not move.
    func testAQuietPartnerIsDrawnWithItsUrgentOneRatherThanInItsOwnBand() {
        let view = sidebar()
        let snapshot = self.snapshot([
            (id: "w1", label: "herdx", agents: [("claude", "blocked"), ("omp", "idle")]),
            (id: "w2", label: "cairn", agents: [("claude", "working")]),
        ])
        view.priority.observe(snapshot: snapshot, endpoint: 0, watching: false)
        view.update(endpoints: [endpoint(snapshot)], active: 0, hibernated: [])

        let drawn = rows(view)
        // herdx leads because its blocked agent is the most urgent thing here,
        // and its partner follows it directly rather than after cairn.
        XCTAssertEqual(drawn.map(\.title).prefix(2), ["herdx", "omp"])
        XCTAssertTrue(drawn[1].isUnderLead)
        XCTAssertEqual(drawn[2].title, "cairn", "the pair was broken up by another repo")
    }

    /// A band heading describes where a group sits, and a group sits where its
    /// most urgent member put it — so a quieter sibling must not open a band.
    func testASiblingDoesNotOpenABandOfItsOwn() {
        let view = sidebar()
        let snapshot = self.snapshot([
            (id: "w1", label: "herdx", agents: [("claude", "blocked"), ("omp", "idle")])
        ])
        view.priority.observe(snapshot: snapshot, endpoint: 0, watching: false)
        view.update(endpoints: [endpoint(snapshot)], active: 0, hibernated: [])

        XCTAssertTrue(
            headings(view).isEmpty,
            "one group is one band, so there is nothing to tell apart: \(headings(view))")
    }

    /// Two machines really do both have a `w1`, so grouping on the workspace
    /// alone would file one machine's agents under another's.
    func testTheSameWorkspaceIdOnTwoMachinesIsTwoGroups() {
        let view = sidebar()
        let first = snapshot([(id: "w1", label: "herdx", agents: [("claude", "working")])])
        let second = snapshot([(id: "w1", label: "augur", agents: [("claude", "working")])])
        view.priority.observe(snapshot: first, endpoint: 0, watching: false)
        view.priority.observe(snapshot: second, endpoint: 1, watching: false)
        view.update(
            endpoints: [
                endpoint(first), endpoint(second, index: 1, id: "vsdev", label: "vsdev"),
            ], active: 0, hibernated: [])

        let drawn = rows(view)
        XCTAssertEqual(drawn.count, 2)
        XCTAssertFalse(
            drawn[1].isUnderLead,
            "an agent on another machine was gathered under this one's workspace")
        XCTAssertEqual(Set(drawn.map(\.title)), ["herdx", "augur"])
    }

    /// "Local" after every row is a column of noise in a sidebar this narrow,
    /// and it only tells you anything when there is more than one machine.
    func testTheMachineIsNamedOnlyWhenThereIsMoreThanOne() {
        let view = sidebar()
        let only = snapshot([(id: "w1", label: "herdx", agents: [("claude", "working")])])
        view.priority.observe(snapshot: only, endpoint: 0, watching: false)
        view.update(endpoints: [endpoint(only)], active: 0, hibernated: [])
        XCTAssertFalse(
            rows(view)[0].subtitle.contains("Local"),
            "the only machine there is was named anyway")

        let second = snapshot([(id: "w2", label: "augur", agents: [("claude", "working")])])
        view.priority.observe(snapshot: second, endpoint: 1, watching: false)
        view.update(
            endpoints: [
                endpoint(only), endpoint(second, index: 1, id: "vsdev", label: "vsdev"),
            ], active: 0, hibernated: [])
        XCTAssertTrue(
            rows(view).contains { $0.subtitle.contains("vsdev") },
            "with two machines attached, which one matters")
    }

    /// Two agents of the same kind in one repo is the case this list exists
    /// to untangle, and two rows both saying "claude" untangle nothing.
    ///
    /// The pane's own label is what tells them apart — usually the one thing
    /// the person named themselves.
    func testTwoAgentsOfOneKindAreToldApartByTheirPaneLabels() {
        let view = sidebar()
        let json = """
            {"boot_id":"boot","revision":1,
             "workspaces":[{"workspace_id":"w1","number":1,"label":"root","focused":false,
                            "agent_status":"idle","active_tab_id":"w1:t1"}],
             "tabs":[],
             "panes":[
               {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":false,
                "label":"Overall","agent_status":"working"},
               {"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t2","focused":false,
                "label":"vs-bestpack","agent_status":"idle"}],
             "agents":[
               {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"claude",
                "agent_status":"working","state_change_seq":1,"focused":false},
               {"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t2","agent":"claude",
                "agent_status":"idle","state_change_seq":2,"focused":false}]}
            """
        let snapshot = try! JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        view.priority.observe(snapshot: snapshot, endpoint: 0, watching: false)
        view.update(endpoints: [endpoint(snapshot)], active: 0, hibernated: [])

        let drawn = rows(view)
        XCTAssertEqual(drawn.count, 2)
        XCTAssertEqual(drawn[0].title, "root")
        XCTAssertTrue(
            drawn[0].subtitle.contains("Overall"),
            "both agents are claude, so the lead must say which one: \(drawn[0].subtitle)")
        XCTAssertEqual(
            drawn[1].title, "vs-bestpack",
            "the sibling said \"claude\" too, which tells it from nothing")
    }

    /// Where the kinds differ they are what you want to read, not pane labels.
    func testDifferentKindsAreNamedByKind() {
        let view = sidebar()
        let snapshot = self.snapshot([
            (id: "w1", label: "herdx", agents: [("claude", "working"), ("omp", "idle")])
        ])
        view.priority.observe(snapshot: snapshot, endpoint: 0, watching: false)
        view.update(endpoints: [endpoint(snapshot)], active: 0, hibernated: [])

        let drawn = rows(view)
        XCTAssertTrue(drawn[0].subtitle.contains("claude"))
        XCTAssertEqual(drawn[1].title, "omp")
    }

    /// A row draws itself selected from the agent's `focused`, so the
    /// signature has to carry it.
    ///
    /// Moving focus between two working agents in one tab changes nothing
    /// else — same workspace, same status, same sequence — so the list was
    /// not rebuilt and the old row stayed highlighted. That is also where
    /// arrow-key navigation starts from.
    func testMovingFocusBetweenTwoAgentsRebuildsTheList() {
        let view = sidebar()
        func snapshot(focused: String) -> Snapshot {
            let agents = ["w1:p1", "w1:p2"].enumerated().map { index, pane in
                """
                {"pane_id":"\(pane)","workspace_id":"w1","tab_id":"w1:t1","agent":"claude",
                 "agent_status":"working","state_change_seq":\(index + 1),
                 "focused":\(pane == focused)}
                """
            }
            return try! JSONDecoder().decode(
                Snapshot.self,
                from: Data(
                    """
                    {"boot_id":"boot","revision":1,
                     "workspaces":[{"workspace_id":"w1","number":1,"label":"herdx",
                                    "focused":true,"agent_status":"working"}],
                     "tabs":[],"panes":[],
                     "agents":[\(agents.joined(separator: ","))]}
                    """.utf8))
        }

        let first = snapshot(focused: "w1:p1")
        view.priority.observe(snapshot: first, endpoint: 0, watching: false)
        view.update(endpoints: [endpoint(first)], active: 0, hibernated: [])
        let rebuilds = view.rebuilds
        XCTAssertEqual(rows(view).filter(\.selected).count, 1)

        let moved = snapshot(focused: "w1:p2")
        view.priority.observe(snapshot: moved, endpoint: 0, watching: false)
        view.update(endpoints: [endpoint(moved)], active: 0, hibernated: [])

        XCTAssertEqual(
            view.rebuilds, rebuilds + 1,
            "focus moved and nothing else did, so the list never noticed")
        let selected = rows(view).first { $0.selected }
        guard case .pane(let paneID, _)? = selected?.target else {
            return XCTFail("no row is selected after the focus moved")
        }
        XCTAssertEqual(paneID, "w1:p2", "the highlight stayed on the pane that lost focus")
    }

    /// Three in one repo is not special, and none of them is left behind.
    func testEveryAgentInARepoIsDrawn() {
        let view = sidebar()
        let snapshot = self.snapshot([
            (
                id: "w1", label: "herdx",
                agents: [("claude", "working"), ("omp", "done"), ("codex", "idle")]
            )
        ])
        view.priority.observe(snapshot: snapshot, endpoint: 0, watching: false)
        view.update(endpoints: [endpoint(snapshot)], active: 0, hibernated: [])

        let drawn = rows(view)
        XCTAssertEqual(drawn.count, 3)
        XCTAssertEqual(drawn.filter(\.isUnderLead).count, 2, "only the lead is unindented")
    }
}
