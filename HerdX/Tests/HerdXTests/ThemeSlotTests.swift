import AppKit
import XCTest

@testable import HerdX

/// A theme for light and one for dark, and which of them the terminal uses.
///
/// Saving and loading go through a defaults suite of their own, so the real
/// settings are never read or written.
final class ThemeSlotTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "dev.herdr.herdx.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// A palette unlike either built-in one, told apart by its background.
    private func palette(_ background: String, from base: Theme) -> [String] {
        var theme = base
        theme.background = Theme.hex(background)!
        return theme.hexComponents
    }

    private lazy var paper = Preferences.ThemeChoice(
        name: "Paper", colors: palette("#f0e8d8", from: .light))
    private lazy var ink = Preferences.ThemeChoice(
        name: "Ink", colors: palette("#101828", from: .dark))

    private func background(of theme: Theme) -> String? {
        Preferences.encode(theme.background)
    }

    func testFollowingTheSystemUsesTheSlotForWhatTheSystemIs() {
        var preferences = Preferences.load(from: defaults)
        preferences.appearance = .system
        XCTAssertEqual(preferences.slot(matching: true), .dark)
        XCTAssertEqual(preferences.slot(matching: false), .light)
    }

    func testAPinnedAppearanceIgnoresTheSystem() {
        var preferences = Preferences.load(from: defaults)
        preferences.appearance = .dark
        XCTAssertEqual(preferences.slot(matching: false), .dark)
        preferences.appearance = .light
        XCTAssertEqual(preferences.slot(matching: true), .light)
    }

    func testEachAppearanceDrawsWithItsOwnSlot() {
        var preferences = Preferences.load(from: defaults)
        preferences.appearance = .system
        preferences.lightTheme = paper
        preferences.darkTheme = ink
        XCTAssertEqual(background(of: preferences.terminalTheme(matching: false)), "#f0e8d8")
        XCTAssertEqual(background(of: preferences.terminalTheme(matching: true)), "#101828")
    }

    func testAnEmptySlotIsTheBuiltInForThatAppearance() {
        var preferences = Preferences.load(from: defaults)
        preferences.appearance = .system
        preferences.lightTheme = paper
        XCTAssertEqual(
            preferences.terminalTheme(matching: true).hexComponents,
            Theme.dark.hexComponents,
            "the dark slot is empty, so dark should be the built-in dark")
    }

    func testAnUnreadableChoiceFallsBackToTheBuiltIn() {
        var preferences = Preferences.load(from: defaults)
        preferences.appearance = .light
        preferences.lightTheme = Preferences.ThemeChoice(name: "Broken", colors: ["#000000"])
        XCTAssertEqual(
            preferences.terminalTheme(matching: true).hexComponents,
            Theme.light.hexComponents)
    }

    func testBothSlotsSurviveASave() {
        var preferences = Preferences.load(from: defaults)
        preferences.lightTheme = paper
        preferences.darkTheme = ink
        preferences.save(to: defaults)

        let loaded = Preferences.load(from: defaults)
        XCTAssertEqual(loaded.lightTheme, paper)
        XCTAssertEqual(loaded.darkTheme, ink)
    }

    // MARK: - Settings from before there were two themes

    func testALoadedThemeIsKeptInBoth() {
        defaults.set("Paper", forKey: "themeName")
        defaults.set(paper.colors, forKey: "themeColors")

        let migrated = Preferences.load(from: defaults)
        XCTAssertEqual(migrated.lightTheme, paper)
        XCTAssertEqual(migrated.darkTheme, paper)
    }

    func testOverridesOnALoadedThemeAreKept() {
        defaults.set("Paper", forKey: "themeName")
        defaults.set(paper.colors, forKey: "themeColors")
        defaults.set("#202020", forKey: "terminalBackground")

        let migrated = Preferences.load(from: defaults)
        XCTAssertEqual(migrated.lightTheme?.name, "Paper (adjusted)")
        XCTAssertEqual(migrated.lightTheme?.colors.first, "#202020")
        XCTAssertEqual(migrated.darkTheme, migrated.lightTheme)
    }

    func testAPinnedTerminalWithItsOwnColoursIsKept() {
        // The window light, the terminal pinned dark and given exact colours:
        // what the old settings drew was none of the built-in palettes.
        defaults.set("light", forKey: "appearance")
        defaults.set("dark", forKey: "terminalAppearance")
        defaults.set("#101010", forKey: "terminalBackground")
        defaults.set("#eeeeee", forKey: "terminalForeground")

        let migrated = Preferences.load(from: defaults)
        let drawn = migrated.terminalTheme(matching: false)
        XCTAssertEqual(background(of: drawn), "#101010")
        XCTAssertEqual(Preferences.encode(drawn.foreground), "#eeeeee")
        XCTAssertEqual(Theme(hexComponents: migrated.lightTheme!.colors)?.ansi.first,
            Theme.dark.ansi.first, "the terminal was pinned dark, so its palette was dark")
    }

    func testAPinnedTerminalFillsTheSlotsItWasShownIn() {
        // Following the system, with the terminal pinned dark: dark was on
        // screen in both appearances.
        defaults.set("system", forKey: "appearance")
        defaults.set("dark", forKey: "terminalAppearance")

        let migrated = Preferences.load(from: defaults)
        XCTAssertEqual(migrated.lightTheme?.colors, Theme.dark.hexComponents)
        XCTAssertNil(migrated.darkTheme, "the built-in dark needs no choice")
    }

    func testAPinnedWindowsOtherSlotIsWorkedOutAsIfFollowingTheSystem() {
        defaults.set("light", forKey: "appearance")
        defaults.set("system", forKey: "terminalAppearance")
        defaults.set("#fafafa", forKey: "terminalBackground")

        let migrated = Preferences.load(from: defaults)
        XCTAssertEqual(migrated.lightTheme?.colors.first, "#fafafa")
        XCTAssertEqual(
            migrated.darkTheme?.colors.first, "#fafafa",
            "the override applied whatever the appearance, so dark had it too")
        defaults.removeObject(forKey: "terminalBackground")

        let unadjusted = Preferences.load(from: defaults)
        XCTAssertNil(unadjusted.lightTheme)
        XCTAssertNil(
            unadjusted.darkTheme,
            "pinned light never showed dark; following the system later should show the built-in")
    }

    func testTheOldSettingsGoOnTheFirstSave() {
        defaults.set("Paper", forKey: "themeName")
        defaults.set(paper.colors, forKey: "themeColors")
        defaults.set("dark", forKey: "terminalAppearance")
        defaults.set("#101010", forKey: "terminalBackground")
        defaults.set("#eeeeee", forKey: "terminalForeground")

        Preferences.load(from: defaults).save(to: defaults)
        for key in [
            "themeName", "themeColors", "terminalAppearance",
            "terminalBackground", "terminalForeground",
        ] {
            XCTAssertNil(defaults.object(forKey: key), "\(key) outlived the save")
        }
    }

    func testClearingAMigratedSlotDoesNotBringTheOldThemeBack() {
        defaults.set("Paper", forKey: "themeName")
        defaults.set(paper.colors, forKey: "themeColors")

        var preferences = Preferences.load(from: defaults)
        preferences.lightTheme = nil
        preferences.darkTheme = nil
        preferences.save(to: defaults)

        let reloaded = Preferences.load(from: defaults)
        XCTAssertNil(reloaded.lightTheme)
        XCTAssertNil(reloaded.darkTheme)
    }
}
