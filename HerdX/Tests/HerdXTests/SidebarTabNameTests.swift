import AppKit
import XCTest

@testable import HerdX

/// A workspace row says which tab you would land in, when that tab has been
/// given a name.
@MainActor
final class SidebarTabNameTests: XCTestCase {
    /// An agent in a pane, for the rows that name one.
    private func agentSnapshot(paneLabel: String?, tabLabel: String) -> Snapshot {
        let label = paneLabel.map { "\"\($0)\"" } ?? "null"
        let json = """
            {"boot_id": "b", "revision": 1,
             "workspaces": [{"workspace_id": "w1", "number": 1, "label": "herdx",
                             "focused": false, "agent_status": "idle",
                             "active_tab_id": "w1:t1"}],
             "tabs": [{"tab_id": "w1:t1", "workspace_id": "w1", "number": 1,
                       "label": "\(tabLabel)", "zoomed": false, "focused": false,
                       "agent_status": "idle"}],
             "panes": [{"pane_id": "w1:p1", "tab_id": "w1:t1", "label": \(label),
                        "focused": false}],
             "agents": [{"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                         "agent_status": "idle", "state_change_seq": 1, "focused": false}]}
            """
        return try! JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    private func snapshot(
        workspace: String = "crucibulum", activeTab: String? = "w1:t1",
        tabs: [(id: String, number: Int, label: String)] = [(id: "w1:t1", number: 1, label: "1")]
    ) -> Snapshot {
        let active = activeTab.map { "\"\($0)\"" } ?? "null"
        let tabJSON = tabs.map { tab in
            """
            {"tab_id": "\(tab.id)", "workspace_id": "w1", "number": \(tab.number),
             "label": "\(tab.label)", "zoomed": false, "focused": false,
             "agent_status": "idle"}
            """
        }.joined(separator: ",")
        let json = """
            {"boot_id": "b", "revision": 1,
             "workspaces": [{"workspace_id": "w1", "number": 1, "label": "\(workspace)",
                             "focused": false, "agent_status": "idle",
                             "active_tab_id": \(active)}],
             "tabs": [\(tabJSON)], "panes": [], "agents": []}
            """
        return try! JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    private func suffix(_ snapshot: Snapshot) -> String {
        SidebarView.namedTab(of: snapshot.workspaces[0], in: snapshot)
    }

    func testANamedTabIsShown() {
        let named = snapshot(
            workspace: "herdx", activeTab: "w1:t1",
            tabs: [(id: "w1:t1", number: 1, label: "claude")])

        XCTAssertEqual(suffix(named), " (claude)")
    }

    func testATabStillCalledByItsNumberIsNot() {
        // herdr names a tab after its number until somebody renames it, and
        // "crucibulum (1)" says nothing that "crucibulum" did not.
        XCTAssertEqual(suffix(snapshot()), "")
    }

    func testTheActiveTabIsTheOneNamed() {
        // A tab's own `focused` is about the session, so it cannot answer this
        // for a workspace you are not in — hence active_tab_id.
        let several = snapshot(
            activeTab: "w1:t2",
            tabs: [
                (id: "w1:t1", number: 1, label: "notes"),
                (id: "w1:t2", number: 2, label: "build"),
            ])

        XCTAssertEqual(suffix(several), " (build)")
    }

    func testAWorkspaceWithNoActiveTabSaysNothingExtra() {
        XCTAssertEqual(suffix(snapshot(activeTab: nil)), "")
    }

    func testAnActiveTabThatIsNotInTheSnapshotSaysNothingExtra() {
        XCTAssertEqual(suffix(snapshot(activeTab: "w1:t9")), "")
    }

    // MARK: - The other two lists that name the same workspace

    func testAnAgentRowNamesTheTabTheAgentIsIn() {
        // Not the workspace's active tab: the point of listing agents apart is
        // that they are somewhere you are not.
        let several = snapshot(
            activeTab: "w1:t1",
            tabs: [
                (id: "w1:t1", number: 1, label: "notes"),
                (id: "w1:t2", number: 2, label: "build"),
            ])

        XCTAssertEqual(SidebarView.namedTab(tabID: "w1:t2", in: several), " (build)")
        XCTAssertEqual(SidebarView.namedTab(of: several.workspaces[0], in: several), " (notes)")
    }

    func testANamedPaneWinsOverItsTab() {
        // An agent row is one agent in one pane, so the pane is the most
        // specific thing true of it — and a pane is named only deliberately,
        // where a tab carries its number until somebody renames it.
        let snapshot = agentSnapshot(paneLabel: "agent", tabLabel: "claude")

        XCTAssertEqual(
            SidebarView.namedPlace(of: snapshot.agents[0], in: snapshot), " (agent)")
    }

    func testTheTabIsUsedWhenThePaneHasNoName() {
        let snapshot = agentSnapshot(paneLabel: nil, tabLabel: "claude")

        XCTAssertEqual(
            SidebarView.namedPlace(of: snapshot.agents[0], in: snapshot), " (claude)")
    }

    func testNeitherNamedSaysNothingExtra() {
        // A tab still called by its number is not a name, and this is the
        // ordinary case — nothing in brackets at all.
        let snapshot = agentSnapshot(paneLabel: nil, tabLabel: "1")

        XCTAssertEqual(SidebarView.namedPlace(of: snapshot.agents[0], in: snapshot), "")
    }

    func testAnEmptyPaneLabelIsNotAName() {
        let snapshot = agentSnapshot(paneLabel: "", tabLabel: "claude")

        XCTAssertEqual(
            SidebarView.namedPlace(of: snapshot.agents[0], in: snapshot), " (claude)")
    }

    func testAStoredTabNameSurvivesHibernation() {
        // A hibernated row has only the label it kept; the number it would
        // otherwise be called by is not stored, so digits are taken as default.
        XCTAssertEqual(SidebarView.namedTab(stored: "claude"), " (claude)")
        XCTAssertEqual(SidebarView.namedTab(stored: "2"), "")
        XCTAssertEqual(SidebarView.namedTab(stored: nil), "")
        XCTAssertEqual(SidebarView.namedTab(stored: ""), "")
    }

    func testRenamingATabRebuildsTheList() {
        // The row's text changes and nothing else about the workspace does, so
        // the name has to be part of what the list compares.
        let view = SidebarView(frame: .zero)
        let before = snapshot(
            workspace: "herdx", tabs: [(id: "w1:t1", number: 1, label: "1")])
        let endpoint = { (s: Snapshot) in
            EndpointInfo(
                index: 0, id: "local", label: "Local", status: .online, isRemote: false,
                error: nil, needsInstall: false, snapshot: s)
        }
        view.update(endpoints: [endpoint(before)], active: 0)
        let rebuilds = view.rebuilds

        let after = snapshot(
            workspace: "herdx", tabs: [(id: "w1:t1", number: 1, label: "claude")])
        view.update(endpoints: [endpoint(after)], active: 0)

        XCTAssertEqual(view.rebuilds, rebuilds + 1)
    }
}
