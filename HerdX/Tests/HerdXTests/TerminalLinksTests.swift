import AppKit
import CHerdrCore
import XCTest

@testable import HerdX

@MainActor
final class TerminalLinksTests: XCTestCase {
    private func pane(_ id: String, x: Int, width: Int) -> PaneView {
        let rect = CellRect(x: x, y: 0, width: width, height: 1)
        return PaneView(id: id, rect: rect, inner: rect, focused: true,
            alternateScreen: false, mouseReporting: false, scrollOffsetFromBottom: 0,
            scrollMaxOffsetFromBottom: 0, contentRevision: 2)
    }

    private func withGrid(
        _ symbols: [String], links: [Int: UInt32] = [:], target: String = "",
        width: Int? = nil,
        body: (GridView) -> Void
    ) {
        var glyphs: [UInt8] = []
        let cells = symbols.enumerated().map { index, symbol -> HxCell in
            let bytes = Array(symbol.utf8)
            let offset = glyphs.count
            glyphs += bytes
            return HxCell(fg: 0, bg: 0, modifier: 0, glyph_len: UInt16(bytes.count),
                glyph_off: UInt32(offset), hyperlink: links[index] ?? UInt32.max)
        }
        let targetBytes = Array(target.utf8)
        cells.withUnsafeBufferPointer { cellBuffer in
            glyphs.withUnsafeBufferPointer { glyphBuffer in
                targetBytes.withUnsafeBufferPointer { targetBuffer in
                    let entries = target.isEmpty ? [] : [HxHyperlink(
                        bytes: targetBuffer.baseAddress, len: targetBuffer.count)]
                    entries.withUnsafeBufferPointer { linkBuffer in
                        let columns = width ?? symbols.count
                        body(GridView(width: columns, height: symbols.count / columns, cells: cellBuffer,
                            glyphs: glyphBuffer, hyperlinks: linkBuffer,
                            cursor: (0, 0, false, 0), revision: 1, panes: [], placements: []))
                    }
                }
            }
        }
    }

    func testExplicitLinkBeatsPrintedURLAndStaysInsideItsPane() {
        let text = Array("https://example.com").map(String.init)
        withGrid(text + [" ", "A", "B"], links: [0: 0, 1: 0, 20: 0, 21: 0],
            target: "https://destination.test/pr/1") { grid in
            let first = pane("first", x: 0, width: 19)
            let second = pane("second", x: 20, width: 2)
            let explicit = TerminalLinks.resolve(grid, pane: first, column: 0, row: 0)
            XCTAssertEqual(explicit?.url.absoluteString, "https://destination.test/pr/1")
            XCTAssertEqual(explicit?.spans, [.init(row: 0, columns: 0..<2)])
            XCTAssertEqual(TerminalLinks.resolve(grid, pane: second, column: 20, row: 0)?.paneID,
                "second")
            XCTAssertNil(TerminalLinks.resolve(grid, pane: first, column: 20, row: 0))
        }
    }

    private func pane(_ id: String, _ rect: CellRect) -> PaneView {
        PaneView(id: id, rect: rect, inner: rect, focused: true, alternateScreen: false,
            mouseReporting: false, scrollOffsetFromBottom: 0, scrollMaxOffsetFromBottom: 0,
            contentRevision: 2)
    }

    private func rows(_ lines: [String], width: Int) -> [String] {
        lines.flatMap { Array($0.padding(toLength: width, withPad: " ", startingAt: 0)) }
            .map(String.init)
    }

    /// The shape a live 46-column surface put on the wire: the wrap lands
    /// inside the host, and herdr leaves the last column blank.
    func testWrappedPrintedURLOpensTheWholeAddress() {
        let width = 46
        let symbols = rows(["https://docs.example.com.internal-tools.examp", "le.org/runbook"],
            width: width)
        withGrid(symbols, width: width) { grid in
            let single = pane("single", CellRect(x: 0, y: 0, width: width, height: 2))
            let expected = "https://docs.example.com.internal-tools.example.org/runbook"
            let fromFirst = TerminalLinks.resolve(grid, pane: single, column: 10, row: 0)
            XCTAssertEqual(fromFirst?.url.absoluteString, expected)
            XCTAssertEqual(fromFirst?.url.host, "docs.example.com.internal-tools.example.org")
            XCTAssertEqual(fromFirst?.spans,
                [.init(row: 0, columns: 0..<45), .init(row: 1, columns: 0..<14)])
            XCTAssertEqual(
                TerminalLinks.resolve(grid, pane: single, column: 3, row: 1)?.url.absoluteString,
                expected, "the continuation row opens the same link")
        }
    }

    /// A pane wraps at its own edge; the neighbouring pane's cells are not a
    /// continuation of anything.
    func testWrapIsFollowedWithinASplitPane() {
        let symbols = rows(["https://ex|right-pane", "ample.com |more-text!"], width: 21)
        withGrid(symbols, width: 21) { grid in
            let left = pane("left", CellRect(x: 0, y: 0, width: 10, height: 2))
            let right = pane("right", CellRect(x: 11, y: 0, width: 10, height: 2))
            XCTAssertEqual(
                TerminalLinks.resolve(grid, pane: left, column: 4, row: 0)?.url.absoluteString,
                "https://example.com")
            XCTAssertNil(TerminalLinks.resolve(grid, pane: right, column: 12, row: 0))
        }
    }

    /// Only rows that run to the edge are joined: a URL that simply ends a
    /// line is still clickable, and the next line is not glued onto it.
    func testAURLEndingALineIsNotJoinedToTheNext() {
        let width = 40
        let symbols = rows(["see https://example.com/a", "next line"], width: width)
        withGrid(symbols, width: width) { grid in
            let single = pane("single", CellRect(x: 0, y: 0, width: width, height: 2))
            let link = TerminalLinks.resolve(grid, pane: single, column: 8, row: 0)
            XCTAssertEqual(link?.url.absoluteString, "https://example.com/a")
            XCTAssertEqual(link?.spans, [.init(row: 0, columns: 4..<25)])
        }
    }

    func testLargeExplicitLinkStillResolvesWhenHoverSpanIsBounded() {
        let width = 100
        let symbols = [String](repeating: "x", count: width * 100)
        let links = Dictionary(uniqueKeysWithValues: symbols.indices.map { ($0, UInt32(0)) })
        withGrid(symbols, links: links, target: "https://example.com/large", width: width) { grid in
            let rect = CellRect(x: 0, y: 0, width: width, height: 100)
            let pane = PaneView(id: "large", rect: rect, inner: rect, focused: true,
                alternateScreen: false, mouseReporting: false, scrollOffsetFromBottom: 0,
                scrollMaxOffsetFromBottom: 0, contentRevision: 2)
            let link = TerminalLinks.resolve(grid, pane: pane, column: 50, row: 50)
            XCTAssertEqual(link?.url.absoluteString, "https://example.com/large")
            XCTAssertTrue(link?.contains(50, 50) == true)
        }
    }

    func testPrintedURLAndSurroundingPunctuation() {
        let row = Array("See (https://example.com/a(b)?q=1&x=2), now.").map(String.init)
        let column = 10
        let found = TerminalLinks.printed(in: row, column: column)
        XCTAssertEqual(found?.url.absoluteString, "https://example.com/a(b)?q=1&x=2")
        XCTAssertNil(TerminalLinks.printed(in: row, column: row.count - 1))
    }

    func testUnicodeBeforeLinkKeepsColumnAlignment() {
        let row = ["🦊", " "] + Array("https://localhost:3000/x#part").map(String.init)
        XCTAssertEqual(TerminalLinks.printed(in: row, column: 2)?.columns.lowerBound, 2)
        XCTAssertEqual(TerminalLinks.printed(in: row, column: 2)?.url.host, "localhost")
    }

    func testOnlyWebURLsOpen() {
        XCTAssertNil(TerminalLinks.safeURL("file:///tmp/secret"))
        XCTAssertNil(TerminalLinks.safeURL("javascript:alert(1)"))
        XCTAssertNil(TerminalLinks.safeURL("https://"))
        XCTAssertNotNil(TerminalLinks.safeURL("https://example.com/a?b=c#d"))
    }

    func testCommandClickOpensOnceButDragCancels() {
        let view = TerminalGridView(font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            lineHeight: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        XCTAssertFalse(window.isVisible)
        defer { window.close() }
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertTrue(window.makeFirstResponder(view))
        guard let url = URL(string: "https://example.com") else { return XCTFail("invalid fixture") }
        let link = TerminalLink(url: url, paneID: "p1",
            spans: [.init(row: 0, columns: 0..<5)])
        view.linkResolverForTesting = { _ in link }
        var opened: [URL] = []
        view.openLink = { opened.append($0) }

        func event(_ type: NSEvent.EventType, x: CGFloat = 40) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 40),
                modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown))
        view.mouseUp(with: event(.leftMouseUp))
        XCTAssertEqual(opened, [link.url])

        view.linkResolverForTesting = { point in point.x < 100 ? link : nil }
        view.mouseDown(with: event(.leftMouseDown))
        view.mouseUp(with: event(.leftMouseUp, x: 150))
        XCTAssertEqual(opened, [link.url])

        view.mouseDown(with: event(.leftMouseDown))
        view.mouseDragged(with: event(.leftMouseDragged))
        view.mouseUp(with: event(.leftMouseUp))
        XCTAssertEqual(opened, [link.url])

        view.mouseDown(with: event(.leftMouseDown))
        view.linkResolverForTesting = { _ in nil }
        view.mouseUp(with: event(.leftMouseUp))
        XCTAssertEqual(opened, [link.url])

        view.linkResolverForTesting = { _ in link }
        view.mouseDown(with: event(.leftMouseDown))
        view.forgetSurface()
        view.mouseUp(with: event(.leftMouseUp))
        XCTAssertEqual(opened, [link.url])
    }
}
