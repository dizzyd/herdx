import AppKit
import XCTest

@testable import HerdX

/// The up and down arrows move between panes while there are panes to move
/// between, and between sidebar rows when there are not.
@MainActor
final class SidebarNavigationTests: XCTestCase {

    // MARK: - Which list the key belongs to

    private func snapshot(panes: [(String, String)], focusedTab: String?) -> Snapshot {
        let rows = panes.map { pane, tab in
            """
            {"pane_id": "\(pane)", "tab_id": "\(tab)", "focused": false}
            """
        }.joined(separator: ",")
        let focused = focusedTab.map { "\"\($0)\"" } ?? "null"
        let json = """
            {
              "boot_id": "boot",
              "revision": 1,
              "focused_tab_id": \(focused),
              "workspaces": [],
              "tabs": [],
              "panes": [\(rows)],
              "agents": []
            }
            """
        return try! JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    func testOnlyThePanesSharingTheFocusedTabAreCounted() {
        let split = snapshot(
            panes: [("w1:p1", "w1:t1"), ("w1:p2", "w1:t1"), ("w1:p3", "w1:t2")],
            focusedTab: "w1:t1")

        XCTAssertEqual(
            split.panesInFocusedTab, 2,
            "a pane in another tab is not above or below the one you are in")
    }

    func testALoneePaneInAFocusedTabIsCountedAsOne() {
        let single = snapshot(
            panes: [("w1:p1", "w1:t1"), ("w1:p9", "w1:t7")], focusedTab: "w1:t1")

        XCTAssertEqual(single.panesInFocusedTab, 1)
    }

    // MARK: - Stepping through the rows

    func testAStepStopsAtTheEndsRatherThanWrapping() {
        XCTAssertEqual(SidebarView.step(from: 1, by: 1, count: 3), 2)
        XCTAssertEqual(SidebarView.step(from: 1, by: -1, count: 3), 0)
        XCTAssertNil(
            SidebarView.step(from: 2, by: 1, count: 3),
            "a spatial move that wraps is a list you fall off the end of")
        XCTAssertNil(SidebarView.step(from: 0, by: -1, count: 3))
    }

    func testAStepFromNowhereEntersTheListFromTheEndItIsMovingTowards() {
        XCTAssertEqual(SidebarView.step(from: nil, by: 1, count: 3), 0)
        XCTAssertEqual(SidebarView.step(from: nil, by: -1, count: 3), 2)
    }

    func testAnEmptyListGoesNowhere() {
        XCTAssertNil(SidebarView.step(from: nil, by: 1, count: 0))
        XCTAssertNil(SidebarView.step(from: 0, by: -1, count: 0))
    }

    // MARK: - What the rows are

    /// Builds the sidebar the way the app does, then asks it to move.
    private func sidebar(_ endpoints: [EndpointInfo], active: Int = 0) -> SidebarView {
        let view = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        view.update(endpoints: endpoints, active: active)
        return view
    }

    private func endpoint(
        _ index: Int, _ id: String, _ label: String, workspaces: [(String, Bool)]
    ) -> EndpointInfo {
        let rows = workspaces.map { id, focused in
            """
            {"workspace_id": "\(id)", "number": 1, "label": "\(id)",
             "focused": \(focused), "agent_status": "idle"}
            """
        }.joined(separator: ",")
        let json = """
            {
              "boot_id": "boot-\(id)",
              "revision": 1,
              "workspaces": [\(rows)],
              "tabs": [], "panes": [], "agents": []
            }
            """
        return EndpointInfo(
            index: index, id: id, label: label, status: .online, isRemote: false,
            error: nil, needsInstall: false,
            snapshot: try! JSONDecoder().decode(Snapshot.self, from: Data(json.utf8)))
    }

    func testAMachineIsNotSomewhereAnArrowCanLand() {
        var moved: [String] = []
        let view = sidebar([
            endpoint(0, "local", "Local", workspaces: [("alpha", true), ("beta", false)])
        ])
        view.onSelectWorkspace = { id, _ in moved.append(id) }
        view.onSelectEndpoint = { _ in moved.append("MACHINE") }

        XCTAssertTrue(view.step(by: 1))
        XCTAssertTrue(view.step(by: -1))

        XCTAssertEqual(
            moved, ["beta", "alpha"],
            "an arrow moves between places to work; a machine is the heading over them")
    }

    func testASecondPressMovesOnWithoutWaitingForTheServer() {
        var moved: [String] = []
        let view = sidebar([
            endpoint(
                0, "local", "Local",
                workspaces: [("alpha", true), ("beta", false), ("gamma", false)])
        ])
        view.onSelectWorkspace = { id, _ in moved.append(id) }

        // Nothing rebuilds in between, because nothing has come back yet: the
        // rows still say alpha is the selected one.
        XCTAssertTrue(view.step(by: 1))
        XCTAssertTrue(view.step(by: 1))

        XCTAssertEqual(
            moved, ["beta", "gamma"],
            "reading the selection off the rows alone made the second press repeat the first")
    }

    func testTheServerCatchingUpHandsTheSelectionBack() {
        var moved: [String] = []
        let view = sidebar([
            endpoint(0, "local", "Local", workspaces: [("alpha", true), ("beta", false)])
        ])
        view.onSelectWorkspace = { id, _ in moved.append(id) }
        XCTAssertTrue(view.step(by: 1))

        // The snapshot arrives agreeing that beta is now focused.
        view.update(
            endpoints: [
                endpoint(0, "local", "Local", workspaces: [("alpha", false), ("beta", true)])
            ], active: 0)

        XCTAssertTrue(view.step(by: -1))
        XCTAssertEqual(
            moved, ["beta", "alpha"],
            "a stale intent would have started this press from beta's old position")
    }

    func testSteppingPastTheLastRowDoesNothingAtAll() {
        var moved: [String] = []
        let view = sidebar([
            endpoint(0, "local", "Local", workspaces: [("alpha", false), ("beta", true)])
        ])
        view.onSelectWorkspace = { id, _ in moved.append(id) }

        XCTAssertFalse(
            view.step(by: 1),
            "beta is the last row, so down is not a move and must not report one")
        XCTAssertTrue(moved.isEmpty)
    }

    func testTheArrowsCrossFromOneMachineToTheNext() {
        var moved: [(String, Int)] = []
        let view = sidebar([
            endpoint(0, "local", "Local", workspaces: [("alpha", true)]),
            endpoint(1, "remote", "Remote", workspaces: [("gamma", false)]),
        ])
        view.onSelectWorkspace = { id, endpoint in moved.append((id, endpoint)) }

        XCTAssertTrue(view.step(by: 1))

        XCTAssertEqual(moved.map(\.0), ["gamma"])
        XCTAssertEqual(
            moved.map(\.1), [1],
            "the row carries its machine, and going there has to switch to it first")
    }
}
