import AppKit
import XCTest

@testable import HerdX

/// Applying a theme writes four settings, not two. Cancelling has to put back
/// all four, or the colour wells are lost by pressing Escape.
///
/// `Preferences.current` is read for a starting value and never written back,
/// so these leave the real settings alone — and every test sets the whole
/// selection before asserting on it, so what is in them does not matter.
final class ThemeSelectionTests: XCTestCase {
    /// What "Match Attached" or the colour wells leave behind: exact colours
    /// and no loaded palette.
    private func customColours() -> Preferences.ThemeSelection {
        Preferences.ThemeSelection(
            name: nil,
            colors: nil,
            background: NSColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1),
            foreground: NSColor(srgbRed: 0.9, green: 0.9, blue: 0.88, alpha: 1))
    }

    /// What applying a loaded theme leaves behind: a palette, no overrides.
    private func loadedTheme() -> Preferences.ThemeSelection {
        Preferences.ThemeSelection(
            name: "Solarized Dark",
            colors: ["#002b36", "#839496"],
            background: nil,
            foreground: nil)
    }

    func testApplyingAThemeClearsTheColourOverrides() {
        var preferences = Preferences.current
        preferences.themeSelection = customColours()
        XCTAssertNotNil(preferences.background)

        preferences.themeSelection = loadedTheme()

        XCTAssertNil(
            preferences.background,
            "a loaded palette and the two overrides cannot both win")
        XCTAssertNil(preferences.foreground)
        XCTAssertEqual(preferences.themeName, "Solarized Dark")
    }

    func testCancellingPutsBackEverythingApplyingChanged() {
        var preferences = Preferences.current
        preferences.themeSelection = customColours()
        let before = preferences.themeSelection

        // Highlighting rows in the picker, each one applied to be looked at.
        preferences.themeSelection = loadedTheme()
        preferences.themeSelection = Preferences.ThemeSelection(
            name: "Nord", colors: ["#2e3440"], background: nil, foreground: nil)

        // Escape.
        preferences.themeSelection = before

        XCTAssertEqual(
            preferences.themeSelection, before,
            "the colours set through the wells were lost by pressing Escape")
        XCTAssertEqual(preferences.background, customColours().background)
        XCTAssertEqual(preferences.foreground, customColours().foreground)
        XCTAssertNil(preferences.themeName)
        XCTAssertNil(preferences.themeColors)
    }

    func testTheSelectionCoversEveryFieldApplyingWrites() {
        // Guards the pairing itself: a setting added to one side and not the
        // other is how the two came apart in the first place.
        var preferences = Preferences.current
        preferences.themeSelection = customColours()
        let before = preferences.themeSelection

        preferences.themeSelection = loadedTheme()
        XCTAssertNotEqual(preferences.themeSelection, before)

        preferences.themeSelection = before
        XCTAssertEqual(preferences.themeName, before.name)
        XCTAssertEqual(preferences.themeColors, before.colors)
        XCTAssertEqual(preferences.background, before.background)
        XCTAssertEqual(preferences.foreground, before.foreground)
    }

    func testRestoringAPaletteAlsoRestoresTheAbsenceOfOverrides() {
        var preferences = Preferences.current
        preferences.themeSelection = loadedTheme()
        let before = preferences.themeSelection

        preferences.themeSelection = customColours()
        preferences.themeSelection = before

        XCTAssertEqual(preferences.themeName, "Solarized Dark")
        XCTAssertNil(preferences.background, "the overrides were not there to restore")
        XCTAssertNil(preferences.foreground)
    }
}
