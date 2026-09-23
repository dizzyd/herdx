import AppKit
import XCTest

@testable import HerdX

/// A sidebar taller than its window used to put real rows out of reach: they
/// were laid out past the bottom edge with nothing to scroll them into view.
@MainActor
final class SidebarOverflowTests: XCTestCase {
    private func manyWorkspaces(_ count: Int) -> EndpointInfo {
        let rows = (0..<count).map { index in
            """
            {"workspace_id": "w\(index)", "number": \(index), "label": "space \(index)",
             "focused": \(index == 0), "agent_status": "idle"}
            """
        }.joined(separator: ",")
        let json = """
            {
              "boot_id": "boot",
              "revision": 1,
              "workspaces": [\(rows)],
              "tabs": [], "panes": [], "agents": []
            }
            """
        return EndpointInfo(
            index: 0, id: "local", label: "Local", status: .online, isRemote: false,
            error: nil, needsInstall: false,
            snapshot: try! JSONDecoder().decode(Snapshot.self, from: Data(json.utf8)))
    }

    /// Laid out for real, at a height that cannot hold forty rows.
    private func sidebar(workspaces: Int) -> SidebarView {
        let view = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        view.update(endpoints: [manyWorkspaces(workspaces)], active: 0)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func rows(of view: SidebarView) -> [SidebarRow] {
        var found: [SidebarRow] = []
        func walk(_ v: NSView) {
            if let row = v as? SidebarRow { found.append(row) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    func testTheLastOfManyRowsCanBeScrolledTo() throws {
        let view = sidebar(workspaces: 40)
        let last = try XCTUnwrap(rows(of: view).last)

        XCTAssertNotNil(
            last.enclosingScrollView, "the rows sit in nothing that can scroll")

        last.scrollToVisible(last.bounds)
        view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(last.enclosingScrollView)
        let visible = scroll.contentView.convert(scroll.contentView.bounds, to: last)
        XCTAssertTrue(
            visible.intersects(last.bounds),
            "the last row is still off screen after being scrolled to")
    }

    /// The arrow keys move the selection, so they have to move the view with
    /// it — a row selected below the fold reads as the key doing nothing.
    func testSteppingDownBringsTheRowIntoView() throws {
        let view = sidebar(workspaces: 40)
        var landed: String?
        view.onSelectWorkspace = { id, _ in landed = id }

        for _ in 0..<39 { _ = view.step(by: 1) }
        view.layoutSubtreeIfNeeded()

        let last = try XCTUnwrap(rows(of: view).last)
        XCTAssertEqual(landed, "w39", "the fixture did not reach the end of the list")
        let scroll = try XCTUnwrap(last.enclosingScrollView)
        let visible = scroll.contentView.convert(scroll.contentView.bounds, to: last)
        XCTAssertTrue(
            visible.intersects(last.bounds),
            "the selection moved off the bottom and the sidebar stayed where it was")
    }

    /// Few enough rows to fit: they belong at the top, not floated to the
    /// bottom edge the way an unflipped document view would leave them.
    func testAShortListStaysAtTheTop() throws {
        let view = sidebar(workspaces: 2)
        let first = try XCTUnwrap(rows(of: view).first)
        let scroll = try XCTUnwrap(first.enclosingScrollView)
        let top = first.convert(first.bounds, to: scroll.contentView).minY
        XCTAssertLessThan(top, 60, "the rows were pushed to the bottom of the sidebar")
    }
}
