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
}
