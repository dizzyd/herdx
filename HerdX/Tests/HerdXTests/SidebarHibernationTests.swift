import AppKit
import XCTest

@testable import HerdX

/// Hibernated rows come from the store, not from a snapshot — which is exactly
/// how a sidebar row goes missing in this app. The list compares a signature
/// and returns early, so a record that appears while nothing else changes has
/// to be part of that signature or it is never drawn.
@MainActor
final class SidebarHibernationTests: XCTestCase {
    private func sidebar() -> SidebarView {
        let view = SidebarView(frame: .zero)
        view.arrangement = .priority
        return view
    }

    private func endpoint(id: String = "local") -> EndpointInfo {
        EndpointInfo(
            index: 0, id: id, label: "Local", status: .online, isRemote: false,
            error: nil, needsInstall: false, snapshot: snapshot())
    }

    private func snapshot() -> Snapshot {
        try! JSONDecoder().decode(
            Snapshot.self,
            from: Data(
                """
                {"boot_id": "boot", "revision": 1, "workspaces": [], "tabs": [],
                 "panes": [], "agents": []}
                """.utf8))
    }

    private func record(label: String = "augur", endpointID: String = "local") -> Hibernated {
        Hibernated(
            id: UUID(), endpointID: endpointID, number: 2, label: label,
            cwd: "/src/augur", branch: nil, at: Date(),
            tabs: [
                Hibernated.Tab(
                    label: "1", zoomed: false,
                    root: .pane(.init(paneID: "w2:p1", cwd: "/src/augur")),
                    focused: [],
                    agents: [
                        Hibernated.Agent(
                            path: [], source: "herdr:claude", agent: "claude",
                            kind: "id", value: "conv")
                    ])
            ])
    }

    func testARecordAppearingRebuildsTheListOnItsOwn() {
        let view = sidebar()
        view.update(endpoints: [endpoint()], active: 0, hibernated: [])
        let before = view.rebuilds

        view.update(endpoints: [endpoint()], active: 0, hibernated: [record()])

        XCTAssertEqual(
            view.rebuilds, before + 1,
            "nothing else in the signature moves when a workspace is hibernated, so the row "
                + "would not appear until something unrelated changed")
    }

    func testRevivingARecordRebuildsTheListToo() {
        let view = sidebar()
        view.update(endpoints: [endpoint()], active: 0, hibernated: [record()])
        let before = view.rebuilds

        view.update(endpoints: [endpoint()], active: 0, hibernated: [])

        XCTAssertEqual(view.rebuilds, before + 1, "the row has to go away again as well")
    }

    func testAnUnchangedListIsNotRebuilt() {
        let view = sidebar()
        let held = record()
        view.update(endpoints: [endpoint()], active: 0, hibernated: [held])
        let before = view.rebuilds

        view.update(endpoints: [endpoint()], active: 0, hibernated: [held])

        XCTAssertEqual(
            view.rebuilds, before,
            "rebuilding on every tick throws away the row under the cursor mid-gesture")
    }

    func testHibernatedRowsAreDrawnUnderTheirOwnHeading() {
        let view = sidebar()
        view.update(endpoints: [endpoint()], active: 0, hibernated: [record()])

        let headings = view.builtRows.compactMap { $0 as? SidebarSection }.map(\.title)
        XCTAssertEqual(headings, ["Hibernated"])
    }

    func testARecordForAMachineThatIsNotHereIsNotDrawn() {
        let view = sidebar()
        view.update(
            endpoints: [endpoint(id: "local")], active: 0,
            hibernated: [record(endpointID: "rainbow")])

        // Clicking it could not revive it, and a row that does nothing is worse
        // than one that is missing. The list still says "No agents", which is
        // a row — so the assertion is about hibernated rows, not about rows.
        let dormantRows = view.builtRows.compactMap { $0 as? SidebarRow }.filter {
            if case .hibernated = $0.target { return true }
            return false
        }
        XCTAssertTrue(dormantRows.isEmpty)
    }

    func testTheRowSaysWhatIsComingBack() {
        let view = sidebar()
        view.update(endpoints: [endpoint()], active: 0, hibernated: [record(label: "augur")])

        let rows = view.builtRows.compactMap { $0 as? SidebarRow }
        XCTAssertEqual(rows.count, 1)
        guard case .hibernated = rows[0].target else {
            return XCTFail("clicking the row has to be what revives it")
        }
    }
}
