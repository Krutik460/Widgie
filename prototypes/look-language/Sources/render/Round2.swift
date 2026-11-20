import SwiftUI
import AppKit
import ImageIO

// Round two vocabulary: named fonts, image assets, and the fit measurement.

let fontFamilies: [(name: String, style: String)] = [
    ("Bradley Hand", "handwriting, a quick pen"),
    ("Noteworthy", "handwriting, neat notes"),
    ("Marker Felt", "handwriting, felt marker"),
    ("Chalkduster", "display, chalk on a blackboard"),
    ("Snell Roundhand", "script, formal calligraphy"),
    ("American Typewriter", "typewriter"),
    ("Rockwell", "slab serif"),
    ("DIN Condensed", "condensed, bold signage, capitals work best"),
    ("Avenir Next Condensed", "condensed, clean, every weight"),
    ("Futura", "display, geometric poster type"),
    ("Copperplate", "display, engraved small capitals"),
    ("Didot", "display, high contrast fashion serif"),
]

let appKitWeights: [String: Int] = [
    "ultraLight": 2, "thin": 3, "light": 3, "regular": 5, "medium": 6,
    "semibold": 8, "bold": 9, "heavy": 10, "black": 12,
]

func resolveFont(family: String, size: CGFloat, weight: String, italic: Bool) -> NSFont? {
    let fm = NSFontManager.shared
    let w = appKitWeights[weight] ?? 5
    if italic, let f = fm.font(withFamily: family, traits: .italicFontMask, weight: w, size: size) { return f }
    return fm.font(withFamily: family, traits: [], weight: w, size: size)
}

struct Asset {
    var image: CGImage
    var sourceWidth: Int
    var sourceHeight: Int
}

let assetPixelBudget = 800_000
var assetRegistry: [String: Asset] = [:]

func loadAsset(_ path: String) throws -> Asset {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else {
        throw LookError("cannot read image asset \(path)")
    }
    var maxSide = max(w, h)
    if w * h > assetPixelBudget {
        maxSide = Int((Double(maxSide) * (Double(assetPixelBudget) / Double(w * h)).squareRoot()).rounded(.down))
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxSide,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
        throw LookError("cannot decode image asset \(path)")
    }
    return Asset(image: image, sourceWidth: w, sourceHeight: h)
}

struct TextProbe {
    var path: String
    var value: String
    var lineLimit: Int?
    // The same text at its smallest allowed scale, so shrinking to fit is not counted as cut.
    var smallest: (String) -> Text
}

final class FitCollector {
    var enabled = true
    var frames: [String: CGRect] = [:]
    var localSizes: [String: CGSize] = [:]
    var kinds: [String: String] = [:]
    var labels: [String: String] = [:]
    var clips: [String: CGRect] = [:]
    var rootSize: CGSize?
    var texts: [TextProbe] = []

    func leaf(_ path: String, _ kind: String, _ label: String) {
        kinds[path] = kind
        labels[path] = label
    }
}

extension View {
    func reportGeometry(_ collector: FitCollector, _ sink: @escaping (FitCollector, GeometryProxy) -> Void) -> some View {
        background(GeometryReader { geo in
            let _ = collector.enabled ? sink(collector, geo) : ()
            Color.clear
        })
    }
}

@MainActor
func fittedSize<V: View>(_ view: V) -> CGSize {
    NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
}

func round1(_ x: CGFloat) -> Double { (Double(x) * 10).rounded() / 10 }

// Points by which `r` sticks out of `bounds` on each edge.
func excess(_ r: CGRect, _ bounds: CGRect) -> [String: Double] {
    [
        "top": round1(max(0, bounds.minY - r.minY)), "bottom": round1(max(0, r.maxY - bounds.maxY)),
        "leading": round1(max(0, bounds.minX - r.minX)), "trailing": round1(max(0, r.maxX - bounds.maxX)),
    ]
}

@MainActor
func fitReport(_ c: FitCollector, widget: CGSize) -> [String: Any] {
    let bounds = CGRect(origin: .zero, size: widget)
    let layoutW = round1(max(0, (c.rootSize?.width ?? 0) - widget.width))
    let layoutH = round1(max(0, (c.rootSize?.height ?? 0) - widget.height))
    var edges: [String: Double] = ["top": 0, "bottom": 0, "leading": 0, "trailing": 0]
    var cut: [[String: Any]] = []
    for (path, frame) in c.frames where frame.width > 0 && frame.height > 0 {
        var worst = excess(frame, bounds)
        var within = "widget"
        for (k, v) in worst { edges[k] = max(edges[k]!, v) }
        for (clipPath, clipFrame) in c.clips where path == clipPath || path.hasPrefix(clipPath + ".") {
            let e = excess(frame, clipFrame)
            if e.values.max()! > worst.values.max()! {
                worst = e
                within = clipPath
            }
        }
        let most = worst.values.max()!
        if most > 0 {
            var row: [String: Any] = ["path": path, "type": c.kinds[path] ?? "", "label": c.labels[path] ?? "", "within": within, "max": most]
            for (k, v) in worst where v > 0 { row[k] = v }
            cut.append(row)
        }
    }
    cut.sort { ($0["max"] as! Double, $1["path"] as! String) > ($1["max"] as! Double, $0["path"] as! String) }
    let contentMax = cut.first.map { $0["max"] as! Double } ?? 0

    var truncated: [[String: Any]] = []
    for t in c.texts {
        guard let size = c.localSizes[t.path], size.width >= 1 else { continue }
        let needed = fittedSize(t.smallest(t.value).lineLimit(nil).fixedSize(horizontal: false, vertical: true).frame(width: size.width.rounded(.up) + 1)).height
        let oneLine = fittedSize(t.smallest("Ag").fixedSize()).height
        let linesNeeded = max(1, Int((needed / max(oneLine, 1)).rounded()))
        let overLimit = t.lineLimit.map { linesNeeded > $0 } ?? false
        // A one-line text that is squeezed by a point or two cannot wrap, so the line count misses it.
        let squeezed = (t.lineLimit == 1 || t.value.count == 1) && fittedSize(t.smallest(t.value).fixedSize()).width > size.width + 1
        if overLimit || squeezed || needed > size.height + 1 {
            var row: [String: Any] = ["path": t.path, "value": String(t.value.prefix(60)), "lines_needed": linesNeeded,
                                      "height_needed": round1(needed), "height": round1(size.height), "width": round1(size.width)]
            if let l = t.lineLimit { row["line_limit"] = l }
            truncated.append(row)
        }
    }
    truncated.sort { ($0["path"] as! String) < ($1["path"] as! String) }

    if ProcessInfo.processInfo.environment["FIT_DEBUG"] != nil {
        for (path, f) in c.frames.sorted(by: { $0.key < $1.key }) {
            let ideal = c.texts.first { $0.path == path }.map { fittedSize($0.smallest($0.value).fixedSize()) }
            FileHandle.standardError.write("\(path) \(c.kinds[path] ?? "") \"\(c.labels[path] ?? "")\" frame \(f) local \(String(describing: c.localSizes[path])) ideal \(String(describing: ideal))\n".data(using: .utf8)!)
        }
    }
    return [
        "layout": ["width": layoutW, "height": layoutH],
        "edges": edges,
        "content_max": contentMax,
        "max": max(layoutW, layoutH, contentMax),
        "cut": Array(cut.prefix(8)),
        "cut_count": cut.count,
        "truncated": truncated,
        "texts": c.texts.count,
    ]
}

struct FontSpecimen: View {
    struct Row { var family: String; var style: String; var faces: [(label: String, font: NSFont?)] }
    var rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<rows.count, id: \.self) { i in
                let row = rows[i]
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.family).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(white: 0.9))
                        Text(row.style).font(.system(size: 12)).foregroundStyle(Color(white: 0.62))
                    }
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(0..<row.faces.count, id: \.self) { j in
                            let face = row.faces[j]
                            VStack(alignment: .leading, spacing: 3) {
                                if let f = face.font {
                                    Text("Water the plants 0123456789").font(Font(f as CTFont)).foregroundStyle(.white).lineLimit(1).fixedSize()
                                    Text("\(face.label): \(f.fontName)").font(.system(size: 10)).foregroundStyle(Color(white: 0.55))
                                } else {
                                    Text("does not resolve").font(.system(size: 14)).foregroundStyle(Color(red: 1, green: 0.6, blue: 0.6))
                                    Text(face.label).font(.system(size: 10)).foregroundStyle(Color(white: 0.55))
                                }
                            }
                            .frame(width: 330, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.2)).frame(height: 1) }
            }
        }
        .padding(20)
        .background(Color(red: 0.09, green: 0.094, blue: 0.102))
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
func fontSpecimen() -> (view: FontSpecimen, report: [[String: Any]]) {
    var rows: [FontSpecimen.Row] = []
    var report: [[String: Any]] = []
    for (family, style) in fontFamilies {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        let regular = resolveFont(family: family, size: 20, weight: "regular", italic: false)
        let bold = resolveFont(family: family, size: 20, weight: "bold", italic: false)
        let italic = resolveFont(family: family, size: 20, weight: "regular", italic: true)
        rows.append(.init(family: family, style: style, faces: [("regular", regular), ("bold", bold), ("italic", italic)]))
        report.append([
            "family": family, "style": style, "resolves": !members.isEmpty,
            "faces": members.compactMap { $0.first as? String },
            "regular": regular?.fontName ?? NSNull(), "bold": bold?.fontName ?? NSNull(), "italic": italic?.fontName ?? NSNull(),
        ])
    }
    return (FontSpecimen(rows: rows), report)
}
