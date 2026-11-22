import CoreGraphics
import Testing
import WidgetEngine

@Suite struct AssetImagesTests {
    /// The widget extension has 30 MB, so a cached crop must hold only the pixels the budget charges for, not
    /// the whole decode it was cut from.
    @Test func aCachedCropHoldsOnlyItsOwnPixels() throws {
        let photo = try #require(mistakeSpec.asset(named: "photo")).id
        let crop = try AssetImages.inMemory([photo: landscape]).image(
            photo, crop: CGRect(x: 0.2, y: 0.25, width: 0.1, height: 0.5), maxPixels: CGSize(width: 300, height: 200)
        ).cgImage
        #expect([crop.width, crop.height] == [30, 100])
        #expect(crop.bytesPerRow * crop.height <= crop.width * crop.height * 4)
    }
}
