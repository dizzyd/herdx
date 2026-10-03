import XCTest

@testable import HerdX

/// The record is the only pointer to conversations the workspace no longer
/// holds, so what happens to it on a failure is the whole question.
@MainActor
final class HibernationRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("herdx-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: HibernationStore {
        HibernationStore(url: directory.appendingPathComponent("hibernated.json"))
    }

    /// What `layout.apply` answers on each call, in the order revival makes
    /// them: the first tab's single pane, then the second tab's split.
    private static func appliedLayout(call: Int) -> String {
        if call == 1 {
            return """
                {"id":"1","result":{"layout":{"tab_id":"w9:t1","zoomed":false,
                "focused_pane_id":"w9:p1","root":{"type":"pane","pane_id":"w9:p1"}}}}
                """
        }
        return """
            {"id":"1","result":{"layout":{"tab_id":"w9:t2","zoomed":false,
            "focused_pane_id":"w9:p2","root":{"type":"split","direction":"row","ratio":0.5,
            "first":{"type":"pane","pane_id":"w9:p2"},
            "second":{"type":"pane","pane_id":"w9:p3"}}}}}
            """
    }

    private func record() -> Hibernated {
        Hibernated(
            id: UUID(), endpointID: "local", number: 1, label: "augur",
            cwd: "/tmp", branch: nil, at: Date(timeIntervalSince1970: 1_758_000_000),
            tabs: [
                Hibernated.Tab(
                    label: "1", zoomed: false, root: .pane(.init(cwd: "/tmp")), focused: [],
                    agents: [
                        Hibernated.Agent(
                            path: [], source: "herdr:claude", agent: "claude",
                            kind: "id", value: "abc123")
                    ])
            ])
    }

    // MARK: - Reading the close reply

    func testAServerRefusalIsNotTheSameAnswerAsSilence() {
        XCTAssertEqual(
            Hibernator.outcome(of: .success(#"{"id":"1","result":{}}"#)), .closed)
        XCTAssertEqual(
            Hibernator.outcome(
                of: .success(#"{"id":"1","error":{"code":"busy","message":"a pane is busy"}}"#)),
            .refused("a pane is busy"))
        XCTAssertEqual(
            Hibernator.outcome(of: .failure(LocalAPI.Failure(reason: "workspace.close timed out"))),
            .unknown("workspace.close timed out"))
    }

    /// herdr closes the workspace before it encodes the reply, so a reply we
    /// cannot read tells us nothing about whether it happened.
    func testAnUnreadableReplyIsNotReadAsARefusal() {
        XCTAssertEqual(
            Hibernator.outcome(of: .success("not json at all")),
            .unknown("the reply to workspace.close could not be read"))
        XCTAssertEqual(
            Hibernator.outcome(of: .success(#"{"id":"1"}"#)),
            .unknown("the reply to workspace.close carried no result"))
    }

    // MARK: - What the record does about it

    /// The close may already have happened, and the workspace with it.
    func testALostCloseReplyKeepsTheRecord() throws {
        let store = self.store
        let hibernator = Hibernator(store: store) { command, _, then in
            if command.method == "workspace.close" {
                then(.failure(LocalAPI.Failure(reason: "workspace.close timed out")))
            } else {
                then(.success(#"{"id":"1","result":{}}"#))
            }
        }
        var failure: Error?
        hibernator.write(record(), closing: "w1", socket: nil) {
            if case .failure(let error) = $0 { failure = error }
        }

        XCTAssertNotNil(failure, "a lost reply is still a failure to report")
        XCTAssertEqual(hibernator.records.count, 1, "the record was dropped on an unknown outcome")
        XCTAssertEqual(store.load().count, 1, "the file was left without the record")
    }

    /// The server answering no means the workspace is still on screen.
    func testARefusedCloseTakesTheRecordBackOut() throws {
        let store = self.store
        let hibernator = Hibernator(store: store) { command, _, then in
            if command.method == "workspace.close" {
                then(.success(#"{"id":"1","error":{"code":"busy","message":"a pane is busy"}}"#))
            } else {
                then(.success(#"{"id":"1","result":{}}"#))
            }
        }
        hibernator.write(record(), closing: "w1", socket: nil) { _ in }

        XCTAssertEqual(hibernator.records, [], "a record was left for a running workspace")
        XCTAssertEqual(store.load(), [], "the file kept a record for a running workspace")
    }

    func testACloseThatWorkedLeavesTheRecordInPlace() throws {
        let store = self.store
        let hibernator = Hibernator(store: store) { _, _, then in
            then(.success(#"{"id":"1","result":{}}"#))
        }
        var saved: Hibernated?
        hibernator.write(record(), closing: "w1", socket: nil) {
            if case .success(let record) = $0 { saved = record }
        }

        XCTAssertNotNil(saved)
        XCTAssertEqual(store.load().count, 1)
    }

    /// A revive that restored one agent and then failed leaves the rest of the
    /// session ids nowhere but the record.
    func testAReviveWhoseRollbackFailsStillKeepsTheRecord() throws {
        let store = self.store
        let original = record()
        try store.save([original])

        let hibernator = Hibernator(store: store) { command, _, then in
            switch command.method {
            case "workspace.create":
                then(.success(#"""
                    {"id":"1","result":{"workspace":{"workspace_id":"w9"},
                    "tab":{"tab_id":"w9:t1"},"root_pane":{"pane_id":"w9:p1"}}}
                    """#))
            case "workspace.close":
                // The rollback is refused too: the husk stays standing.
                then(.success(#"{"id":"1","error":{"message":"could not close it"}}"#))
            default:
                then(.success(#"{"id":"1","error":{"message":"no"}}"#))
            }
        }
        XCTAssertEqual(hibernator.records.count, 1)

        let finished = expectation(description: "revive settles")
        hibernator.revive(original.id, socket: nil) { result in
            if case .success = result { XCTFail("this revive cannot succeed") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)

        XCTAssertEqual(
            hibernator.records.count, 1,
            "the record was forgotten although the husk never took the agent's session")
        XCTAssertEqual(store.load().count, 1, "the file lost the record")
    }

    // MARK: - Coming back zoomed

    /// A record of two tabs: the second split in two and zoomed on its right
    /// leaf, which is the saved focus path `[true]`.
    private func zoomedOnTheRightOfTheSecondTab() -> Hibernated {
        func split() -> LayoutNode {
            .split(
                LayoutNode.Split(
                    direction: "row", ratio: 0.5,
                    first: .pane(LayoutNode.Pane(cwd: "/tmp")),
                    second: .pane(LayoutNode.Pane(cwd: "/tmp"))))
        }
        return Hibernated(
            id: UUID(), endpointID: "local", number: 1, label: "augur",
            cwd: "/tmp", branch: nil, at: Date(timeIntervalSince1970: 1_758_000_000),
            tabs: [
                Hibernated.Tab(
                    label: "1", zoomed: false, root: .pane(LayoutNode.Pane(cwd: "/tmp")), focused: [],
                    agents: []),
                Hibernated.Tab(
                    label: "2", zoomed: true, root: split(), focused: [true], agents: []),
            ])
    }

    /// Revival zoomed the first leaf of every zoomed tab, so a tab zoomed on
    /// its right split came back zoomed on the left one.
    ///
    /// Not cosmetic: the server focuses whatever pane it zooms, and the focus
    /// repair at the end only ever covered the first tab. So the workspace
    /// came back looking at a pane nobody left it on.
    func testAZoomedTabComesBackOnThePaneItWasZoomedOn() throws {
        let store = self.store
        let original = zoomedOnTheRightOfTheSecondTab()
        try store.save([original])

        var zoomed: [String] = []
        var focused: [String] = []
        var applies = 0
        let hibernator = Hibernator(store: store) { command, _, then in
            switch command.method {
            case "workspace.create":
                then(.success(#"""
                    {"id":"1","result":{"workspace":{"workspace_id":"w9"},
                    "tab":{"tab_id":"w9:t1"},"root_pane":{"pane_id":"w9:p1"}}}
                    """#))
            case "layout.apply":
                // One per tab, in order: the first tab is a single pane,
                // the second is the split. A `[true]` path in that split
                // names its second child, `w9:p3`.
                applies += 1
                then(.success(Self.appliedLayout(call: applies)))
            case "pane.zoom":
                zoomed.append(Self.paneID(in: command))
                then(.success(#"{"id":"1","result":{}}"#))
            case "pane.focus":
                focused.append(Self.paneID(in: command))
                then(.success(#"{"id":"1","result":{}}"#))
            default:
                then(.success(#"{"id":"1","result":{}}"#))
            }
        }

        let finished = expectation(description: "revive settles")
        hibernator.revive(original.id, socket: nil) { _ in finished.fulfill() }
        wait(for: [finished], timeout: 5)

        XCTAssertEqual(
            zoomed, ["w9:p3"],
            "the saved focus path [true] names the second leaf, not the first")
        XCTAssertFalse(
            zoomed.contains("w9:p2"),
            "zooming the wrong leaf also moves focus there, since the server "
                + "focuses what it zooms")
        // The first tab's saved focus is its root, which came back as w9:p1,
        // and it is asked for last so it wins over the focus the zoom moved.
        XCTAssertEqual(focused.last, "w9:p1", "the workspace did not come back where it was left")
    }

    /// A record from before focus was kept has no path to resolve, and one
    /// guess is as good as another.
    func testAZoomedTabWithNoSavedFocusFallsBackToTheFirstLeaf() throws {
        let store = self.store
        var original = zoomedOnTheRightOfTheSecondTab()
        original = Hibernated(
            id: original.id, endpointID: original.endpointID, number: original.number,
            label: original.label, cwd: original.cwd, branch: original.branch, at: original.at,
            tabs: original.tabs.map {
                Hibernated.Tab(
                    label: $0.label, zoomed: $0.zoomed, root: $0.root, focused: nil,
                    agents: $0.agents)
            })
        try store.save([original])

        var zoomed: [String] = []
        var applies = 0
        let hibernator = Hibernator(store: store) { command, _, then in
            switch command.method {
            case "workspace.create":
                then(.success(#"""
                    {"id":"1","result":{"workspace":{"workspace_id":"w9"},
                    "tab":{"tab_id":"w9:t1"},"root_pane":{"pane_id":"w9:p1"}}}
                    """#))
            case "layout.apply":
                // One per tab, in order: the first tab is a single pane,
                // the second is the split. A `[true]` path in that split
                // names its second child, `w9:p3`.
                applies += 1
                then(.success(Self.appliedLayout(call: applies)))
            case "pane.zoom":
                zoomed.append(Self.paneID(in: command))
                then(.success(#"{"id":"1","result":{}}"#))
            default:
                then(.success(#"{"id":"1","result":{}}"#))
            }
        }

        let finished = expectation(description: "revive settles")
        hibernator.revive(original.id, socket: nil) { _ in finished.fulfill() }
        wait(for: [finished], timeout: 5)

        XCTAssertEqual(zoomed, ["w9:p2"], "an unknown focus should keep the old behaviour")
    }

    /// The pane a command names, read off the request it would send.
    private static func paneID(in command: Command) -> String {
        command.params["pane_id"] as? String ?? ""
    }
}
