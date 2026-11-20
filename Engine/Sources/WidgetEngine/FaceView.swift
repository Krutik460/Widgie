import SwiftUI

/// What differs between the places a face is shown. Closures, so the renderer imports neither AppIntents
/// nor WidgetKit:
/// - the widget wraps a button in `Button(intent:)`, a form button in a `Link` that opens the app, and puts
///   the background in `containerBackground`,
/// - the app wraps both in closure buttons and draws the background itself,
/// - proofs and the render tool use `.still`.
public struct FaceHost: Sendable {
    public typealias Wrap = @MainActor @Sendable (_ tap: Tap, _ label: AnyView) -> AnyView
    public typealias Compose = @MainActor @Sendable (_ content: AnyView, _ background: AnyView) -> AnyView

    /// A button whose action writes in place.
    public let button: Wrap
    /// A button whose action asks for input, which only the app can show.
    public let form: Wrap
    public let root: Compose

    public init(button: @escaping Wrap, form: @escaping Wrap, root: @escaping Compose) {
        self.button = button
        self.form = form
        self.root = root
    }

    /// Buttons draw their children and do nothing. The background is drawn under the content and the
    /// whole face is clipped to the widget's rounded rectangle.
    public static let still = FaceHost(
        button: { _, label in label },
        form: { _, label in label },
        root: { content, background in
            AnyView(
                ZStack {
                    background
                    content
                }.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
        }
    )
}

/// Renders a face. Total: a `Drawing` has no invalid states, and a fallback has a fixed calm look.
public struct FaceView: View {
    let face: Face
    let host: FaceHost

    public init(_ face: Face, host: FaceHost) {
        self.face = face
        self.host = host
    }

    public var body: some View {
        switch face.content {
        case .drawing(let drawing): DrawingView(drawing: drawing, host: host)
        case .fallback(let name, _): FallbackView(name: name, host: host)
        }
    }
}

/// Maps a `Drawing` to SwiftUI. The root node is centered in the widget and offered its whole size; the
/// background fills the widget behind it. Knows `Tap` only as an opaque value it passes to the host.
package struct DrawingView: View {
    package let drawing: Drawing
    package let host: FaceHost

    package init(drawing: Drawing, host: FaceHost) {
        self.drawing = drawing
        self.host = host
    }

    package var body: some View {
        let size = drawing.size
        host.root(
            AnyView(
                NodeView(node: drawing.root, host: host)
                    .modifier(Probe(path: drawing.root.path, role: .root))
                    .frame(width: size.width, height: size.height)),
            AnyView(BackgroundView(layer: drawing.background, host: host))
        )
        .frame(width: size.width, height: size.height)
        .coordinateSpace(.named(GeometryProbe.space))
    }
}

/// White when the look sets no `widgetBackground`.
struct BackgroundView: View {
    let layer: Layer?
    let host: FaceHost

    var body: some View {
        switch layer {
        case nil: Color.white
        case .fill(let fill)?: Rectangle().fill(fill.paint)
        case .node(let node)?: NodeView(node: node, host: host).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The calm face for an unknown widget, an empty store, or a look that failed on this data. It names the
/// widget when the name is known and never shows why it failed.
struct FallbackView: View {
    let name: String?
    let host: FaceHost

    var body: some View {
        host.root(
            AnyView(
                VStack(spacing: 8) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color(white: 0.56))
                    Text(name ?? "Widget")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            AnyView(Color(red: 0.11, green: 0.11, blue: 0.12)))
    }
}

/// Geometry capture for the builder's fit analysis. Exists only during a proof render, where the
/// environment carries it to every node; in a widget it is nil and no geometry readers are added.
/// Frames are in the widget's coordinate space.
package final class GeometryProbe: @unchecked Sendable {
    package static let space = "widget"

    /// Node path to frame, for every text, symbol, shape, image, and button.
    package private(set) var frames: [String: CGRect] = [:]
    /// Node path to the frame a `clip` or `cornerRadius` clips to.
    package private(set) var clips: [String: CGRect] = [:]
    /// Node path to the size each text was given.
    package private(set) var textSizes: [String: CGSize] = [:]
    /// The size the root node takes when offered the widget's size. Larger than the widget means overflow.
    package private(set) var rootSize: CGSize?

    package init() {}

    @MainActor func record(_ role: Probe.Role, path: String, geometry: GeometryProxy) {
        let frame = geometry.frame(in: .named(Self.space))
        switch role {
        case .leaf:
            frames[path] = frame
        case .text:
            frames[path] = frame
            textSizes[path] = geometry.size
        case .clip:
            clips[path] = frame
        case .root:
            rootSize = geometry.size
        }
    }
}

// A hand-written key, not `@Entry`: the Command Line Tools ship no SwiftUI macro plugin, so the package
// uses no SwiftUI macros (`@Entry`, `#Preview`) if it is to build on this Mac.
private struct GeometryProbeKey: EnvironmentKey {
    static let defaultValue: GeometryProbe? = nil
}

extension EnvironmentValues {
    package var geometryProbe: GeometryProbe? {
        get { self[GeometryProbeKey.self] }
        set { self[GeometryProbeKey.self] = newValue }
    }
}
