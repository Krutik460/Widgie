import CoreText
import Foundation

/// The fonts the engine ships in `Fonts/`, which `cut-bricolage.py` cuts from the OFL variable font. They are
/// registered for the whole process once, before an engine is made or a named font is drawn, so the app, the
/// widget extension, and render-tool all draw them from this one copy, and the app may name them too.
package enum BundledFonts {
    /// The families, as `fontName` and `Font.custom` name them.
    package static let families = ["Bricolage Grotesque Display", "Bricolage Grotesque Key"]

    package static func register() { _ = registered }

    private static let registered: Void = {
        for url in Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}
