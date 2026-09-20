import XCTest

@testable import HerdX

/// The store holds the only reference to conversations that are otherwise
/// unreachable, so losing it quietly is the failure that matters.
final class HibernationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("herdx-hibernation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: HibernationStore {
        HibernationStore(url: directory.appendingPathComponent("hibernated.json"))
    }

    private func record(label: String = "augur") -> Hibernated {
        Hibernated(
            id: UUID(), endpointID: "local", number: 3, label: label,
            cwd: "/Users/dizzyd/src/augur", branch: "main",
            at: Date(timeIntervalSince1970: 1_758_000_000),
            tabs: [
                Hibernated.Tab(
                    label: "1", zoomed: false,
                    root: .split(
                        .init(
                            direction: "right", ratio: 0.35,
                            first: .pane(.init(cwd: "/Users/dizzyd/src/augur")),
                            second: .pane(.init(cwd: "/tmp")))),
                    focused: [false],
                    agents: [
                        Hibernated.Agent(
                            path: [false], source: "herdr:claude", agent: "claude",
                            kind: "id", value: "abc123")
                    ])
            ])
    }

    func testARecordSurvivesTheFile() throws {
        let original = record()
        try store.save([original])

        XCTAssertEqual(store.load(), [original], "what comes back is not what went in")
    }

    func testTheTreeAndTheAgentPathSurviveTogether() throws {
        try store.save([record()])
        let loaded = try XCTUnwrap(store.load().first)
        let agent = try XCTUnwrap(loaded.agents.first)

        // The path is the whole point: pane ids do not survive a revive, so an
        // agent is matched to its pane by position in the stored tree.
        XCTAssertEqual(
            loaded.tabs[0].root.leaf(at: agent.path)?.cwd, "/Users/dizzyd/src/augur",
            "the agent no longer points at the pane it came out of")
    }

    func testNoFileMeansNothingHibernated() {
        XCTAssertEqual(store.load(), [], "a first run must not look like a failure")
    }

    func testAnUnreadableFileIsKeptRatherThanOverwritten() throws {
        let store = self.store
        try Data("this is not json".utf8).write(to: store.url)

        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.url.path),
            "the unreadable file is moved out of the way")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.url.appendingPathExtension("unreadable").path),
            "and kept, because it is the only record of those conversations")
    }

    func testSavingReplacesRatherThanAppends() throws {
        let store = self.store
        try store.save([record(label: "first")])
        try store.save([record(label: "second")])

        XCTAssertEqual(store.load().map(\.label), ["second"])
    }
}
