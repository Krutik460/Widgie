import CoreGraphics
import Foundation
import ImageIO
import Rows
import Spec
import Synchronization

/// Image assets for one render call. Decodes each referenced asset once, as a thumbnail no larger than the
/// display needs, and applies `crop` before caching. Two sources, one behavior: stored widgets read
/// content-addressed files; proofs read the bytes of a `WidgetSource` before anything is saved.
package final class AssetImages: Sendable {
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
    private let decoded = Mutex<[Key: DecodedImage]>([:])

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
    package var decodedPixels: Int {
        decoded.withLock { $0.values.reduce(0) { $0 + $1.cgImage.width * $1.cgImage.height } }
    }

    /// `crop` is in fractions of the image, from the top left. `maxPixels` is the most the display can show;
    /// the decode is just large enough that the cropped part covers it, and never larger than the source.
    package func image(_ id: Spec.AssetID, crop: CGRect?, maxPixels: CGSize) -> DecodedImage? {
        let region = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let key = Key(
            id: id, crop: [region.minX, region.minY, region.width, region.height],
            pixels: [maxPixels.width, maxPixels.height])
        if let hit = decoded.withLock({ $0[key] }) { return hit }
        guard let image = decode(id, region: region, maxPixels: maxPixels) else { return nil }
        decoded.withLock { $0[key] = image }
        return image
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
        return DecodedImage(cgImage: cropped)
    }
}
