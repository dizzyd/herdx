import AppKit
import XCTest

@testable import HerdX

/// The list survives between presentations; only the window around it is
/// rebuilt. These guard what that reuse leaves behind.
///
/// Presented over a window that is never ordered in — `show` only makes the
/// chooser key when its parent is visible — so running these does not put
/// anything on screen.
@MainActor
final class PickerTests: XCTestCase {
    private var parent: NSWindow!

    override func setUp() async throws {
        parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        // ARC owns it here; without this, closing it releases it a second time.
        parent.isReleasedWhenClosed = false
        XCTAssertFalse(parent.isVisible, "the test window must stay off screen")
    }

    override func tearDown() async throws {
        parent.close()
        parent = nil
    }

    private func items(_ titles: [String], chose: @escaping (String) -> Void = { _ in })
        -> [Picker.Item]
    {
        titles.map { title in
            Picker.Item(title: title, detail: "detail for \(title)") { chose(title) }
        }
    }

    /// Closes the floating chooser the way its close button does.
    private func dismiss(_ picker: Picker) {
        picker.presented?.close()
    }

    func testReopeningDoesNotAddAColumn() {
        let picker = Picker()

        picker.show(over: parent, title: "First", items: items(["a", "b"]), as: .floating)
        XCTAssertEqual(picker.list.numberOfColumns, 1)
        dismiss(picker)

        picker.show(over: parent, title: "Second", items: items(["c", "d"]), as: .floating)
        XCTAssertEqual(
            picker.list.numberOfColumns, 1,
            "a second column duplicates every row's content")
        dismiss(picker)

        picker.show(over: parent, title: "Third", items: items(["e"]), as: .floating)
        XCTAssertEqual(picker.list.numberOfColumns, 1)
        dismiss(picker)
    }

    func testReopeningClearsTheFilterAndShowsEverything() {
        let picker = Picker()
        picker.show(over: parent, title: "First", items: items(["alpha", "beta"]), as: .floating)

        picker.filterField.stringValue = "alph"
        picker.filterField.sendAction(picker.filterField.action, to: picker.filterField.target)
        XCTAssertEqual(picker.list.numberOfRows, 1, "the filter should have applied")
        dismiss(picker)

        picker.show(
            over: parent, title: "Second", items: items(["gamma", "delta", "epsilon"]),
            as: .floating)

        XCTAssertEqual(picker.filterField.stringValue, "")
        XCTAssertEqual(
            picker.list.numberOfRows, 3,
            "the previous presentation's filter was still narrowing the list")
        dismiss(picker)
    }





    func testCancellingDoesNotRunAnyRowsAction() {
        let picker = Picker()
        var chosen: [String] = []
        var cancelled = false

        picker.show(
            over: parent, title: "Themes",
            items: items(["a", "b"], chose: { chosen.append($0) }), as: .floating,
            onCancel: { cancelled = true })
        dismiss(picker)

        XCTAssertTrue(cancelled)
        XCTAssertEqual(chosen, [])
    }
}
