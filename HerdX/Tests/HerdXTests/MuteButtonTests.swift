import AppKit
import XCTest

@testable import HerdX

/// The speaker at the foot of the sidebar is a shortcut to one preference, so
/// what matters is that it says what the preference says, asks rather than
/// acts, and is actually in the corner — "where is it?" being the question
/// that has found every misplaced view in this app so far.
@MainActor
final class MuteButtonTests: XCTestCase {
    private func sidebar() -> SidebarView {
        SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
    }

    private func endpoint(workspaces count: Int) -> EndpointInfo {
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

    // MARK: - What it says

    func testItStartsSayingSoundsAreOn() {
        let view = sidebar()
        XCTAssertFalse(view.mute.isMuted)
        XCTAssertEqual(view.mute.toolTip, "Mute agent sounds")
        XCTAssertEqual(view.mute.image?.accessibilityDescription, "Mute agent sounds")
    }

    func testItSaysWhatThePreferenceSays() {
        let view = sidebar()
        view.show(muted: true)
        XCTAssertTrue(view.mute.isMuted)
        XCTAssertEqual(view.mute.toolTip, "Unmute agent sounds")
        XCTAssertEqual(view.mute.image?.accessibilityDescription, "Unmute agent sounds")

        view.show(muted: false)
        XCTAssertEqual(view.mute.toolTip, "Mute agent sounds")
    }

    // MARK: - What a click does

    func testAClickAsksRatherThanActs() {
        let view = sidebar()
        var asked = 0
        view.onToggleMute = { asked += 1 }

        view.mute.performClick(nil)

        XCTAssertEqual(asked, 1)
        // The preference is the app's to flip; the button waits to be told
        // what it became, so there is only ever one copy of the answer.
        XCTAssertFalse(view.mute.isMuted)
    }

    // MARK: - Where it is

    func testItSitsInTheBottomLeftCornerBelowTheRows() {
        let view = sidebar()
        view.update(endpoints: [endpoint(workspaces: 3)], active: 0)
        view.layoutSubtreeIfNeeded()

        // The sidebar is not flipped, so y grows upwards and the corner is
        // where both coordinates are small.
        let frame = view.mute.frame
        XCTAssertEqual(frame.minX, 8, "in line with the machine rows and the switch above")
        XCTAssertEqual(frame.minY, 6)
        XCTAssertEqual(frame.size, NSSize(width: 22, height: 22), "small: a glyph, not a toolbar")

        // The rows stop above it rather than scrolling underneath, so no row's
        // name runs through the glyph and no row's click lands under it.
        let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first
        XCTAssertNotNil(scroll)
        XCTAssertGreaterThanOrEqual(scroll?.frame.minY ?? 0, frame.maxY)
        XCTAssertFalse(view.mute.isHidden)
    }

    func testItKeepsItsCornerWhenTheListOverflows() {
        let view = sidebar()
        view.update(endpoints: [endpoint(workspaces: 40)], active: 0)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.mute.frame.minY, 6, "forty rows do not push it off the bottom")
    }
}
