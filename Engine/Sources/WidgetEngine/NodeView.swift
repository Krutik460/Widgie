import SwiftUI

/// One node of a `Drawing` as SwiftUI. Total: every case of `Kind` and every field of `Style` maps to views
/// a widget may use, so there is nothing here that can fail. Buttons go through the host's closures, which
/// is all this view knows about taps.
struct NodeView: View {
    let node: Node
    let host: FaceHost

    var body: some View {
        content.modifier(Styled(style: node.style, path: node.path, host: host))
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .vstack(let spacing, let align, let children):
            VStack(alignment: align.horizontal, spacing: spacing.map { CGFloat($0) }) { Nodes(children, host) }
        case .hstack(let spacing, let align, let children):
            HStack(alignment: align.vertical, spacing: spacing.map { CGFloat($0) }) { Nodes(children, host) }
        case .zstack(let align, let children):
            ZStack(alignment: align.alignment) { Nodes(children, host) }
        case .spacer(let minLength):
            Spacer(minLength: minLength.map { CGFloat($0) })
        case .text(let run):
            TextView(run: run).modifier(Probe(path: node.path, role: .text))
        case .symbol(let symbol):
            SymbolView(symbol: symbol).modifier(Probe(path: node.path, role: .leaf))
        case .shape(let geometry, let paint):
            ShapeView(geometry: geometry, paint: paint).modifier(Probe(path: node.path, role: .leaf))
        case .image(let picture):
            PictureView(picture: picture, host: host).modifier(Probe(path: node.path, role: .leaf))
        case .button(let press, let children):
            pressable(press, label: AnyView(ZStack { Nodes(children, host) }))
                .modifier(Probe(path: node.path, role: .leaf))
        }
    }

    private func pressable(_ press: Press, label: AnyView) -> AnyView {
        switch press {
        case .run(let tap): host.button(tap, label)
        case .form(let tap): host.form(tap, label)
        }
    }
}

private struct Nodes: View {
    let nodes: [Node]
    let host: FaceHost

    init(_ nodes: [Node], _ host: FaceHost) {
        self.nodes = nodes
        self.host = host
    }

    var body: some View {
        ForEach(nodes, id: \.path) { NodeView(node: $0, host: host) }
    }
}

/// The common props, in the order `Style` lists them. Split into groups because one chain of fourteen
/// optional modifiers overflows the compiler's opaque type substitution.
private struct Styled: ViewModifier {
    let style: Style
    let path: String
    let host: FaceHost

    func body(content: Content) -> some View {
        content
            .modifier(Layout(style: style))
            .modifier(Layers(style: style, path: path, host: host))
            .modifier(Effects(style: style))
            .modifier(Transforms(style: style))
            .modifier(AccentGroup(accent: style.accent, host: host))
    }
}

/// `accent: true`: the node, its layers included, joins the accent group. The renderer resolves colors inside it
/// to the tint, and the host marks it for the system (`widgetAccentable()` in the widget).
private struct AccentGroup: ViewModifier {
    let accent: Bool
    let host: FaceHost

    func body(content: Content) -> some View {
        if accent {
            host.accent(AnyView(content.environment(\.accentGroup, true)))
        } else {
            content
        }
    }
}

private struct Layout: ViewModifier {
    let style: Style

    func body(content: Content) -> some View {
        content
            .apply(style.aspectRatio) { $0.aspectRatio($1, contentMode: .fit) }
            .apply(style.padding) {
                $0.padding(EdgeInsets(top: $1.top, leading: $1.leading, bottom: $1.bottom, trailing: $1.trailing))
            }
            .apply(style.frame) { $0.framed($1) }
    }
}

private struct Layers: ViewModifier {
    let style: Style
    let path: String
    let host: FaceHost

    func body(content: Content) -> some View {
        content
            .apply(style.background) { view, layer in view.background { LayerView(layer: layer, host: host) } }
            .apply(style.overlay) { view, layer in view.overlay { LayerView(layer: layer, host: host) } }
            .apply(style.clip) { $0.clipShape($1.shape).modifier(Probe(path: path, role: .clip)) }
            .apply(style.mask) { view, layer in view.mask { LayerView(layer: layer, host: host) } }
    }
}

private struct Effects: ViewModifier {
    let style: Style
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .apply(style.opacity) { $0.opacity($1) }
            .apply(style.shadow) {
                $0.shadow(color: palette.color($1.color), radius: $1.radius, x: $1.offset.width, y: $1.offset.height)
            }
            .apply(style.blur) { $0.blur(radius: $1) }
    }
}

private struct Transforms: ViewModifier {
    let style: Style

    func body(content: Content) -> some View {
        content
            .apply(style.scale) { $0.scaleEffect(x: $1.width, y: $1.height) }
            .apply(style.rotation) { $0.rotationEffect(.degrees($1)) }
            .apply(style.offset) { $0.offset(x: $1.width, y: $1.height) }
            .apply(style.blend) { $0.blendMode($1.mode) }
    }
}

private struct LayerView: View {
    let layer: Layer
    let host: FaceHost
    @Environment(\.palette) private var palette

    var body: some View {
        switch layer {
        case .fill(let fill): Rectangle().fill(palette.paint(fill))
        case .node(let node): NodeView(node: node, host: host)
        }
    }
}

/// Colors resolve in a view of their own, below the node's modifiers, so an `accent` on the node reaches them.
private struct SymbolView: View {
    let symbol: Symbol
    @Environment(\.palette) private var palette

    var body: some View {
        Image(systemName: symbol.name)
            .font(.system(size: symbol.size, weight: symbol.weight.font))
            .foregroundStyle(palette.color(symbol.color))
    }
}

private struct TextView: View {
    let run: TextRun
    @Environment(\.palette) private var palette

    var body: some View {
        run.text(scale: 1)
            .foregroundStyle(palette.color(run.color))
            .lineLimit(run.lineLimit)
            .minimumScaleFactor(run.minScale)
            .multilineTextAlignment(run.align.text)
    }
}

extension TextRun {
    /// The size this text takes at `scale` of its font size, offered `width` (nil: as wide as it likes) and
    /// held to `lines` (nil: no limit), laid out on the pixel grid of `pixelScale`. The builder's fit analysis
    /// measures with it, so it sets type exactly as the renderer does.
    @MainActor package func size(scale: Double, width: Double?, lines: Int?, pixelScale: Double) -> CGSize {
        var measured = CGSize.zero
        let renderer = ImageRenderer(
            content: text(scale: scale).lineLimit(lines).fixedSize(horizontal: width == nil, vertical: true))
        renderer.scale = pixelScale
        renderer.proposedSize = ProposedViewSize(width: width.map { CGFloat($0) }, height: nil)
        renderer.render { size, _ in measured = size }
        return measured
    }

    /// The width of the first word alone on one line at `scale`, or zero when the text has no word. Words are
    /// found the way the system finds them, so text without spaces, such as Japanese, splits too.
    @MainActor package func firstWordWidth(scale: Double, pixelScale: Double) -> Double {
        var first: String?
        value.enumerateSubstrings(in: value.startIndex..., options: [.byWords, .localized]) { word, _, _, stop in
            first = word
            stop = true
        }
        guard let first else { return 0 }
        var measured = CGSize.zero
        let renderer = ImageRenderer(content: text(scale: scale, first).lineLimit(1).fixedSize())
        renderer.scale = pixelScale
        renderer.render { size, _ in measured = size }
        return measured.width
    }

    /// The font is `fixedSize`, like `.system(size:)`, so a named font does not grow with Dynamic Type and
    /// break fit.
    fileprivate func text(scale: Double, _ string: String? = nil) -> Text {
        let points = size * scale
        let font: Font =
            switch self.font {
            case .system(let design): .system(size: points, weight: weight.font, design: design.font)
            // Each bundled family is one face, and SwiftUI logs a failure for every weight it cannot find.
            case .named(let family) where BundledFonts.families.contains(family): .custom(family, fixedSize: points)
            case .named(let family): .custom(family, fixedSize: points).weight(weight.font)
            }
        return Text(string ?? value).font(font).italic(italic).strikethrough(strikethrough)
            .kerning((kerning ?? 0) * scale)
    }
}

private struct ShapeView: View {
    let geometry: Geometry
    let paint: ShapePaint

    var body: some View {
        let half = (paint.stroke?.width ?? 0) / 2
        switch geometry {
        case .rect(let radius):
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            Painted(shape: shape, outline: shape.inset(by: half), paint: paint)
        case .circle: Painted(shape: Circle(), outline: Circle().inset(by: half), paint: paint)
        case .capsule: Painted(shape: Capsule(), outline: Capsule().inset(by: half), paint: paint)
        case .ellipse: Painted(shape: Ellipse(), outline: Ellipse().inset(by: half), paint: paint)
        case .path(let data, let viewBox):
            let shape = PathShape(data: data, viewBox: viewBox)
            Painted(shape: shape, outline: shape, paint: paint)
        }
    }
}

/// Fill, then stroke along `outline`, each trimmed. Closed shapes pass an outline inset by half the stroke,
/// so the stroke stays inside their bounds; a path's stroke is centered on the path, as in SVG.
private struct Painted<Filled: Shape, Outline: Shape>: View {
    let shape: Filled
    let outline: Outline
    let paint: ShapePaint
    @Environment(\.palette) private var palette

    var body: some View {
        let trim = (from: CGFloat(paint.trim.lowerBound), to: CGFloat(paint.trim.upperBound))
        ZStack {
            if let fill = paint.fill {
                shape.trim(from: trim.from, to: trim.to).fill(palette.paint(fill))
            }
            if let stroke = paint.stroke {
                outline.trim(from: trim.from, to: trim.to)
                    .stroke(
                        palette.paint(stroke.fill),
                        style: StrokeStyle(
                            lineWidth: stroke.width, lineCap: stroke.cap.lineCap, lineJoin: .round,
                            dash: stroke.dash.map { CGFloat($0) }))
            }
        }
    }
}

/// SVG path data scaled to fit its rect, keeping the view box's aspect ratio, centered.
private struct PathShape: Shape {
    let data: PathData
    let viewBox: CGRect

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        var path = Path()
        for command in data.commands {
            switch command {
            case .move(let point): path.move(to: point)
            case .line(let point): path.addLine(to: point)
            case .quad(let point, let control): path.addQuadCurve(to: point, control: control)
            case .cubic(let point, let control1, let control2):
                path.addCurve(to: point, control1: control1, control2: control2)
            case .close: path.closeSubpath()
            }
        }
        return path.applying(
            CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale,
                tx: rect.minX + (rect.width - viewBox.width * scale) / 2 - viewBox.minX * scale,
                ty: rect.minY + (rect.height - viewBox.height * scale) / 2 - viewBox.minY * scale))
    }
}

/// In tinted mode an image follows its `tint`: `fullColor` as drawn, `desaturated` in gray, and `accented` in the
/// tint color with each pixel's brightness as its opacity, inside the accent group. The host maps the tint to
/// the system's own image mode as well.
private struct PictureView: View {
    let picture: Picture
    let host: FaceHost
    @Environment(\.renderingMode) private var mode

    var body: some View {
        switch (mode, picture.tint) {
        case (.fullColor, _), (.accented, .fullColor):
            adjusted
        case (.accented, .desaturated):
            adjusted.saturation(0)
        case (.accented, .accented):
            host.accent(
                AnyView(Palette.tint.color.mask { adjusted.saturation(0).luminanceToAlpha() }))
        }
    }

    private var adjusted: some View {
        let image = host.tint(
            picture.tint, Image(decorative: picture.image.cgImage, scale: 1).resizable().interpolation(.high))
        return Group {
            switch picture.mode {
            case .fill: Color.clear.overlay { image.aspectRatio(contentMode: .fill) }.clipped()
            case .fit: image.aspectRatio(contentMode: .fit)
            }
        }
        .apply(picture.adjust.saturation) { $0.saturation($1) }
        .apply(picture.adjust.brightness) { $0.brightness($1) }
        .apply(picture.adjust.contrast) { $0.contrast($1) }
    }
}

/// Reports frames to the geometry probe during a proof render. In a widget there is no probe, and this adds
/// nothing to the view.
struct Probe: ViewModifier {
    enum Role { case leaf, text, clip, root }

    let path: String
    let role: Role
    @Environment(\.geometryProbe) private var probe

    func body(content: Content) -> some View {
        if let probe {
            content.background(
                GeometryReader { geometry in
                    let _ = probe.record(role, path: path, geometry: geometry)
                    Color.clear
                })
        } else {
            content
        }
    }
}

extension View {
    /// `transform` when `value` is present, else the view unchanged.
    @ViewBuilder fileprivate func apply<T, V: View>(_ value: T?, _ transform: (Self, T) -> V) -> some View {
        if let value { transform(self, value) } else { self }
    }

    @ViewBuilder fileprivate func framed(_ frame: Frame) -> some View {
        let alignment = frame.alignment.alignment
        let fixed = frame.width != nil || frame.height != nil
        let flexible =
            frame.minWidth != nil || frame.maxWidth != nil || frame.minHeight != nil || frame.maxHeight != nil
        switch (fixed, flexible) {
        case (true, true):
            self.frame(
                width: frame.width.map { CGFloat($0) }, height: frame.height.map { CGFloat($0) }, alignment: alignment
            )
            .frame(
                minWidth: frame.minWidth.map { CGFloat($0) }, maxWidth: frame.maxWidth.map { CGFloat($0) },
                minHeight: frame.minHeight.map { CGFloat($0) }, maxHeight: frame.maxHeight.map { CGFloat($0) },
                alignment: alignment)
        case (true, false):
            self.frame(
                width: frame.width.map { CGFloat($0) }, height: frame.height.map { CGFloat($0) }, alignment: alignment)
        case (false, true):
            self.frame(
                minWidth: frame.minWidth.map { CGFloat($0) }, maxWidth: frame.maxWidth.map { CGFloat($0) },
                minHeight: frame.minHeight.map { CGFloat($0) }, maxHeight: frame.maxHeight.map { CGFloat($0) },
                alignment: alignment)
        case (false, false):
            self
        }
    }
}

extension Clip {
    fileprivate var shape: AnyShape {
        switch self {
        case .rect: AnyShape(Rectangle())
        case .circle: AnyShape(Circle())
        case .capsule: AnyShape(Capsule())
        case .ellipse: AnyShape(Ellipse())
        case .rounded(let radius): AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

extension HAlign {
    fileprivate var horizontal: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    fileprivate var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

extension VAlign {
    fileprivate var vertical: VerticalAlignment {
        switch self {
        case .top: .top
        case .center: .center
        case .bottom: .bottom
        case .firstBaseline: .firstTextBaseline
        }
    }
}

extension Align {
    fileprivate var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        case .bottomLeading: .bottomLeading
        case .bottom: .bottom
        case .bottomTrailing: .bottomTrailing
        }
    }
}

extension Weight {
    fileprivate var font: Font.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
}

extension Design {
    fileprivate var font: Font.Design {
        switch self {
        case .default: .default
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        }
    }
}

extension Cap {
    fileprivate var lineCap: CGLineCap {
        switch self {
        case .butt: .butt
        case .round: .round
        }
    }
}

extension Blend {
    fileprivate var mode: BlendMode {
        switch self {
        case .normal: .normal
        case .multiply: .multiply
        case .screen: .screen
        case .overlay: .overlay
        case .darken: .darken
        case .lighten: .lighten
        case .colorDodge: .colorDodge
        case .colorBurn: .colorBurn
        case .softLight: .softLight
        case .hardLight: .hardLight
        case .difference: .difference
        case .exclusion: .exclusion
        }
    }
}
