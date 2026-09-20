import XCTest

@testable import HerdX

/// The tree is herdr's, so the fixture is too.
///
/// This is the exact body of a `layout.export` reply from a running server —
/// a tab split right at 0.35 with its second half split down at 0.6 — rather
/// than a shape invented here. A model that only round-trips its own idea of
/// the format is the guessing this type exists to avoid.
final class LayoutTreeTests: XCTestCase {
    private let exported = """
        {
          "type": "split",
          "direction": "right",
          "ratio": 0.35,
          "first": {
            "type": "pane",
            "pane_id": "w7:p1",
            "label": "alpha",
            "cwd": "/Users/dizzyd/src/herdx"
          },
          "second": {
            "type": "split",
            "direction": "down",
            "ratio": 0.6,
            "first": {
              "type": "pane",
              "pane_id": "w7:p2",
              "label": "beta",
              "cwd": "/Users/dizzyd/src/herdx"
            },
            "second": {
              "type": "pane",
              "pane_id": "w7:p3",
              "label": "gamma",
              "cwd": "/private/tmp"
            }
          }
        }
        """

    private func decoded() throws -> LayoutNode {
        try JSONDecoder().decode(LayoutNode.self, from: Data(exported.utf8))
    }

    func testAServersOwnExportDecodes() throws {
        guard case .split(let root) = try decoded() else {
            return XCTFail("the root of the exported tab is a split")
        }
        XCTAssertEqual(root.direction, "right")
        XCTAssertEqual(root.ratio, 0.35, accuracy: 0.0001)

        guard case .split(let nested) = root.second else {
            return XCTFail("the second half is split again")
        }
        XCTAssertEqual(nested.direction, "down")
        XCTAssertEqual(nested.ratio, 0.6, accuracy: 0.0001)
    }

    func testTheTreeReEncodesToWhatTheServerSent() throws {
        let tree = try decoded()
        let reEncoded = try JSONEncoder().encode(tree)

        // Compared as JSON rather than as text: key order is not part of the
        // document, and asserting on it would fail for a reason that does not
        // matter.
        let original = try JSONSerialization.jsonObject(with: Data(exported.utf8))
        let returned = try JSONSerialization.jsonObject(with: reEncoded)
        XCTAssertEqual(
            returned as? NSDictionary, original as? NSDictionary,
            "what goes back to layout.apply is no longer what came out of layout.export")
    }

    func testAStoredTreeSurvivesAFileRoundTrip() throws {
        let tree = try decoded()
        let stored = try JSONEncoder().encode(tree)
        let back = try JSONDecoder().decode(LayoutNode.self, from: stored)
        XCTAssertEqual(back, tree, "a hibernated workspace would come back a different shape")
    }

    func testCommandsAreStrippedAtEveryDepth() throws {
        let withCommands = LayoutNode.split(
            .init(
                direction: "right", ratio: 0.5,
                first: .pane(.init(cwd: "/a", command: ["claude", "--resume", "x"])),
                second: .split(
                    .init(
                        direction: "down", ratio: 0.5,
                        first: .pane(.init(cwd: "/b", command: ["npm", "run", "dev"])),
                        second: .pane(.init(cwd: "/c"))))))

        let commands = withCommands.withoutCommands.leaves.compactMap { $0.pane.command }

        XCTAssertTrue(
            commands.isEmpty,
            "a pane applied with a command has no shell under it, and its idle test stops working")
        XCTAssertEqual(
            withCommands.withoutCommands.leaves.compactMap { $0.pane.cwd }, ["/a", "/b", "/c"],
            "stripping the commands must not disturb anything else")
    }

    func testLeavesAreAddressedByPositionRatherThanByPaneID() throws {
        let leaves = try decoded().leaves

        XCTAssertEqual(leaves.map(\.pane.label), ["alpha", "beta", "gamma"])
        XCTAssertEqual(
            leaves.map(\.path), [[false], [true, false], [true, true]],
            "paths are how a revived pane is matched to the agent that was in it")
    }

    func testALeafCanBeFoundAgainByItsPath() throws {
        let tree = try decoded()
        for (path, pane) in tree.leaves {
            XCTAssertEqual(tree.leaf(at: path)?.label, pane.label)
        }
        XCTAssertNil(tree.leaf(at: [false, false]), "a path the tree does not have finds nothing")
        XCTAssertNil(tree.leaf(at: []), "the root is a split, not a leaf")
    }
}
