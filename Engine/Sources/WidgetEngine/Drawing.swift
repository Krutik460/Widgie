import CoreGraphics
import Foundation

// The validated tree. `Drawing.parse` is the only producer, so every value here is in range, every
// button has a resolved `Tap`, and every image is decoded. The renderer is total over this type: it has
// no error paths. The vocabulary that produces it is the registry in Vocabulary.swift, and the
// model-facing reference is Reference/look.md. Append-only (see `Spec.Upgrade`).

package struct Drawing: Sendable {
    package let root: Node
    /// `widgetBackground` on the root. Nil draws white.
    package let background: Layer?
    package let size: CGSize
    package let family: Family
    /// Every button, in tree order; the builder's coverage rule reads it.
    package let taps: [Tap]
}

package struct Node: Sendable {
    package let kind: Kind
    package let style: Style
    /// "root.children[2]", for fit reports and error lines.
    package let path: String
}

package enum Kind: Sendable {
    case vstack(spacing: Double?, align: HAlign, children: [Node])
    case hstack(spacing: Double?, align: VAlign, children: [Node])
    case zstack(align: Align, children: [Node])
    case spacer(minLength: Double?)
    case text(TextRun)
    case symbol(Symbol)
    case shape(Geometry, ShapePaint)
    case image(Picture)
    /// The renderer hands `children` to the host's closure for this press. That is all it knows.
    case button(Press, children: [Node])
}

/// What a button does. A widget cannot show a form, so the host turns `.form` into a link that opens the
/// app, and `.run` into the App Intent.
package enum Press: Sendable {
    case run(Tap)
    case form(Tap)

    package var tap: Tap {
        switch self {
        case .run(let tap), .form(let tap): tap
        }
    }
}

package struct TextRun: Sendable {
    package let value: String
    package let size: Double
    package let weight: Weight
    package let font: Typeface
    package let italic: Bool
    package let color: ColorPair
    package let lineLimit: Int?
    package let minScale: Double
    package let align: HAlign
    package let strikethrough: Bool
    package let kerning: Double?
}

package enum Typeface: Sendable {
    case system(Design)
    /// A family in `Vocabulary.fonts`.
    case named(String)
}

package struct Symbol: Sendable {
    /// Checked against the platform's symbol set at validation.
    package let name: String
    package let size: Double
    package let weight: Weight
    package let color: ColorPair
}

package enum Geometry: Sendable {
    case rect(cornerRadius: Double)
    case circle
    case capsule
    case ellipse
    /// Parsed from SVG `d` at validation, and scaled to fit its frame keeping the view box's aspect ratio.
    case path(PathData, viewBox: CGRect)
}

package struct PathData: Sendable {
    package enum Command: Sendable, Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(CGPoint, control: CGPoint)
        case cubic(CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }
    /// Arcs are converted to cubics when parsed.
    package let commands: [Command]
}

package struct ShapePaint: Sendable {
    /// Nil only when the shape has a stroke; a shape with neither is filled black at validation.
    package let fill: Fill?
    package let stroke: Stroke?
    package let trim: ClosedRange<Double>
}

package struct Stroke: Sendable {
    package let fill: Fill
    package let width: Double
    package let cap: Cap
    /// Dash and gap lengths. Empty is solid.
    package let dash: [Double]
}

package struct Picture: Sendable {
    /// Already cropped and sized for the display's pixels.
    package let image: DecodedImage
    package let mode: ImageMode
    package let adjust: ColorAdjust
    /// How tinted mode draws it.
    package let tint: ImageTint
}

/// Each is nil when the look leaves it out, and the renderer then adds no modifier.
package struct ColorAdjust: Sendable {
    package let saturation: Double?
    package let brightness: Double?
    package let contrast: Double?
}

/// Common props, applied in the fixed order this struct lists them.
package struct Style: Sendable {
    package var aspectRatio: Double?
    package var padding: Insets?
    package var frame: Frame?
    package var background: Layer?
    package var overlay: Layer?
    package var clip: Clip?
    package var mask: Layer?
    package var opacity: Double?
    package var shadow: Shadow?
    package var blur: Double?
    package var scale: CGSize?
    package var rotation: Double?
    package var offset: CGSize?
    package var blend: Blend?
    /// Drawn in the tint color in tinted mode, with everything in it. Applied outermost.
    package var accent = false
}

/// A background, overlay, mask, or widget background: a fill or a whole node. Boxed because a node's style
/// holds nodes.
package indirect enum Layer: Sendable {
    case fill(Fill)
    case node(Node)
}

package enum Fill: Sendable {
    case color(ColorPair)
    case linear(stops: [Stop], from: CGPoint, to: CGPoint)
    case radial(stops: [Stop], center: CGPoint, startRadius: Double, endRadius: Double)
    case angular(stops: [Stop], center: CGPoint, startAngle: Double, endAngle: Double)
}

package struct Stop: Sendable {
    package let color: ColorPair
    package let location: Double
}

/// sRGB components from 0 to 1.
package struct RGBA: Sendable, Hashable {
    package let r, g, b, a: Double
}

/// A color for each color scheme. A plain hex color is the same in both.
package struct ColorPair: Sendable, Hashable {
    package let light, dark: RGBA

    package init(light: RGBA, dark: RGBA) {
        self.light = light
        self.dark = dark
    }

    package init(_ both: RGBA) { self.init(light: both, dark: both) }
}

package struct Frame: Sendable {
    package var width, height, minWidth, minHeight: Double?
    /// `.infinity` for "infinity".
    package var maxWidth, maxHeight: Double?
    package var alignment: Align
}

package struct Insets: Sendable {
    package let top, leading, bottom, trailing: Double
}

package struct Shadow: Sendable {
    package let color: ColorPair
    package let radius: Double
    package let offset: CGSize
}

package enum Clip: Sendable {
    case rect, circle, capsule, ellipse
    case rounded(Double)
}

// The names below are the words a look writes, so each enum's raw values are its allowed list.

package enum HAlign: String, CaseIterable, Sendable { case leading, center, trailing }
package enum VAlign: String, CaseIterable, Sendable { case top, center, bottom, firstBaseline }
package enum Align: String, CaseIterable, Sendable {
    case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing

    /// The point an alignment names, in unit coordinates, for gradient endpoints.
    package var unitPoint: CGPoint {
        switch self {
        case .topLeading: CGPoint(x: 0, y: 0)
        case .top: CGPoint(x: 0.5, y: 0)
        case .topTrailing: CGPoint(x: 1, y: 0)
        case .leading: CGPoint(x: 0, y: 0.5)
        case .center: CGPoint(x: 0.5, y: 0.5)
        case .trailing: CGPoint(x: 1, y: 0.5)
        case .bottomLeading: CGPoint(x: 0, y: 1)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .bottomTrailing: CGPoint(x: 1, y: 1)
        }
    }
}
package enum Weight: String, CaseIterable, Sendable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
}
package enum Design: String, CaseIterable, Sendable { case `default`, serif, rounded, monospaced }
package enum Cap: String, CaseIterable, Sendable { case butt, round }
package enum ImageMode: String, CaseIterable, Sendable { case fill, fit }

/// How an image draws in tinted mode: in its own colors, in gray, or in the tint color by its brightness. Public
/// because `FaceHost.tint` maps it to WidgetKit's accented rendering mode.
public enum ImageTint: String, CaseIterable, Sendable { case fullColor, desaturated, accented }
package enum ClipShape: String, CaseIterable, Sendable { case rect, circle, capsule, ellipse }
package enum Blend: String, CaseIterable, Sendable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, softLight, hardLight, difference,
        exclusion
}

/// A decoded image. CGImage is immutable, so sharing it across threads is safe.
package struct DecodedImage: @unchecked Sendable {
    package let cgImage: CGImage
}
