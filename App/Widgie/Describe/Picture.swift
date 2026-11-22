import PhotosUI
import SwiftUI
import UIKit
import WidgetBuilder

/// A photo the person attaches, as the model gets it: at most 1080 pixels on its longest side, as JPEG.
enum Picture {
    static func attachment(from data: Data) -> Attachment? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, 1080 / max(pixels.width, pixels.height))
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // JPEG has no alpha, so a transparent screenshot goes on white rather than black.
        let flat = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = flat.jpegData(compressionQuality: 0.85) else { return nil }
        return Attachment(mime: "image/jpeg", bytes: jpeg)
    }

    static func load(_ item: PhotosPickerItem) async -> Attachment? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return attachment(from: data)
    }
}

/// The attached photo as a small rounded thumbnail.
struct Thumbnail: View {
    let attachment: Attachment
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let image = UIImage(data: attachment.bytes) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Palette.off
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .accessibilityLabel("Attached picture")
    }
}
