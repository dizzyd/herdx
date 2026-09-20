import AppKit
import XCTest

@testable import HerdX

/// The Shell menu is a table, and the two ways it has gone wrong are both the
/// kind a reader cannot see: an item whose command is not in `allByTag`, which
/// clicks and does nothing, and two items claiming one key equivalent, which
/// AppKit hands to whichever it finds first.
final class CommandMenuTests: XCTestCase {
    func testEveryMenuItemResolvesBackToItsCommand() {
        for (title, _, command) in Command.menuLayout where !title.isEmpty {
            XCTAssertEqual(
                Command.allByTag[command.tag]?.tag, command.tag,
                "\"\(title)\" is in the menu but not in allByTag, so clicking it does nothing")
        }
    }

    func testNoTwoMenuItemsClaimTheSameKeyEquivalent() {
        var seen: [String: String] = [:]
        for (title, key, _) in Command.menuLayout
        where !title.isEmpty && !key.equivalent.isEmpty {
            let chord = "\(key.equivalent)-\(key.modifiers.rawValue)"
            XCTAssertNil(
                seen[chord],
                "\"\(title)\" and \"\(seen[chord] ?? "")\" share a key equivalent; AppKit gives "
                    + "it to whichever it finds first and the other becomes unreachable")
            seen[chord] = title
        }
    }

    func testTheLocalWorkspaceItemIsInTheMenuWithoutAKeyEquivalent() {
        let item = Command.menuLayout.first { $0.0 == "New Local Workspace" }
        XCTAssertNotNil(item, "the menu lost the item")
        // Its keystroke is a prefix chord, which a Mac menu cannot spell, and
        // ⇧⌘N is already New Workspace.
        XCTAssertEqual(item?.1.equivalent, "")
    }

    func testTheHelpMenuColumnListsOnlyThingsYouCanType() {
        // The column is a keyboard reference, so a blank key cell would read as
        // a shortcut nobody can find.
        let rows = Command.menuLayout.filter { !$0.0.isEmpty && !$0.1.equivalent.isEmpty }
        XCTAssertFalse(rows.contains { $0.0 == "New Local Workspace" })
        XCTAssertTrue(rows.contains { $0.0 == "New Workspace" })
    }

    func testTheLocalWorkspaceCommandNeverGoesOutOnTheWire() {
        // It is workspace.create aimed at a named machine; `invoke` resolves it
        // before a request is built, and a method here would be a second answer
        // to the same question.
        XCTAssertEqual(Command.newLocalWorkspace.method, "")
    }
}
