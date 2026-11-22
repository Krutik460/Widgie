import CoreGraphics
import Foundation
import ImageIO
import Rows
import Spec
import Synchronization

/// Image assets for one render call: one `faces` call, or one proof cell. Decodes each referenced asset once
/// per crop and display size, as a thumbnail no larger than the display needs, and applies `crop` before
/// caching. Two sources, one behavior: stored widgets read content-addressed files; proofs read the bytes of a
/// `WidgetSource` before anything is saved.
///
/// Everything it decodes counts against `pixelBudget` for its whole lifetime. The cache keys on the crop and
/// the display size, so each distinct crop of one asset is its own decode and counts again. A decode past the budget returns
/// `.overBudget` and holds nothing, so the widget and its proof enforce the same cap in the same place.
package final class AssetImages: Sendable {
    /// The most image pixels one render call may hold decoded: 1.5 megapixels, about 6 MB.
    package static let pixelBudget = 1_500_000

    package enum Failure: Error {
        /// The asset is missing or its bytes are not an image.
        case unreadable
        /// The decode would take this call past `pixelBudget`.
        case overBudget
    }

    private enum Source: Sendable {
        case files([Spec.AssetID: URL])
        case bytes([Spec.AssetID: Data])
    }

    private struct Key: Hashable {
        let id: Spec.AssetID
        let crop: [Double]
        let pixels: [Double]
    }

    private let source: Source
    private let decoded = Mutex<(images: [Key: DecodedImage], pixels: Int)>(([:], 0))

    private init(_ source: Source) { self.source = source }

    package static func stored(_ spec: Spec, store: RowStore) -> AssetImages {
        AssetImages(
            .files(
                Dictionary(
                    uniqueKeysWithValues: spec.assets.compactMap { asset in
                        asset.digest.map { (asset.id, store.assetURL($0)) }
                    })))
    }

    package static func inMemory(_ bytes: [Spec.AssetID: Data]) -> AssetImages { AssetImages(.bytes(bytes)) }

    /// Every pixel decoded so far, which is what this render call holds in memory for images.
    package var decodedPixels: Int { decoded.withLock { $0.pixels } }

    /// `crop` is in fractions of the image, from the top left. `maxPixels` is the most the display can show;
    /// the decode is just large enough that the cropped part covers it, and never larger than the source.
    package func image(_ id: Spec.AssetID, crop: CGRect?, maxPixels: CGSize) throws(Failure) -> DecodedImage {
        let region = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let key = Key(
            id: id, crop: [region.minX, region.minY, region.width, region.height],
            pixels: [maxPixels.width, maxPixels.height])
        if let hit = decoded.withLock({ $0.images[key] }) { return hit }
        guard let image = decode(id, region: region, maxPixels: maxPixels) else { throw .unreadable }
        let pixels = image.cgImage.width * image.cgImage.height
        return try decoded.withLock { (decoded) throws(Failure) -> DecodedImage in
            if let hit = decoded.images[key] { return hit }
            guard decoded.pixels + pixels <= Self.pixelBudget else { throw .overBudget }
            decoded.images[key] = image
            decoded.pixels += pixels
            return image
        }
    }

    private func decode(_ id: Spec.AssetID, region: CGRect, maxPixels: CGSize) -> DecodedImage? {
        let file: CGImageSource? =
            switch source {
            case .files(let urls): urls[id].flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
            case .bytes(let all): all[id].flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            }
        guard let file, let properties = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }
        let quarterTurn = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        let upright = quarterTurn ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let scale = min(
            1,
            max(
                maxPixels.width / (region.width * upright.width), maxPixels.height / (region.height * upright.height)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int((Double(max(width, height)) * scale).rounded(.up))),
        ]
        guard let whole = CGImageSourceCreateThumbnailAtIndex(file, 0, options as CFDictionary) else { return nil }
        if region == CGRect(x: 0, y: 0, width: 1, height: 1) { return DecodedImage(cgImage: whole) }
        let pixels = CGRect(
            x: region.minX * Double(whole.width), y: region.minY * Double(whole.height),
            width: region.width * Double(whole.width), height: region.height * Double(whole.height)
        ).integral
        guard let cropped = whole.cropping(to: pixels), cropped.width > 0, cropped.height > 0 else { return nil }
        return copy(cropped).map(DecodedImage.init)
    }

    /// A crop shares the whole thumbnail's buffer, so caching it would hold every pixel of the thumbnail
    /// while the budget charges only the crop's. A copy holds just the crop.
    private func copy(_ image: CGImage) -> CGImage? {
        let space =
            image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
