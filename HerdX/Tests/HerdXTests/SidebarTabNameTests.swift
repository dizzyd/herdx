import AppKit
import XCTest

@testable import HerdX

/// A workspace row says which tab you would land in, when that tab has been
/// given a name.
@MainActor
final class SidebarTabNameTests: XCTestCase {
    /// A workspace holding some agents, for the rows that tell them apart.
    private func agentSnapshot(
        panes: [(id: String, label: String?, kind: String?)],
        tabLabel: String = "1",
        tabs: [(id: String, number: Int, label: String)]? = nil,
        paneTabs: [String]? = nil
    ) -> Snapshot {
        let tabList = tabs ?? [(id: "w1:t1", number: 1, label: tabLabel)]
        let tabOf = { (index: Int) in paneTabs?[index] ?? tabList[0].id }
        let paneJSON = panes.enumerated().map { index, pane in
            let label = pane.label.map { "\"\($0)\"" } ?? "null"
            return """
                {"pane_id": "\(pane.id)", "tab_id": "\(tabOf(index))", "label": \(label),
                 "focused": false}
                """
        }.joined(separator: ",")
        let agentJSON = panes.enumerated().map { index, pane in
            let kind = pane.kind.map { "\"\($0)\"" } ?? "null"
            return """
                {"pane_id": "\(pane.id)", "workspace_id": "w1", "tab_id": "\(tabOf(index))",
                 "agent": \(kind), "agent_status": "idle",
                 "state_change_seq": 1, "focused": false}
                """
        }.joined(separator: ",")
        let tabJSON = tabList.map { tab in
            """
            {"tab_id": "\(tab.id)", "workspace_id": "w1", "number": \(tab.number),
             "label": "\(tab.label)", "zoomed": false, "focused": false,
             "agent_status": "idle"}
            """
        }.joined(separator: ",")
        let json = """
            {"boot_id": "b", "revision": 1,
             "workspaces": [{"workspace_id": "w1", "number": 1, "label": "herdx",
                             "focused": false, "agent_status": "idle",
                             "active_tab_id": "w1:t1"}],
             "tabs": [\(tabJSON)], "panes": [\(paneJSON)], "agents": [\(agentJSON)]}
            """
        return try! JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    private func places(_ snapshot: Snapshot) -> [String] {
        snapshot.agents.map { SidebarView.namedPlace(of: $0, in: snapshot) }
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

    func testALoneAgentSaysNothingExtra() {
        // Its workspace has already said everything there is to say about
        // where it is, even when its pane carries a name.
        let alone = agentSnapshot(panes: [(id: "w1:p1", label: "agent", kind: "claude")])

        XCTAssertEqual(places(alone), [""])
    }

    func testTwoAgentsAreToldApartByTheirPanes() {
        let pair = agentSnapshot(panes: [
            (id: "w1:p1", label: "agent", kind: "claude"),
            (id: "w1:p2", label: "tests", kind: "claude"),
        ])

        XCTAssertEqual(places(pair), [" (agent)", " (tests)"])
    }

    func testAnUnnamedPaneIsCalledByWhatIsRunningInIt() {
        // From `agent`, not `display_agent`: a live server omits the latter
        // for an agent it merely detected, which is nearly all of them.
        let pair = agentSnapshot(panes: [
            (id: "w1:p1", label: nil, kind: "claude"),
            (id: "w1:p3", label: nil, kind: "codex"),
        ])

        XCTAssertEqual(places(pair), [" (claude 1)", " (codex 3)"])
    }

    func testANamedTabIsUsedWhenTheAgentsAreInDifferentTabs() {
        // Exactly the shape on Monolith: one pane named, the other in a tab
        // that was renamed instead.
        let pair = agentSnapshot(
            panes: [
                (id: "w1:p1", label: "Overall", kind: "claude"),
                (id: "w1:p2", label: nil, kind: "claude"),
            ],
            tabs: [(id: "w1:t1", number: 1, label: "1"),
                   (id: "w1:t2", number: 2, label: "vs-bestpack")],
            paneTabs: ["w1:t1", "w1:t2"])

        XCTAssertEqual(places(pair), [" (Overall)", " (vs-bestpack)"])
    }

    func testATabSharedByBothAgentsCannotTellThemApart() {
        // Two split panes sit in one tab, so its name reads the same on both
        // rows and answers nothing — the number has to do the work.
        let pair = agentSnapshot(
            panes: [
                (id: "w1:p1", label: nil, kind: "claude"),
                (id: "w1:p2", label: nil, kind: "claude"),
            ],
            tabLabel: "work")

        XCTAssertEqual(places(pair), [" (claude 1)", " (claude 2)"])
    }

    func testAnUnknownAgentLeavesJustTheNumber() {
        let pair = agentSnapshot(panes: [
            (id: "w1:p1", label: nil, kind: nil),
            (id: "w1:p2", label: nil, kind: nil),
        ])

        XCTAssertEqual(places(pair), [" (1)", " (2)"])
    }

    func testANamedPaneAndAnUnnamedOneCanSitTogether() {
        let pair = agentSnapshot(panes: [
            (id: "w1:p1", label: "agent", kind: "claude"),
            (id: "w1:p2", label: nil, kind: "claude"),
        ])

        XCTAssertEqual(places(pair), [" (agent)", " (claude 2)"])
    }

    func testThePaneNumberIsTheOneHerdrCallsItBy() {
        // Its id rather than its position, so it keeps meaning the same pane
        // after one beside it is closed.
        XCTAssertEqual(SidebarView.paneNumber(of: "w1:p2"), "2")
        XCTAssertEqual(SidebarView.paneNumber(of: "wA:p12"), "12")
        XCTAssertEqual(SidebarView.paneNumber(of: "nonsense"), "nonsense")
    }

    func testRenamingATabRebuildsTheAgentsList() {
        // The reported case: the agents list is what was on screen, and its
        // signature is built separately from the machine list's.
        let view = SidebarView(frame: .zero)
        view.arrangement = .priority
        let endpoint = { (s: Snapshot) in
            EndpointInfo(
                index: 0, id: "local", label: "Local", status: .online, isRemote: false,
                error: nil, needsInstall: false, snapshot: s)
        }
        let panes: [(id: String, label: String?, kind: String?)] = [
            (id: "w1:p1", label: "Overall", kind: "claude"),
            (id: "w1:p2", label: nil, kind: "claude"),
        ]
        let before = agentSnapshot(
            panes: panes,
            tabs: [(id: "w1:t1", number: 1, label: "1"), (id: "w1:t2", number: 2, label: "2")],
            paneTabs: ["w1:t1", "w1:t2"])
        view.update(endpoints: [endpoint(before)], active: 0)
        let rebuilds = view.rebuilds

        let after = agentSnapshot(
            panes: panes,
            tabs: [(id: "w1:t1", number: 1, label: "1"),
                   (id: "w1:t2", number: 2, label: "vs-bestpack")],
            paneTabs: ["w1:t1", "w1:t2"])
        view.update(endpoints: [endpoint(after)], active: 0)

        XCTAssertEqual(
            view.rebuilds, rebuilds + 1,
            "renaming a tab changes what an agent row reads and nothing else here")
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
