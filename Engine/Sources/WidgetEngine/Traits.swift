import CoreGraphics

/// What a face shows, as far as a host suggesting a change to it needs to know. A fallback face shows nothing.
public struct FaceTraits: Sendable, Equatable {
    /// Some text of at least 20 points shows a digit: a count, a total, a time.
    public let showsNumber: Bool
    /// The hue, in degrees from 0 up to 360, that the face paints most across its text, symbols, and fills.
    /// Greys, near-blacks, and faint colors do not count. Nil when the face paints only those.
    public let hue: Double?
}

extension Face {
    public var traits: FaceTraits {
        guard case .drawing(let drawing) = content else { return FaceTraits(showsNumber: false, hue: nil) }
        var tally = Tally()
        if let background = drawing.background {
            tally.add(background, area: drawing.size.width * drawing.size.height)
        }
        tally.add(drawing.root)
        return FaceTraits(showsNumber: tally.showsNumber, hue: tally.hue)
    }
}

/// Paint weighed by roughly how much of the face it covers, in twelve 30 degree sectors of the color wheel.
private struct Tally {
    var showsNumber = false
    private var weights = [Double](repeating: 0, count: 12)
    private var hues = [Double](repeating: 0, count: 12)

    /// The weighted mean hue of the heaviest sector.
    var hue: Double? {
        guard let sector = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[sector] > 0 else {
            return nil
        }
        return hues[sector] / weights[sector]
    }

    mutating func add(_ node: Node) {
        let frame = node.style.frame
        // A node without a fixed size counts as a 20 point square, about a symbol's size.
        let area = frame.flatMap { frame in frame.width.flatMap { width in frame.height.map { width * $0 } } } ?? 400
        if let background = node.style.background { add(background, area: area) }
        if let overlay = node.style.overlay { add(overlay, area: area) }
        switch node.kind {
        case .vstack(_, _, let children), .hstack(_, _, let children), .zstack(_, let children),
            .button(_, _, let children):
            for child in children { add(child) }
        case .text(let run):
            if run.size >= 20, run.value.contains(where: \.isNumber) { showsNumber = true }
            // Each character is about half as wide as the text is tall.
            add(run.color, weight: run.size * run.size * 0.5 * Double(run.value.count))
        case .symbol(let symbol):
            // A symbol fills about a square of its size.
            add(symbol.color, weight: symbol.size * symbol.size)
        case .shape(_, let paint):
            if let fill = paint.fill { add(fill, weight: area) }
            // An outline paints a thin edge, about a fifth of what filling the shape would.
            if let stroke = paint.stroke { add(stroke.fill, weight: area * 0.2) }
        case .spacer, .image:
            break
        }
    }

    mutating func add(_ layer: Layer, area: Double) {
        switch layer {
        case .fill(let fill): add(fill, weight: area)
        case .node(let node): add(node)
        }
    }

    private mutating func add(_ fill: Fill, weight: Double) {
        switch fill {
        case .color(let color):
            add(color, weight: weight)
        case .linear(let stops, _, _), .radial(let stops, _, _, _), .angular(let stops, _, _, _):
            // Each stop paints an even share of the gradient.
            for stop in stops { add(stop.color, weight: weight / Double(stops.count)) }
        }
    }

    private mutating func add(_ color: ColorPair, weight: Double) {
        let (r, g, b, a) = (color.light.r, color.light.g, color.light.b, color.light.a)
        let brightest = max(r, g, b)
        let spread = brightest - min(r, g, b)
        // Faint (alpha 0.2 or less), near black (no channel over 0.3), or grey (saturation 0.3 or less).
        guard a > 0.2, brightest > 0.3, spread / brightest > 0.3 else { return }
        let sixth =
            switch brightest {
            case r: (g - b) / spread
            case g: 2 + (b - r) / spread
            default: 4 + (r - g) / spread
            }
        let hue = (sixth * 60 + 360).truncatingRemainder(dividingBy: 360)
        let sector = Int(hue / 30) % 12
        weights[sector] += weight * a
        hues[sector] += hue * weight * a
    }
}
