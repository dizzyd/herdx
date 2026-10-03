import XCTest

@testable import HerdX

/// Hibernation ends somebody's processes, so what it knows must be current.
///
/// Every reading it takes is already out of date by the time the close goes
/// out: the agent status came from a `pane.list` issued alongside the layout
/// and process queries, and the close follows all of them. An agent that
/// started a turn in that window was killed mid-turn by a decision taken
/// before it began.
///
/// These pin the late reread. They do not pin atomicity, because there is
/// none to pin — `workspace.close` carries a workspace id and nothing to
/// check it against.
@MainActor
final class HibernationRaceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("herdx-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: HibernationStore {
        HibernationStore(url: directory.appendingPathComponent("hibernated.json"))
    }

    private func workspace() -> Snapshot.Workspace {
        try! JSONDecoder().decode(
            Snapshot.Workspace.self,
            from: Data(
                """
                {"workspace_id":"w1","number":1,"label":"augur","focused":false,
                 "agent_status":"idle","active_tab_id":"w1:t1"}
                """.utf8))
    }

    private func tab() -> Snapshot.Tab {
        try! JSONDecoder().decode(
            Snapshot.Tab.self,
            from: Data(
                """
                {"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1",
                 "zoomed":false,"focused":true,"agent_status":"idle"}
                """.utf8))
    }

    private func pane() -> Snapshot.Pane {
        try! JSONDecoder().decode(
            Snapshot.Pane.self,
            from: Data(
                """
                {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,
                 "agent_status":"idle"}
                """.utf8))
    }

    /// One pane holding a resumable agent, in whatever state is asked for.
    private func paneList(_ status: String, paneID: String = "w1:p1") -> String {
        """
        {"id":"1","result":{"panes":[
          {"pane_id":"\(paneID)","workspace_id":"w1","tab_id":"w1:t1",
           "agent_status":"\(status)",
           "agent_session":{"source":"herdr:claude","agent":"claude","kind":"id",
                            "value":"conv"}}]}}
        """
    }

    private let layout = """
        {"id":"1","result":{"layout":{"tab_id":"w1:t1","zoomed":false,
         "focused_pane_id":"w1:p1","root":{"type":"pane","pane_id":"w1:p1"}}}}
        """

    /// An idle shell, so the plan's process rule is satisfied.
    private let processInfo = """
        {"id":"1","result":{"process_info":{"pane_id":"w1:p1","shell_pid":42,
         "foreground_process_group_id":42,
         "foreground_processes":[{"pid":42,"name":"zsh","argv":["-zsh"]}]}}}
        """

    /// The case the review reproduced: idle when first asked, working by the
    /// time the close would go out.
    func testAnAgentThatStartsWorkingDuringInspectionIsNotClosed() throws {
        var closes = 0
        var listCalls = 0
        let hibernator = Hibernator(store: store) { command, _, then in
            switch command.method {
            case "pane.list":
                listCalls += 1
                // Idle to the inspection, working to the reread — an agent
                // that picked up a turn while the layouts were being read.
                then(.success(self.paneList(listCalls == 1 ? "idle" : "working")))
            case "layout.export": then(.success(self.layout))
            case "pane.process_info": then(.success(self.processInfo))
            case "workspace.close":
                closes += 1
                then(.success(#"{"id":"1","result":{}}"#))
            default: then(.success(#"{"id":"1","result":{}}"#))
            }
        }

        let settled = expectation(description: "hibernate settles")
        var outcome: Result<Hibernated, Error>?
        hibernator.hibernate(
            workspace: workspace(), in: snapshot(), endpointID: "local", socket: nil
        ) { outcome = $0; settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(closes, 0, "an agent mid-turn had its workspace closed under it")
        guard case .failure = outcome else {
            return XCTFail("hibernation reported success after refusing to close")
        }
        XCTAssertTrue(
            hibernator.records.isEmpty,
            "a record was kept for a workspace that is still running")
        XCTAssertTrue(store.load().isEmpty, "the file kept it too")
    }

    /// A tab opened while the layouts were being read is not in the record, so
    /// closing the workspace would throw it away with nothing written down.
    func testAWorkspaceThatGrewDuringInspectionIsNotClosed() throws {
        var closes = 0
        var listCalls = 0
        let hibernator = Hibernator(store: store) { command, _, then in
            switch command.method {
            case "pane.list":
                listCalls += 1
                guard listCalls > 1 else { return then(.success(self.paneList("idle"))) }
                // A second pane has appeared since, in a tab nothing read.
                then(
                    .success(
                        """
                        {"id":"1","result":{"panes":[
                          {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1",
                           "agent_status":"idle",
                           "agent_session":{"source":"herdr:claude","agent":"claude",
                                            "kind":"id","value":"conv"}},
                          {"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t2",
                           "agent_status":"idle"}]}}
                        """))
            case "layout.export": then(.success(self.layout))
            case "pane.process_info": then(.success(self.processInfo))
            case "workspace.close":
                closes += 1
                then(.success(#"{"id":"1","result":{}}"#))
            default: then(.success(#"{"id":"1","result":{}}"#))
            }
        }

        let settled = expectation(description: "hibernate settles")
        hibernator.hibernate(
            workspace: workspace(), in: snapshot(), endpointID: "local", socket: nil
        ) { _ in settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(closes, 0, "a tab nobody wrote down was closed with the workspace")
        XCTAssertTrue(hibernator.records.isEmpty)
    }

    /// And a workspace that really is quiet still hibernates, or the reread
    /// would have made the feature useless rather than safe.
    func testAQuietWorkspaceStillCloses() throws {
        var closes = 0
        let hibernator = Hibernator(store: store) { command, _, then in
            switch command.method {
            case "pane.list": then(.success(self.paneList("idle")))
            case "layout.export": then(.success(self.layout))
            case "pane.process_info": then(.success(self.processInfo))
            case "workspace.close":
                closes += 1
                then(.success(#"{"id":"1","result":{}}"#))
            default: then(.success(#"{"id":"1","result":{}}"#))
            }
        }

        let settled = expectation(description: "hibernate settles")
        var outcome: Result<Hibernated, Error>?
        hibernator.hibernate(
            workspace: workspace(), in: snapshot(), endpointID: "local", socket: nil
        ) { outcome = $0; settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(closes, 1)
        guard case .success = outcome else {
            return XCTFail("a quiet workspace was refused: \(String(describing: outcome))")
        }
        XCTAssertEqual(hibernator.records.count, 1)
    }

    /// Same panes is not the same work.
    ///
    /// A pane that swapped one conversation for another between the first
    /// reading and the last is idle both times and keeps its id, so nothing
    /// about its status or shape notices. The record still names the
    /// conversation that has gone: closing ends the one that is there and
    /// revives the one that is not.
    func testAPaneThatChangedConversationIsNotClosed() {
        func entry(_ value: String) -> Reply.PaneEntry {
            Reply.PaneEntry(
                paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", agentStatus: .idle,
                agentSession: Reply.Session(
                    source: "herdr:claude", agent: "claude", kind: "id", value: value))
        }
        XCTAssertNotNil(
            Hibernator.changed(from: [entry("conversation-A")], to: [entry("conversation-B")]),
            "the record names a conversation that is no longer in the pane")
        XCTAssertNil(Hibernator.changed(from: [entry("same")], to: [entry("same")]))
    }

    /// And a plain pane that picked up an agent is a conversation nothing
    /// wrote down.
    func testAPaneThatGainedAnAgentIsNotClosed() {
        let plain = Reply.PaneEntry(
            paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", agentStatus: .unknown,
            agentSession: nil)
        let withAgent = Reply.PaneEntry(
            paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", agentStatus: .idle,
            agentSession: Reply.Session(
                source: "herdr:claude", agent: "claude", kind: "id", value: "new"))
        XCTAssertNotNil(Hibernator.changed(from: [plain], to: [withAgent]))
    }

    /// A refused reread is not an answer, and this is the question standing
    /// between a quiet workspace and one ended mid-turn.
    func testARefusedRereadStopsTheClose() throws {
        var closes = 0
        var listCalls = 0
        let hibernator = Hibernator(store: store) { command, _, then in
            switch command.method {
            case "pane.list":
                listCalls += 1
                guard listCalls > 1 else { return then(.success(self.paneList("idle"))) }
                then(.failure(LocalAPI.Failure(reason: "the server stopped answering")))
            case "layout.export": then(.success(self.layout))
            case "pane.process_info": then(.success(self.processInfo))
            case "workspace.close":
                closes += 1
                then(.success(#"{"id":"1","result":{}}"#))
            default: then(.success(#"{"id":"1","result":{}}"#))
            }
        }

        let settled = expectation(description: "hibernate settles")
        hibernator.hibernate(
            workspace: workspace(), in: snapshot(), endpointID: "local", socket: nil
        ) { _ in settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(closes, 0, "the workspace was closed on an unanswered question")
    }

    private func snapshot() -> Snapshot {
        try! JSONDecoder().decode(
            Snapshot.self,
            from: Data(
                """
                {"boot_id":"boot","revision":1,
                 "workspaces":[{"workspace_id":"w1","number":1,"label":"augur","focused":false,
                                "agent_status":"idle","active_tab_id":"w1:t1"}],
                 "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1",
                          "zoomed":false,"focused":true,"agent_status":"idle"}],
                 "panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1",
                           "focused":true,"agent_status":"idle"}],
                 "agents":[]}
                """.utf8))
    }
}
