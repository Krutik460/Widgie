import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import WidgetBuilder

/// A photo the person attaches: the JPEG the model gets, at most 1080 pixels on its longest side, and that
/// image decoded once for the thumbnails.
struct Picture {
    let attachment: Attachment
    let image: UIImage

    /// Nil when the photo cannot be loaded or decoded.
    static func load(_ item: PhotosPickerItem) async -> Picture? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return Picture(data)
    }

    /// Decodes straight to the downscaled size, upright, without decoding the full photo first.
    init?(_ data: Data) {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1080,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let size = CGSize(width: scaled.width, height: scaled.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // JPEG has no alpha, so a transparent screenshot goes on white rather than black.
        let flat = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: scaled).draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = flat.jpegData(compressionQuality: 0.85) else { return nil }
        attachment = Attachment(mime: "image/jpeg", bytes: jpeg)
        image = flat
    }
}

/// The attached photo as a small rounded thumbnail.
struct Thumbnail: View {
    let picture: Picture
    var size: CGFloat = 44

    var body: some View {
        Image(uiImage: picture.image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityLabel("Attached picture")
    }
}
