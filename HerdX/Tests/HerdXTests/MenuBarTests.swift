import AppKit
import XCTest

@testable import HerdX

/// Checks the menu bar that is actually built, rather than the table half of it
/// comes from.
///
/// A table can be right while the bar is wrong: the standard items — Hide,
/// Services, Minimize — are not in any table, and a keystroke one of them
/// claims takes the item claiming it too away from whoever reaches for it. The
/// only place the two halves meet is the `NSMenu` itself.
@MainActor
final class MenuBarTests: XCTestCase {
    private func menuBar() -> NSMenu {
        AppDelegate().makeMainMenu()
    }

    /// Every item in the bar, submenus included, paired with the menu it is in.
    private func items(of menu: NSMenu) -> [(menu: String, item: NSMenuItem)] {
        menu.items.flatMap { item -> [(String, NSMenuItem)] in
            guard let submenu = item.submenu else { return [(menu.title, item)] }
            return [(menu.title, item)] + items(of: submenu)
        }
    }

    func testTheBarCarriesTheMenusAMacUserLooksFor() {
        let titles = menuBar().items.compactMap { $0.submenu?.title }
        XCTAssertEqual(titles, ["HerdX", "Shell", "Edit", "View", "Session", "Window", "Help"])
    }

    /// The items whose absence the user notices: they are muscle memory, and
    /// nothing else in the app offers them.
    func testTheStandardItemsAreAllThere() {
        let titles = Set(items(of: menuBar()).map(\.item.title))
        for expected in [
            "About HerdX", "Settings…", "Services", "Hide HerdX", "Hide Others", "Show All",
            "Quit HerdX", "Undo", "Cut", "Copy", "Paste", "Select All", "Minimize", "Zoom",
            "Enter Full Screen", "Bring All to Front",
        ] {
            XCTAssertTrue(titles.contains(expected), "the menu bar has no \"\(expected)\"")
        }
    }

    func testNoTwoItemsInTheBarClaimTheSameKeystroke() {
        var seen: [String: String] = [:]
        for (menu, item) in items(of: menuBar()) where !item.keyEquivalent.isEmpty {
            let chord = "\(item.keyEquivalent)-\(item.keyEquivalentModifierMask.rawValue)"
            let owner = "\(menu) ▸ \(item.title)"
            XCTAssertNil(
                seen[chord],
                "\(owner) and \(seen[chord] ?? "") share a keystroke; AppKit gives it to "
                    + "whichever it finds first and the other becomes unreachable")
            seen[chord] = owner
        }
    }

    /// The standard items are AppKit's, and reach it by having no target at all.
    /// Given one, `hide:` would be sent to this app delegate, which does not
    /// implement it, and the item would be dead.
    func testTheStandardItemsAreAimedAtTheResponderChain() {
        let standard = ["About HerdX", "Hide HerdX", "Hide Others", "Show All", "Quit HerdX",
                        "Minimize", "Zoom", "Enter Full Screen", "Bring All to Front",
                        "Copy", "Paste", "Select All"]
        for (_, item) in items(of: menuBar()) where standard.contains(item.title) {
            XCTAssertNil(item.target, "\"\(item.title)\" is aimed at the delegate")
            XCTAssertNotNil(item.action, "\"\(item.title)\" does nothing")
        }
    }

    /// Three menus belong to the system rather than to us, and it only knows
    /// which is which by being told.
    func testAppKitIsToldWhichMenusAreItsOwn() {
        let bar = menuBar()
        let byTitle = Dictionary(
            uniqueKeysWithValues: bar.items.compactMap { item -> (String, NSMenu)? in
                item.submenu.map { ($0.title, $0) }
            })
        XCTAssertTrue(NSApp.windowsMenu === byTitle["Window"], "the window list has no home")
        XCTAssertTrue(NSApp.helpMenu === byTitle["Help"])
        let services = items(of: bar).first { $0.item.title == "Services" }?.item.submenu
        XCTAssertTrue(NSApp.servicesMenu === services, "Services would stay empty")
    }

    /// Each command item carries its command as a tag and nothing else; a tag
    /// that is not in `allByTag` clicks and does nothing.
    func testEveryCommandItemInTheBarResolvesBackToACommand() {
        let action = NSSelectorFromString("menuCommand:")
        var found = 0
        for (menu, item) in items(of: menuBar()) where item.action == action {
            XCTAssertNotNil(
                Command.allByTag[item.tag],
                "\(menu) ▸ \(item.title) carries tag \(item.tag), which is not in allByTag")
            found += 1
        }
        XCTAssertEqual(found, Command.menuLayout.count, "the bar and the table disagree")
    }
}
