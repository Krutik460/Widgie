import CoreGraphics
import Foundation
import ImageIO
import Spec
import SwiftUI
import WidgetEngine

/// Turns captured geometry into a `FitReport`: each drawn node's spill past the widget and past its clipping
/// ancestors, and for each text whether it fits at its smallest allowed scale in the space it was given.
@MainActor
func analyze(
    _ probe: GeometryProbe, drawing: Drawing, image: CGImage, imagePixels: Int, lookMilliseconds: Double,
    renderMilliseconds: Double
) -> FitReport {
    let nodes = catalog(drawing)
    let bounds = CGRect(origin: .zero, size: drawing.size)
    var edges = [String: Double]()
    var cuts: [FitReport.Cut] = []
    for (path, frame) in probe.frames where frame.width > 0 && frame.height > 0 {
        let sides = excess(frame, beyond: bounds)
        for (edge, amount) in sides { edges[edge] = max(edges[edge] ?? 0, amount) }
        var worst = (within: "widget", side: sides.max { $0.amount < $1.amount }!)
        for (clip, clipFrame) in probe.clips where path == clip || path.hasPrefix(clip + ".") {
            let side = excess(frame, beyond: clipFrame).max { $0.amount < $1.amount }!
            if side.amount > worst.side.amount { worst = (clip, side) }
        }
        guard worst.side.amount > 0.05 else { continue }
        cuts.append(
            FitReport.Cut(
                path: path, node: nodes[path]?.type ?? "node", label: nodes[path]?.label ?? "", within: worst.within,
                edge: worst.side.edge, spill: tenth(worst.side.amount)))
    }
    cuts.sort { ($0.spill, $1.path) > ($1.spill, $0.path) }

    var truncated: [FitReport.Truncation] = []
    var ellipsized: [FitReport.Truncation] = []
    for (path, given) in probe.textSizes.sorted(by: { $0.key < $1.key }) {
        guard let run = nodes[path]?.text, given.width >= 1 else { continue }
        switch fit(run, in: given, at: path) {
        case .fits: break
        case .cut(let row): truncated.append(row)
        case .ellipsis(let row): ellipsized.append(row)
        }
    }

    let overflow = probe.rootSize.map {
        FitReport.Overflow(
            width: tenth(max(0, $0.width - bounds.width)), height: tenth(max(0, $0.height - bounds.height)))
    }
    return FitReport(
        spill: cuts.first?.spill ?? 0, layoutOverflow: overflow ?? FitReport.Overflow(width: 0, height: 0),
        edges: FitReport.Edges(
            top: tenth(edges["top"] ?? 0), bottom: tenth(edges["bottom"] ?? 0),
            leading: tenth(edges["leading"] ?? 0), trailing: tenth(edges["trailing"] ?? 0)),
        cut: Array(cuts.prefix(8)), truncated: truncated, ellipsized: ellipsized,
        ink: inkShare(image), cover: nil, imagePixels: imagePixels,
        buttons: drawing.taps.map(\.action), lookMilliseconds: lookMilliseconds,
        renderMilliseconds: renderMilliseconds)
}

/// The builder's acceptance rule for one render, as the line the model receives, or nil when it passes.
/// Shared by `build` and `Engine.proof`, so the render tool's verdict is exactly the builder's.
func verdict(for fit: FitReport, size: CGSize) -> String? {
    if fit.spill > 2, let worst = fit.cut.first {
        let amount = Int(worst.spill.rounded(.up))
        let what = worst.label.isEmpty ? worst.node : "\(worst.node) \(Diagnostic.quote(worst.label))"
        guard worst.within == "widget" else {
            return
                "content spills \(amount)pt past the \(worst.edge) edge of the clip at \(worst.within); the worst cut is \(what) at \(worst.path); shrink it or give the clipping node more room"
        }
        let room =
            ["top", "bottom"].contains(worst.edge)
            ? "\(Int(size.height))pt of height" : "\(Int(size.width))pt of width"
        return
            "content spills \(amount)pt past the \(worst.edge) edge; the worst cut is \(what) at \(worst.path); make things smaller or show fewer rows so everything fits in \(room), and keep every button"
    }
    if let cut = fit.truncated.first {
        let text = "text \(Diagnostic.quote(cut.value)) at \(cut.path)"
        let wanted = min(cut.linesNeeded, cut.lineLimit ?? cut.linesNeeded)
        guard cut.linesShown >= wanted else {
            return
                "\(text) needs \(wanted) \(wanted == 1 ? "line" : "lines") but has room for \(cut.linesShown) (\(Int(cut.width))pt wide); give it room, or set a lineLimit and a minScale so it can end in an ellipsis"
        }
        return
            "\(text) does not fit the \(Int(cut.width))pt it was given, not even its first word; give it more width, take room from what sits beside it, or let it shrink with a lower minScale"
    }
    if fit.ink < 0.0005 { return "the render is blank; check colors against the background" }
    return nil
}

/// The line for a dark or tinted render, which keeps the light render's layout, or nil when it passes.
func appearanceVerdict(for fit: FitReport, _ appearance: Appearance) -> String? {
    if fit.ink < 0.0005 {
        return appearance == .tinted
            ? "the render is blank in tinted mode, which drops widgetBackground and draws every color white at its own opacity; put the backdrop in widgetBackground, not in a full-size shape, and show state through opacity or shape"
            : "the render is blank in dark mode; check the dark value of each { light, dark } color against the background"
    }
    if let cover = fit.cover, cover > 0.5 {
        return
            "\(Int((cover * 100).rounded()))% of the render is one flat color in tinted mode, so a full-size shape draws the backdrop and hides what sits on it; move that color to the root's widgetBackground"
    }
    return nil
}

extension FitReport {
    /// This report for the same tree drawn again in another appearance: the layout stays, the pixels change.
    func redrawn(ink: Double, cover: Double?, renderMilliseconds: Double) -> FitReport {
        FitReport(
            spill: spill, layoutOverflow: layoutOverflow, edges: edges, cut: cut, truncated: truncated,
            ellipsized: ellipsized, ink: ink, cover: cover, imagePixels: imagePixels, buttons: buttons,
            lookMilliseconds: lookMilliseconds, renderMilliseconds: renderMilliseconds)
    }
}

/// 8-bit RGBA PNG.
func encodePNG(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

private enum TextFit {
    case fits
    case cut(FitReport.Truncation)
    case ellipsis(FitReport.Truncation)
}

/// Measures at the smallest scale the text allows, because SwiftUI shrinks it that far before it cuts. A
/// text that needs more height than it got, even held to its own `lineLimit`, is cut. One that only runs
/// past its `lineLimit` ends in the ellipsis the look asked for, unless that ellipsis cuts into its first word.
@MainActor
private func fit(_ run: TextRun, in given: CGSize, at path: String) -> TextFit {
    func measure(width: Double?, lines: Int?) -> CGSize {
        run.size(scale: run.minScale, width: width, lines: lines, pixelScale: renderScale)
    }
    let ideal = measure(width: nil, lines: nil)
    if ideal.width <= given.width + 0.5, ideal.height <= given.height + 1 { return .fits }
    let line = max(measure(width: nil, lines: 1).height, 1)
    let wrapped = measure(width: given.width, lines: nil)
    let held = run.lineLimit.map { measure(width: given.width, lines: $0) } ?? wrapped
    let row = FitReport.Truncation(
        path: path, value: String(run.value.prefix(60)), linesNeeded: max(1, Int((wrapped.height / line).rounded())),
        linesShown: max(0, Int(((given.height + 1) / line).rounded(.down))), lineLimit: run.lineLimit,
        width: tenth(given.width), height: tenth(given.height))
    if held.height > given.height + 1 || wrapped.width > given.width + 0.5 { return .cut(row) }
    guard let limit = run.lineLimit, row.linesNeeded > limit else { return .fits }
    // An ellipsis is the look's choice only while the start of the text survives it. One that lands inside the
    // first word ("Monst...") means the text was squeezed, so it counts as cut.
    let first = run.firstWordWidth(scale: run.minScale, pixelScale: renderScale)
    return first > given.width + 0.5 ? .cut(row) : .ellipsis(row)
}

/// The type, label, and text run of every drawn node, by path.
private func catalog(_ drawing: Drawing) -> [String: (type: String, label: String, text: TextRun?)] {
    var nodes: [String: (type: String, label: String, text: TextRun?)] = [:]
    func visit(_ node: Node) {
        switch node.kind {
        case .vstack(_, _, let children), .hstack(_, _, let children), .zstack(_, let children):
            children.forEach(visit)
        case .spacer:
            break
        case .text(let run):
            nodes[node.path] = ("text", run.value, run)
        case .symbol(let symbol):
            nodes[node.path] = ("symbol", symbol.name, nil)
        case .shape(let geometry, _):
            nodes[node.path] = (geometry.name, "", nil)
        case .image:
            nodes[node.path] = ("image", "", nil)
        case .button(let press, let children):
            nodes[node.path] = ("button", press.tap.action, nil)
            children.forEach(visit)
        }
        for case .node(let layer)? in [node.style.background, node.style.overlay, node.style.mask] { visit(layer) }
    }
    visit(drawing.root)
    if case .node(let layer)? = drawing.background { visit(layer) }
    return nodes
}

/// How far `frame` sits past each edge of `bounds`, zero where it is inside.
private func excess(_ frame: CGRect, beyond bounds: CGRect) -> [(edge: String, amount: Double)] {
    [
        ("top", max(0, bounds.minY - frame.minY)), ("bottom", max(0, frame.maxY - bounds.maxY)),
        ("leading", max(0, bounds.minX - frame.minX)), ("trailing", max(0, frame.maxX - bounds.maxX)),
    ]
}

/// Share of sampled pixels that stand out from the most common color: some channel at least 32 levels of 255
/// away, to four places. Text one shade off its background is not ink, and a white numeral on navy is.
func inkShare(_ image: CGImage) -> Double {
    let samples = opaqueSamples(image)
    guard let dominant = mostCommon(samples) else { return 0 }
    let ink = samples.filter { distance($0, dominant) >= 32 }
    return fourth(Double(ink.count) / Double(samples.count))
}

/// Share of sampled pixels in the most common color that is not `backdrop` (32 levels of 255 or more away from
/// it), to four places. A full-size shape in tinted mode turns into one flat sheet and scores near 1; text,
/// symbols, and small shapes on the backdrop score low, and so does a photo, whose colors vary.
func coverShare(_ image: CGImage, backdrop: RGBA) -> Double {
    let samples = opaqueSamples(image)
    guard !samples.isEmpty else { return 0 }
    let back = (r: Int(backdrop.r * 255), g: Int(backdrop.g * 255), b: Int(backdrop.b * 255))
    var counts: [Int: Int] = [:]
    for pixel in samples where distance(pixel, back) >= 32 { counts[bin(pixel), default: 0] += 1 }
    return fourth(Double(counts.values.max() ?? 0) / Double(samples.count))
}

private typealias Pixel = (r: Int, g: Int, b: Int)

/// Every third pixel in each direction. Only fully opaque pixels count, so the anti-aliased rounded corners do
/// not.
private func opaqueSamples(_ image: CGImage) -> [Pixel] {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return [] }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var samples: [Pixel] = []
    for y in stride(from: 0, to: height, by: 3) {
        for x in stride(from: 0, to: width, by: 3) {
            let index = (y * width + x) * 4
            guard bytes[index + 3] == 255 else { continue }
            samples.append((r: Int(bytes[index]), g: Int(bytes[index + 1]), b: Int(bytes[index + 2])))
        }
    }
    return samples
}

/// Colors in bins of 8 levels per channel.
private func bin(_ pixel: Pixel) -> Int { (pixel.r >> 3) << 10 | (pixel.g >> 3) << 5 | (pixel.b >> 3) }

/// The center of the most common bin.
private func mostCommon(_ samples: [Pixel]) -> Pixel? {
    var counts: [Int: Int] = [:]
    for pixel in samples { counts[bin(pixel), default: 0] += 1 }
    guard let top = counts.max(by: { $0.value < $1.value })?.key else { return nil }
    return (r: ((top >> 10) << 3) + 4, g: (((top >> 5) & 31) << 3) + 4, b: ((top & 31) << 3) + 4)
}

private func distance(_ a: Pixel, _ b: Pixel) -> Int { max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) }

private func fourth(_ value: Double) -> Double { (value * 10000).rounded() / 10000 }

private func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }

extension Geometry {
    fileprivate var name: String {
        switch self {
        case .rect: "rect"
        case .circle: "circle"
        case .capsule: "capsule"
        case .ellipse: "ellipse"
        case .path: "path"
        }
    }
}
