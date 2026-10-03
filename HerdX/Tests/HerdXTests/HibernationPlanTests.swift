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
        tabs: [Snapshot.Tab]? = nil,
        background: [String: [String]] = [:]
    ) -> Result<Hibernated, HibernationPlan.Refusal> {
        HibernationPlan.plan(
            workspace: workspace(),
            tabs: tabs ?? [tab()],
            endpointID: "local",
            panes: panes ?? [agentPane(), plainPane()],
            processes: processes ?? ["w1:p2": idleShell("w1:p2")],
            layouts: layouts ?? ["w1:t1": layout()],
            background: background,
            at: Date(timeIntervalSince1970: 1_758_000_000))
    }

    private func refusal(_ result: Result<Hibernated, HibernationPlan.Refusal>) -> String? {
        if case .failure(let refusal) = result { return refusal.reason }
        return nil
    }

    // MARK: - What counts as a shell at a prompt

    private func info(_ json: String) -> Reply.Info { decode(Reply.Info.self, json) }

    func testALoneShellInItsOwnGroupIsReady() {
        XCTAssertTrue(
            info(
                """
                {"pane_id": "p", "shell_pid": 100, "foreground_process_group_id": 100,
                 "foreground_processes": [{"pid": 100, "name": "zsh"}]}
                """
            ).isIdleShell)
    }

    func testAShellRunningItsStartupFilesIsNotReady() {
        // Measured: a zsh whose rc file initialises conda spawns python *in the
        // shell's own process group*, so the group id still matches while the
        // shell is plainly busy. A revive that trusted the group id alone died
        // with "is not an available shell".
        XCTAssertFalse(
            info(
                """
                {"pane_id": "p", "shell_pid": 100, "foreground_process_group_id": 100,
                 "foreground_processes": [{"pid": 109, "name": "python3.12"},
                                          {"pid": 100, "name": "zsh"}]}
                """
            ).isIdleShell,
            "agent.start refuses this pane, so waiting on it has to as well")
    }

    func testALoginShellIsStillAShell() {
        XCTAssertTrue(
            info(
                """
                {"pane_id": "p", "shell_pid": 100, "foreground_process_group_id": 100,
                 "foreground_processes": [{"pid": 100, "name": "-zsh"}]}
                """
            ).isIdleShell,
            "herdr strips the leading dash before deciding")
    }

    func testAPaneThatIsItsOwnProcessIsNotAShell() {
        // A pane launched with an argv has no shell under it, so its group id
        // equals its own pid while it is busy running that argv.
        XCTAssertFalse(
            info(
                """
                {"pane_id": "p", "shell_pid": 100, "foreground_process_group_id": 100,
                 "foreground_processes": [{"pid": 100, "name": "sleep"}]}
                """
            ).isIdleShell)
    }

    func testAPaneWithNoShellPidIsNotReady() {
        XCTAssertFalse(
            info(#"{"pane_id": "p", "foreground_processes": []}"#).isIdleShell)
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

    // MARK: - What is running behind the prompt

    /// `isIdleShell` reads the foreground job, which is the right question for
    /// "is this a shell at a prompt" and the wrong one for "may everything
    /// here be killed": a background job has its own process group and never
    /// appears in it.
    func testABackgroundJobBehindAnIdleShellRefuses() {
        let refused = plan(background: ["w1:p2": ["node"]])
        XCTAssertEqual(
            refusal(refused), "node is running in the background of w1:p2",
            "a dev server behind a prompt was read as an idle pane")
    }

    /// And nothing behind it is still fine, or the rule would end hibernation
    /// for every workspace with a spare shell in it.
    func testAnIdleShellWithNothingBehindItStillHibernates() {
        XCTAssertNil(refusal(plan(background: [:])))
    }

    /// The agent's own pane is judged by its agent, not by what is under its
    /// shell — the agent *is* what is under its shell.
    func testTheAgentsOwnPaneIsNotJudgedByItsChildren() {
        XCTAssertNil(refusal(plan(background: ["w1:p1": ["claude"]])))
    }

    /// The walk is over descendants, so a server spawned by a background
    /// build counts as much as the build.
    func testADescendantCountsNotJustAChild() {
        let table = [
            LocalProcesses.Entry(pid: 10, ppid: 1, name: "zsh"),
            LocalProcesses.Entry(pid: 11, ppid: 10, name: "npm"),
            LocalProcesses.Entry(pid: 12, ppid: 11, name: "node"),
        ]
        XCTAssertEqual(
            LocalProcesses.unaccounted(under: 10, foreground: [10], in: table).sorted(),
            ["node", "npm"])
    }

    /// What the foreground job already accounts for is not news: the shell
    /// itself, and whatever `pane.process_info` listed.
    func testTheForegroundJobIsNotCountedTwice() {
        let table = [
            LocalProcesses.Entry(pid: 10, ppid: 1, name: "zsh"),
            LocalProcesses.Entry(pid: 11, ppid: 10, name: "vim"),
        ]
        XCTAssertTrue(
            LocalProcesses.unaccounted(under: 10, foreground: [10, 11], in: table).isEmpty,
            "the pane's own foreground process was reported as a background job")
    }

    /// A table read while processes come and go can disagree with itself, and
    /// a cycle in it must not become a loop.
    func testAnInconsistentTableDoesNotHang() {
        let table = [
            LocalProcesses.Entry(pid: 10, ppid: 11, name: "a"),
            LocalProcesses.Entry(pid: 11, ppid: 10, name: "b"),
        ]
        XCTAssertEqual(LocalProcesses.unaccounted(under: 10, foreground: [], in: table), ["b"])
    }

    // MARK: - References revival cannot spend

    /// Having a session reference is not the same as being able to use it.
    /// herdr validates the characters, not the meaning: a letta conversation
    /// of `default:` names no agent, and every revive would roll back.
    func testASessionRevivalCannotResumeRefuses() {
        let letta = agentPane(agent: "letta")
        let refused = plan(
            panes: [
                Reply.PaneEntry(
                    paneID: letta.paneID, workspaceID: letta.workspaceID, tabID: letta.tabID,
                    agentStatus: letta.agentStatus,
                    agentSession: Reply.Session(
                        source: "herdr:letta", agent: "letta", kind: "id", value: "default:")),
                plainPane(),
            ])
        XCTAssertEqual(
            refusal(refused)?.contains("cannot resume"), true,
            "a reference nothing can spend was saved and the workspace closed: "
                + "\(refusal(refused) ?? "accepted")")
    }

    /// The same shape with an agent id after it is fine, so the rule is about
    /// the reference rather than about letta.
    func testAUsableLettaReferenceIsAccepted() {
        let letta = agentPane(agent: "letta")
        XCTAssertNil(
            refusal(
                plan(
                    panes: [
                        Reply.PaneEntry(
                            paneID: letta.paneID, workspaceID: letta.workspaceID,
                            tabID: letta.tabID, agentStatus: letta.agentStatus,
                            agentSession: Reply.Session(
                                source: "herdr:letta", agent: "letta", kind: "id",
                                value: "default:ag-7")),
                        plainPane(),
                    ])))
    }

    // MARK: - Layouts herdr will not rebuild

    /// A balanced tree of `leaves` panes, as `layout.export` would report one.
    private func wideLayout(leaves: Int) -> Reply.Layout {
        func node(_ ids: ArraySlice<Int>) -> String {
            guard ids.count > 1 else {
                return #"{"type":"pane","pane_id":"w1:p\#(ids.first!)","cwd":"/src/augur"}"#
            }
            let middle = ids.startIndex + ids.count / 2
            return """
                {"type":"split","direction":"right","ratio":0.5,
                 "first":\(node(ids[ids.startIndex..<middle])),
                 "second":\(node(ids[middle..<ids.endIndex]))}
                """
        }
        return decode(
            Reply.Layout.self,
            """
            {"tab_id":"w1:t1","zoomed":false,"focused_pane_id":"w1:p1",
             "root":\(node(Array(1...leaves)[...]))}
            """)
    }

    /// A spine of `depth` nodes: every split's second child is another split.
    private func deepLayout(depth: Int) -> Reply.Layout {
        func node(_ level: Int) -> String {
            guard level < depth else {
                return #"{"type":"pane","pane_id":"w1:p\#(level)","cwd":"/src/augur"}"#
            }
            return """
                {"type":"split","direction":"right","ratio":0.5,
                 "first":{"type":"pane","pane_id":"w1:q\(level)","cwd":"/src/augur"},
                 "second":\(node(level + 1))}
                """
        }
        return decode(
            Reply.Layout.self,
            """
            {"tab_id":"w1:t1","zoomed":false,"focused_pane_id":"w1:p1",
             "root":\(node(1))}
            """)
    }

    private func resumablePanes(_ count: Int) -> [Reply.PaneEntry] {
        (1...count).map { agentPane(pane: "w1:p\($0)") }
    }

    /// The leaves a `deepLayout` actually has: one `q` per split, then the
    /// `p` at the bottom. Every one needs an agent, or the plan refuses for a
    /// reason that has nothing to do with the depth being tested.
    private func deepPanes(depth: Int) -> [Reply.PaneEntry] {
        (1..<depth).map { agentPane(pane: "w1:q\($0)") } + [agentPane(pane: "w1:p\(depth)")]
    }

    /// `layout.export` hands over trees `layout.apply` refuses, and nothing
    /// stops you splitting your way into one.
    ///
    /// Saving and closing such a workspace is the worst outcome available: it
    /// is gone, every revive is refused `invalid_layout` and rolls back, and
    /// the record pointing at those conversations can never be spent.
    func testATabWithMorePanesThanHerdrWillRebuildIsRefused() {
        let refused = plan(
            panes: resumablePanes(25),
            processes: [:],
            layouts: ["w1:t1": wideLayout(leaves: 25)])
        XCTAssertEqual(
            refusal(refused),
            "w1:t1 has 25 panes, and herdr will not rebuild more than 24")
    }

    /// herdr's own boundary, so a change upstream fails here rather than at
    /// somebody's next revive.
    func testExactlyHerdrsLimitIsStillAllowed() {
        let allowed = plan(
            panes: resumablePanes(24),
            processes: [:],
            layouts: ["w1:t1": wideLayout(leaves: 24)])
        XCTAssertNil(refusal(allowed), "24 is the limit, not one past it")
    }

    /// Depth is counted herdr's way, with the root as 1.
    func testATabSplitDeeperThanHerdrWillRebuildIsRefused() {
        let deep = deepLayout(depth: 17)
        XCTAssertEqual(deep.root.depth, 17, "the fixture is not the depth it claims")
        let refused = plan(
            panes: deepPanes(depth: 17), processes: [:], layouts: ["w1:t1": deep])
        XCTAssertEqual(
            refusal(refused),
            "w1:t1 is split 17 deep, and herdr will not rebuild deeper than 16")
    }

    func testExactlyHerdrsDepthLimitIsStillAllowed() {
        let deep = deepLayout(depth: 16)
        XCTAssertEqual(deep.root.depth, 16)
        XCTAssertNil(
            refusal(plan(panes: deepPanes(depth: 16), processes: [:], layouts: ["w1:t1": deep])))
    }

    /// A lone pane is depth 1, which is what herdr counts it as.
    func testALonePaneIsDepthOne() {
        XCTAssertEqual(LayoutNode.pane(LayoutNode.Pane(paneID: "w1:p1")).depth, 1)
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

    /// The tabs and the process readings come from the snapshot; the pane list
    /// is fetched afterwards. A tab another client made in between is in the
    /// pane list and nowhere else, so nothing above would have looked at it.
    func testAPaneInNoLayoutIsNotClosedUnexamined() throws {
        let reason = try XCTUnwrap(
            refusal(plan(panes: [agentPane(), plainPane(), plainPane("w1:p3", tab: "w1:t2")])),
            "the workspace would be closed with an unexamined pane in it")
        XCTAssertTrue(reason.contains("w1:p3"), reason)
    }

    /// Answering for it does not help: it is still in no exported tree, so
    /// closing the workspace would end it without writing it down.
    func testAnUnplacedPaneRefusesEvenWithProcessInfo() throws {
        let reason = try XCTUnwrap(
            refusal(
                plan(
                    panes: [agentPane(), plainPane(), plainPane("w1:p3", tab: "w1:t2")],
                    processes: ["w1:p2": idleShell("w1:p2"), "w1:p3": busyShell("w1:p3")])),
            "a busy pane outside the layout was accepted")
        XCTAssertTrue(reason.contains("w1:p3"), reason)
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
