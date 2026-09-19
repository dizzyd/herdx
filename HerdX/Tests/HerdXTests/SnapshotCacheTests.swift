import AppKit
import XCTest

@testable import HerdX

/// Pane ids are unique within a server and no further, so state left over from
/// the machine just left is not a dead reference on the new one.
@MainActor
final class SwitchingMachinesTests: XCTestCase {
    private func snapshot(bootID: String, focusedPane: String) -> Snapshot {
        let json = """
            {
              "boot_id": "\(bootID)",
              "revision": 7,
              "focused_pane_id": "\(focusedPane)",
              "workspaces": [],
              "tabs": [],
              "panes": [],
              "agents": []
            }
            """
        return try! JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    // MARK: - The cached snapshot

    func testTheCurrentSnapshotFollowsTheActiveMachine() {
        var cache = SnapshotCache()
        cache.record(snapshot(bootID: "boot-local", focusedPane: "w1:p1"), forEndpoint: 0)
        cache.record(snapshot(bootID: "boot-remote", focusedPane: "w1:p1"), forEndpoint: 1)

        XCTAssertEqual(cache.current?.bootID, "boot-local")

        cache.activate(1)

        XCTAssertEqual(
            cache.current?.bootID, "boot-remote",
            "a command built from this would carry the wrong machine's boot id")
    }

    func testAMachineThatHasSentNothingHasNoSnapshot() {
        var cache = SnapshotCache()
        cache.record(snapshot(bootID: "boot-local", focusedPane: "w1:p1"), forEndpoint: 0)

        cache.activate(1)

        XCTAssertNil(
            cache.current,
            "no snapshot is the honest answer; the previous machine's is not")
        XCTAssertEqual(
            cache[endpoint: 0]?.bootID, "boot-local",
            "the machine switched away from keeps its own, for the sidebar")
    }

    func testASnapshotIsFiledAgainstTheMachineThatSentIt() {
        var cache = SnapshotCache()
        cache.activate(2)
        cache.record(snapshot(bootID: "boot-two", focusedPane: "w1:p1"), forEndpoint: 2)
        cache.record(snapshot(bootID: "boot-zero", focusedPane: "w1:p9"), forEndpoint: 0)

        XCTAssertEqual(cache.current?.bootID, "boot-two")
        XCTAssertEqual(cache[endpoint: 0]?.bootID, "boot-zero")
    }

    func testSwitchingBackFindsTheMachineStillRemembered() {
        var cache = SnapshotCache()
        cache.record(snapshot(bootID: "boot-local", focusedPane: "w1:p1"), forEndpoint: 0)
        cache.record(snapshot(bootID: "boot-remote", focusedPane: "w2:p3"), forEndpoint: 1)

        cache.activate(1)
        cache.activate(0)

        XCTAssertEqual(cache.current?.bootID, "boot-local")
        XCTAssertEqual(cache.current?.focusedPaneID, "w1:p1")
    }

    // MARK: - The focused pane

    func testForgettingASurfaceForgetsItsFocusedPane() {
        let view = TerminalGridView(font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                    lineHeight: 1)
        view.focusedPaneFromSnapshot = "w1:p1"

        view.forgetSurface()

        XCTAssertNil(
            view.focusedPane,
            "w1:p1 exists on the new machine too, and it is not the same pane")
    }

    func testForgettingASurfaceAlsoDropsSelectionAndCopyMode() {
        let view = TerminalGridView(font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                    lineHeight: 1)
        view.selection = Selection(
            paneID: "w1:p1",
            anchor: Selection.Point(row: 0, column: 0),
            cursor: Selection.Point(row: 0, column: 4),
            origin: .span)

        view.forgetSurface()

        XCTAssertNil(view.selection)
        XCTAssertNil(view.copyMode)
    }
}
