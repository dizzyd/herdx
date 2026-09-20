import XCTest

@testable import HerdX

/// This is the code that decides to end somebody's processes, so the tests are
/// mostly about the times it must decline.
final class HibernationPlanTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func workspace(number: Int = 3, label: String = "augur") -> Snapshot.Workspace {
        decode(
            Snapshot.Workspace.self,
            """
            {"workspace_id": "w1", "number": \(number), "label": "\(label)",
             "branch": "main", "focused": false, "agent_status": "idle"}
            """)
    }

    private func tab(_ id: String = "w1:t1", label: String = "1") -> Snapshot.Tab {
        decode(
            Snapshot.Tab.self,
            """
            {"tab_id": "\(id)", "workspace_id": "w1", "number": 1, "label": "\(label)",
             "zoomed": false, "focused": true, "agent_status": "idle"}
            """)
    }

    /// A pane as `pane.list` reports it — the same keys a live server sends.
    private func agentPane(
        pane: String = "w1:p1", status: String = "idle", session: Bool = true,
        agent: String = "claude", tab: String = "w1:t1"
    ) -> Reply.PaneEntry {
        let sessionJSON =
            session
            ? """
            , "agent_session": {"source": "herdr:\(agent)", "agent": "\(agent)",
                                "kind": "id", "value": "conv-abc"}
            """ : ""
        return decode(
            Reply.PaneEntry.self,
            """
            {"pane_id": "\(pane)", "workspace_id": "w1", "tab_id": "\(tab)",
             "agent_status": "\(status)"\(sessionJSON)}
            """)
    }

    /// A pane with nothing herdr recognises in it.
    private func plainPane(_ pane: String = "w1:p2", tab: String = "w1:t1") -> Reply.PaneEntry {
        decode(
            Reply.PaneEntry.self,
            """
            {"pane_id": "\(pane)", "workspace_id": "w1", "tab_id": "\(tab)",
             "agent_status": "unknown"}
            """)
    }

    private func idleShell(_ pane: String) -> Reply.Info {
        decode(
            Reply.Info.self,
            """
            {"pane_id": "\(pane)", "shell_pid": 100, "foreground_process_group_id": 100,
             "foreground_processes": [{"pid": 100, "name": "zsh", "argv": ["-zsh"]}]}
            """)
    }

    private func busyShell(_ pane: String, running: String = "npm") -> Reply.Info {
        decode(
            Reply.Info.self,
            """
            {"pane_id": "\(pane)", "shell_pid": 100, "foreground_process_group_id": 203,
             "foreground_processes": [{"pid": 203, "name": "\(running)", "argv": ["npm", "run", "dev"]}]}
            """)
    }

    /// One agent pane beside one plain shell, split right.
    private func layout(
        tab: String = "w1:t1", zoomed: Bool = false, focused: String = "w1:p1",
        secondCommand: String? = nil
    ) -> Reply.Layout {
        let command = secondCommand.map { ", \"command\": [\"\($0)\"]" } ?? ""
        return decode(
            Reply.Layout.self,
            """
            {"tab_id": "\(tab)", "zoomed": \(zoomed), "focused_pane_id": "\(focused)",
             "root": {"type": "split", "direction": "right", "ratio": 0.4,
               "first":  {"type": "pane", "pane_id": "w1:p1", "cwd": "/src/augur"},
               "second": {"type": "pane", "pane_id": "w1:p2", "cwd": "/src/augur"\(command)}}}
            """)
    }

    private func plan(
        panes: [Reply.PaneEntry]? = nil,
        processes: [String: Reply.Info]? = nil,
        layouts: [String: Reply.Layout]? = nil,
        tabs: [Snapshot.Tab]? = nil
    ) -> Result<Hibernated, HibernationPlan.Refusal> {
        HibernationPlan.plan(
            workspace: workspace(),
            tabs: tabs ?? [tab()],
            endpointID: "local",
            panes: panes ?? [agentPane(), plainPane()],
            processes: processes ?? ["w1:p2": idleShell("w1:p2")],
            layouts: layouts ?? ["w1:t1": layout()],
            at: Date(timeIntervalSince1970: 1_758_000_000))
    }

    private func refusal(_ result: Result<Hibernated, HibernationPlan.Refusal>) -> String? {
        if case .failure(let refusal) = result { return refusal.reason }
        return nil
    }

    func testAQuietWorkspaceIsRecordedWithEnoughToPutItBack() throws {
        let record = try plan().get()

        XCTAssertEqual(record.label, "augur")
        XCTAssertEqual(record.number, 3, "so the row goes back where the workspace was")
        XCTAssertEqual(record.cwd, "/src/augur")
        XCTAssertEqual(record.branch, "main")
        XCTAssertEqual(record.tabs.count, 1)

        let stored = try XCTUnwrap(record.agents.first)
        XCTAssertEqual(stored.value, "conv-abc")
        XCTAssertEqual(stored.path, [false], "the agent is matched to its pane by position")
        XCTAssertEqual(
            record.tabs[0].root.leaf(at: stored.path)?.paneID, "w1:p1",
            "the path has to address the pane the agent came out of")
        XCTAssertEqual(record.tabs[0].focused, [false], "focus is restored after the layout is")
    }

    func testAWorkspaceWithNoAgentIsLeftAlone() {
        XCTAssertEqual(refusal(plan(panes: [plainPane()])), "no agent to bring back")
    }

    func testAnAgentThatStartedWorkingSinceTheSweepIsNotKilled() {
        // The whole point of asking again: several round trips happen between
        // choosing a workspace and closing it.
        XCTAssertEqual(refusal(plan(panes: [agentPane(status: "working"), plainPane()])), "claude is working")
        XCTAssertEqual(refusal(plan(panes: [agentPane(status: "blocked"), plainPane()])), "claude is blocked")
    }

    func testAnAgentWithNoSessionRefuses() throws {
        let reason = try XCTUnwrap(refusal(plan(panes: [agentPane(session: false), plainPane()])))
        XCTAssertTrue(
            reason.contains("no session to resume"),
            "silently downgrading a workspace to bare shells is worse than leaving it")
    }

    func testAPaneWithSomethingRunningInItRefuses() throws {
        let reason = try XCTUnwrap(
            refusal(plan(processes: ["w1:p2": busyShell("w1:p2", running: "cargo")])))
        XCTAssertTrue(reason.contains("cargo"), "say what was running, not just that something was")
        XCTAssertTrue(reason.contains("w1:p2"))
    }

    func testAPaneWeCouldNotAskAboutRefuses() throws {
        let reason = try XCTUnwrap(refusal(plan(processes: [:])))
        XCTAssertTrue(
            reason.contains("could not tell"),
            "an unanswered question is not the same as an idle pane")
    }

    func testAPaneThatIsItsOwnProcessRefuses() throws {
        // No shell under it, so it can never be judged idle again — and it
        // would not come back as itself either.
        let reason = try XCTUnwrap(
            refusal(plan(layouts: ["w1:t1": layout(secondCommand: "tail")])))
        XCTAssertTrue(reason.contains("tail"))
        XCTAssertTrue(reason.contains("rather than a shell"))
    }

    func testAnAgentInNoLayoutRefuses() throws {
        // Both layout panes answered for, so the stranded agent is the only
        // thing left to object to.
        let reason = try XCTUnwrap(
            refusal(
                plan(
                    panes: [agentPane(pane: "w1:p9"), agentPane(), plainPane()],
                    processes: ["w1:p1": idleShell("w1:p1"), "w1:p2": idleShell("w1:p2")])))
        XCTAssertTrue(
            reason.contains("w1:p9"),
            "closing here would strand a conversation nothing points at any more")
    }

    func testAMissingLayoutRefuses() throws {
        let reason = try XCTUnwrap(refusal(plan(layouts: [:])))
        XCTAssertTrue(reason.contains("could not read the layout"))
    }

    func testZoomIsRememberedBecauseApplyCannotRestoreIt() throws {
        let record = try plan(layouts: ["w1:t1": layout(zoomed: true)]).get()
        XCTAssertTrue(record.tabs[0].zoomed, "pane.zoom has to put it back afterwards")
    }

    func testTheStoredTreeCarriesNoCommands() throws {
        // Belt and braces with the refusal above: a record written today must
        // not revive into a pane whose idleness can never be judged again.
        let record = try plan().get()
        XCTAssertTrue(record.tabs[0].root.leaves.allSatisfy { $0.pane.command == nil })
    }

    func testAgentsInSeveralTabsAreEachPlacedInTheirOwn() throws {
        let second = decode(
            Reply.Layout.self,
            """
            {"tab_id": "w1:t2", "zoomed": false, "focused_pane_id": "w1:p3",
             "root": {"type": "pane", "pane_id": "w1:p3", "cwd": "/src/augur"}}
            """)
        let record = try plan(
            panes: [agentPane(pane: "w1:p1"), agentPane(pane: "w1:p3", agent: "codex", tab: "w1:t2"), plainPane()],
            layouts: ["w1:t1": layout(), "w1:t2": second],
            tabs: [tab(), tab("w1:t2", label: "2")]
        ).get()

        XCTAssertEqual(record.tabs.count, 2)
        XCTAssertEqual(record.tabs[0].agents.map(\.path), [[false]])
        XCTAssertEqual(record.tabs[1].agents.map(\.path), [[]], "a lone pane is the root")
    }
}
