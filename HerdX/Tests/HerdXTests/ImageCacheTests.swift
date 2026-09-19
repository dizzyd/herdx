import AppKit
import CoreGraphics
import XCTest

@testable import HerdX

/// Asset ids are allocated per machine, both starting at 1, so the cache is one
/// machine's and nothing keyed by a bare number survives a switch.
@MainActor
final class ImageCacheTests: XCTestCase {
    private func image(grey: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: grey, green: grey, blue: grey, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }

    private func placement(assetID: UInt64) -> Placement {
        Placement(
            assetID: assetID, x: 0, y: 0, cols: 2, rows: 1,
            sourceX: 0, sourceY: 0, sourceWidth: 2, sourceHeight: 2,
            xOffset: 0, yOffset: 0, z: 0)
    }

    private func gridView() -> TerminalGridView {
        TerminalGridView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular), lineHeight: 1)
    }

    func testPruningKeepsAnAssetTheSceneStillPlaces() {
        var cache = ImageCache()
        cache[1] = image(grey: 0.2)
        cache[2] = image(grey: 0.8)

        cache.prune(keeping: [placement(assetID: 1)])

        XCTAssertNotNil(cache[1])
        XCTAssertNil(cache[2])
    }

    func testPruningCannotTellTheOtherMachinesAssetOneApart() {
        // The number is still live on the new machine, so pruning preserves
        // the previous machine's picture. This is why emptying is needed.
        var cache = ImageCache()
        let fromTheOldMachine = image(grey: 0.2)
        cache[1] = fromTheOldMachine

        cache.prune(keeping: [placement(assetID: 1)])

        XCTAssertTrue(cache[1] === fromTheOldMachine)
    }

    func testEmptyingDropsEverything() {
        var cache = ImageCache()
        cache[1] = image(grey: 0.2)
        cache[7] = image(grey: 0.5)

        cache.empty()

        XCTAssertEqual(cache.count, 0)
    }

    func testForgettingASurfaceEmptiesTheImageCache() {
        let view = gridView()
        view.imageCache[1] = image(grey: 0.2)

        view.forgetSurface()

        XCTAssertEqual(
            view.imageCache.count, 0,
            "asset 1 on the machine switched to is a different picture")
    }
}
