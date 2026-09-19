import CHerdrCore
import CoreGraphics
import Foundation
import ImageIO

/// Turns the server's image bytes into something Core Graphics can draw.
///
/// herdr sends whichever form the originating program used, so all three
/// formats have to be handled: PNG goes through ImageIO, while raw RGB and RGBA
/// are already pixel data and only need wrapping.
enum ImageDecoder {
    static func decode(data: Data, width: Int, height: Int, format: UInt8) -> CGImage? {
        switch format {
        case UInt8(HX_IMAGE_PNG):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        case UInt8(HX_IMAGE_RGB):
            return raw(data: data, width: width, height: height, components: 3)
        case UInt8(HX_IMAGE_RGBA):
            return raw(data: data, width: width, height: height, components: 4)
        default:
            return nil
        }
    }

    private static func raw(data: Data, width: Int, height: Int, components: Int) -> CGImage? {
        guard width > 0, height > 0, data.count >= width * height * components,
            let provider = CGDataProvider(data: data as CFData)
        else { return nil }

        let info: CGBitmapInfo =
            components == 4
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: components * 8,
            bytesPerRow: width * components,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent)
    }
}

/// Decoded images, held so they are not decoded again every frame.
///
/// An asset's bytes arrive once and decoding is far too expensive to repeat,
/// so a result is kept until the scene stops placing it.
///
/// Belongs to one machine. The core allocates asset ids per endpoint, each
/// starting at 1, so asset 1 on the machine you switch to is a different
/// picture entirely — and pruning cannot notice, because that number is still
/// live. Changing machines has to empty it.
struct ImageCache {
    private var images: [UInt64: CGImage] = [:]

    var count: Int { images.count }

    subscript(assetID: UInt64) -> CGImage? {
        get { images[assetID] }
        set { images[assetID] = newValue }
    }

    /// Drops anything the current scene no longer places.
    mutating func prune(keeping placements: [Placement]) {
        guard !images.isEmpty else { return }
        let live = Set(placements.map(\.assetID))
        images = images.filter { live.contains($0.key) }
    }

    mutating func empty() { images.removeAll() }
}
