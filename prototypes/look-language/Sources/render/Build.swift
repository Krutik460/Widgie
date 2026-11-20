import SwiftUI
import AppKit

let nodeTypes = ["vstack", "hstack", "zstack", "spacer", "text", "symbol", "rect", "circle", "capsule", "ellipse", "path", "button", "image"]

let commonProps = ["padding", "frame", "background", "overlay", "clip", "cornerRadius", "opacity", "shadow", "rotation", "offset", "scale", "blur", "mask", "aspectRatio"]

let ownProps: [String: [String]] = [
    "vstack": ["spacing", "align", "children"],
    "hstack": ["spacing", "align", "children"],
    "zstack": ["align", "children"],
    "spacer": ["minLength"],
    "text": ["value", "size", "weight", "design", "italic", "color", "lineLimit", "minScale", "align", "strikethrough", "kerning", "fontName"],
    "symbol": ["name", "size", "weight", "color"],
    "rect": ["fill", "stroke", "trimFrom", "trimTo"],
    "circle": ["fill", "stroke", "trimFrom", "trimTo"],
    "capsule": ["fill", "stroke", "trimFrom", "trimTo"],
    "ellipse": ["fill", "stroke", "trimFrom", "trimTo"],
    "path": ["d", "viewBox", "fill", "stroke", "trimFrom", "trimTo"],
    "button": ["action", "rowId", "children"],
    "image": ["asset", "mode", "crop"],
]

let alignments: [String: Alignment] = [
    "topLeading": .topLeading, "top": .top, "topTrailing": .topTrailing,
    "leading": .leading, "center": .center, "trailing": .trailing,
    "bottomLeading": .bottomLeading, "bottom": .bottom, "bottomTrailing": .bottomTrailing,
]

let unitPoints: [String: UnitPoint] = [
    "topLeading": .topLeading, "top": .top, "topTrailing": .topTrailing,
    "leading": .leading, "center": .center, "trailing": .trailing,
    "bottomLeading": .bottomLeading, "bottom": .bottom, "bottomTrailing": .bottomTrailing,
]

let weights: [String: Font.Weight] = [
    "ultraLight": .ultraLight, "thin": .thin, "light": .light, "regular": .regular, "medium": .medium,
    "semibold": .semibold, "bold": .bold, "heavy": .heavy, "black": .black,
]

let designs: [String: Font.Design] = ["default": .default, "serif": .serif, "rounded": .rounded, "monospaced": .monospaced]

struct StrokeSpec {
    var paint: AnyShapeStyle
    var width: CGFloat
    var cap: CGLineCap
}

struct UsedAction {
    var action: String
    var rowId: String?
}

final class Props {
    let type: String
    let path: String
    let dict: [String: JSON]
    var used: Set<String> = ["type"]

    init(type: String, path: String, dict: [String: JSON]) {
        self.type = type
        self.path = path
        self.dict = dict
    }

    func take(_ key: String) -> JSON? {
        used.insert(key)
        if case .null? = dict[key] { return nil }
        return dict[key]
    }

    func fail(_ key: String, _ expected: String, _ got: JSON) -> LookError {
        LookError("\(type).\(key) at \(path) expects \(expected), got \(got.brief)")
    }

    func num(_ key: String) throws -> CGFloat? {
        guard let v = take(key) else { return nil }
        guard case .num(let n) = v else { throw fail(key, "a number", v) }
        return CGFloat(n)
    }

    func bool(_ key: String) throws -> Bool? {
        guard let v = take(key) else { return nil }
        guard case .bool(let b) = v else { throw fail(key, "true or false", v) }
        return b
    }

    func string(_ key: String) throws -> String? {
        guard let v = take(key) else { return nil }
        guard case .str(let s) = v else { throw fail(key, "a string", v) }
        return s
    }

    func choice<T>(_ key: String, _ table: [String: T]) throws -> T? {
        guard let v = take(key) else { return nil }
        guard case .str(let s) = v, let hit = table[s] else {
            throw fail(key, "one of \(table.keys.sorted().joined(separator: ", "))", v)
        }
        return hit
    }

    func color(_ key: String) throws -> Color? {
        guard let v = take(key) else { return nil }
        return try parseColor(v, "\(type).\(key) at \(path)")
    }

    func finish(extra: [String] = []) throws {
        let allowed = (ownProps[type] ?? []) + commonProps + extra
        for k in dict.keys.sorted() where k != "type" && !allowed.contains(k) {
            throw LookError("unknown prop \"\(k)\" on \"\(type)\" at \(path) (allowed: \(allowed.joined(separator: ", ")))")
        }
    }
}

func parseColor(_ v: JSON, _ what: String) throws -> Color {
    guard case .str(let s) = v, let c = parseHex(s) else {
        throw LookError("\(what) expects a hex color like \"#RRGGBB\" or \"#RRGGBBAA\", got \(v.brief)")
    }
    return Color(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: c.3)
}

func parseUnitPoint(_ v: JSON?, _ fallback: UnitPoint, _ what: String) throws -> UnitPoint {
    guard let v else { return fallback }
    if case .str(let s) = v, let p = unitPoints[s] { return p }
    if case .arr(let a) = v, a.count == 2, case .num(let x) = a[0], case .num(let y) = a[1] { return UnitPoint(x: x, y: y) }
    throw LookError("\(what) expects a point name (\(unitPoints.keys.sorted().joined(separator: ", "))) or [x, y] in 0..1, got \(v.brief)")
}

func parsePaint(_ v: JSON, _ what: String) throws -> AnyShapeStyle {
    if case .str = v { return AnyShapeStyle(try parseColor(v, what)) }
    guard case .obj(let d) = v, case .str(let kind)? = d["gradient"] else {
        throw LookError("\(what) expects a hex color or a gradient object {\"gradient\": \"linear\" | \"radial\" | \"angular\", \"stops\": [...]}, got \(v.brief)")
    }
    let allowed: [String]
    switch kind {
    case "linear": allowed = ["gradient", "stops", "from", "to"]
    case "radial": allowed = ["gradient", "stops", "center", "startRadius", "endRadius"]
    case "angular": allowed = ["gradient", "stops", "center", "startAngle", "endAngle"]
    default: throw LookError("\(what) has unknown gradient \"\(kind)\" (allowed: linear, radial, angular)")
    }
    for k in d.keys.sorted() where !allowed.contains(k) {
        throw LookError("unknown key \"\(k)\" in \(kind) gradient for \(what) (allowed: \(allowed.joined(separator: ", ")))")
    }
    guard case .arr(let rawStops)? = d["stops"], rawStops.count >= 2 else {
        throw LookError("\(what) gradient needs \"stops\": a list of at least 2 colors")
    }
    var stops: [Gradient.Stop] = []
    for (i, s) in rawStops.enumerated() {
        if case .str = s {
            stops.append(.init(color: try parseColor(s, "\(what) stop \(i)"), location: CGFloat(i) / CGFloat(rawStops.count - 1)))
        } else if case .obj(let sd) = s, let c = sd["color"], case .num(let at)? = sd["at"] {
            stops.append(.init(color: try parseColor(c, "\(what) stop \(i)"), location: CGFloat(at)))
        } else {
            throw LookError("\(what) stop \(i) must be a hex color or {\"color\": hex, \"at\": 0..1}, got \(s.brief)")
        }
    }
    func n(_ k: String, _ fallback: CGFloat) throws -> CGFloat {
        guard let v = d[k] else { return fallback }
        guard case .num(let x) = v else { throw LookError("\(what) gradient \"\(k)\" expects a number, got \(v.brief)") }
        return CGFloat(x)
    }
    let g = Gradient(stops: stops)
    switch kind {
    case "linear":
        return AnyShapeStyle(LinearGradient(gradient: g, startPoint: try parseUnitPoint(d["from"], .top, "\(what) gradient from"), endPoint: try parseUnitPoint(d["to"], .bottom, "\(what) gradient to")))
    case "radial":
        return AnyShapeStyle(RadialGradient(gradient: g, center: try parseUnitPoint(d["center"], .center, "\(what) gradient center"), startRadius: try n("startRadius", 0), endRadius: try n("endRadius", 80)))
    default:
        return AnyShapeStyle(AngularGradient(gradient: g, center: try parseUnitPoint(d["center"], .center, "\(what) gradient center"), startAngle: .degrees(try n("startAngle", 0)), endAngle: .degrees(try n("endAngle", 360))))
    }
}

@MainActor
final class Builder {
    var actions: [UsedAction] = []
    var nodeCount = 0
    let fit = FitCollector()
    var assetsUsed: Set<String> = []
    var fontsUsed: Set<String> = []

    func children(_ p: Props) throws -> [AnyView] {
        guard let v = p.take("children") else { return [] }
        guard case .arr(let a) = v else { throw p.fail("children", "a list of nodes", v) }
        return try a.enumerated().map { try build($1, "\(p.path).children[\($0)]") }
    }

    func paint(_ p: Props, _ key: String) throws -> AnyShapeStyle? {
        guard let v = p.take(key) else { return nil }
        return try parsePaint(v, "\(p.type).\(key) at \(p.path)")
    }

    func stroke(_ p: Props) throws -> StrokeSpec? {
        guard let v = p.take("stroke") else { return nil }
        let what = "\(p.type).stroke at \(p.path)"
        guard case .obj(let d) = v else { throw LookError("\(what) expects {\"color\": hex or gradient, \"width\": number, \"cap\": \"butt\" | \"round\"}, got \(v.brief)") }
        for k in d.keys.sorted() where !["color", "width", "cap"].contains(k) {
            throw LookError("unknown key \"\(k)\" in \(what) (allowed: color, width, cap)")
        }
        guard let c = d["color"] else { throw LookError("\(what) needs \"color\"") }
        var width: CGFloat = 1
        if let w = d["width"] {
            guard case .num(let x) = w else { throw LookError("\(what) \"width\" expects a number, got \(w.brief)") }
            width = CGFloat(x)
        }
        var cap = CGLineCap.butt
        if let k = d["cap"] {
            guard case .str(let s) = k, ["butt", "round"].contains(s) else { throw LookError("\(what) \"cap\" expects \"butt\" or \"round\", got \(k.brief)") }
            cap = s == "round" ? .round : .butt
        }
        return StrokeSpec(paint: try parsePaint(c, "\(what) color"), width: width, cap: cap)
    }

    func shape<S: Shape>(_ filled: S, strokeShape: (CGFloat) -> AnyShape, _ p: Props) throws -> AnyView {
        let fill = try paint(p, "fill")
        let st = try stroke(p)
        let from = try p.num("trimFrom") ?? 0
        let to = try p.num("trimTo") ?? 1
        return AnyView(ZStack {
            if fill != nil || st == nil {
                filled.trim(from: from, to: to).fill(fill ?? AnyShapeStyle(Color.black))
            }
            if let st {
                strokeShape(st.width / 2).trim(from: from, to: to)
                    .stroke(st.paint, style: StrokeStyle(lineWidth: st.width, lineCap: st.cap, lineJoin: .round))
            }
        })
    }

    func insettable<S: InsettableShape>(_ s: S, _ p: Props) throws -> AnyView {
        try shape(s, strokeShape: { AnyShape(s.inset(by: $0)) }, p)
    }

    func build(_ node: JSON, _ path: String, isRoot: Bool = false) throws -> AnyView {
        guard case .obj(let d) = node else { throw LookError("\(path) must be a node object like {\"type\": \"text\", ...}, got \(node.brief)") }
        guard case .str(let type)? = d["type"] else { throw LookError("\(path) is missing \"type\"") }
        guard ownProps[type] != nil else {
            throw LookError("unknown node type \"\(type)\" at \(path) (allowed: \(nodeTypes.joined(separator: ", ")))")
        }
        nodeCount += 1
        let p = Props(type: type, path: path, dict: d)
        var view: AnyView

        switch type {
        case "vstack":
            let spacing = try p.num("spacing")
            let align = try p.choice("align", ["leading": HorizontalAlignment.leading, "center": .center, "trailing": .trailing]) ?? .center
            let kids = try children(p)
            view = AnyView(VStack(alignment: align, spacing: spacing) { ForEach(0..<kids.count, id: \.self) { kids[$0] } })
        case "hstack":
            let spacing = try p.num("spacing")
            let align = try p.choice("align", ["top": VerticalAlignment.top, "center": .center, "bottom": .bottom, "firstBaseline": .firstTextBaseline]) ?? .center
            let kids = try children(p)
            view = AnyView(HStack(alignment: align, spacing: spacing) { ForEach(0..<kids.count, id: \.self) { kids[$0] } })
        case "zstack":
            let align = try p.choice("align", alignments) ?? .center
            let kids = try children(p)
            view = AnyView(ZStack(alignment: align) { ForEach(0..<kids.count, id: \.self) { kids[$0] } })
        case "button":
            guard let action = try p.string("action"), !action.isEmpty else { throw LookError("button at \(path) needs \"action\": an action id string") }
            var rowId: String?
            if let r = p.take("rowId") {
                switch r {
                case .str(let s): rowId = s
                case .num(let n): rowId = formatNumber(n)
                default: throw p.fail("rowId", "a string or number", r)
                }
            }
            actions.append(UsedAction(action: action, rowId: rowId))
            let kids = try children(p)
            if kids.isEmpty { throw LookError("button at \(path) needs at least one child to show") }
            fit.leaf(path, "button", rowId.map { "\(action) \($0)" } ?? action)
            view = AnyView(ZStack { ForEach(0..<kids.count, id: \.self) { kids[$0] } }
                .reportGeometry(fit) { c, geo in c.frames[path] = geo.frame(in: .named("widget")) })
        case "spacer":
            view = AnyView(Spacer(minLength: try p.num("minLength")))
        case "text":
            guard let raw = p.take("value") else { throw LookError("text at \(path) needs \"value\"") }
            switch raw {
            case .str, .num, .bool: break
            default: throw p.fail("value", "a string or number", raw)
            }
            let size = try p.num("size") ?? 15
            var weightName = "regular"
            if case .str(let w)? = d["weight"] { weightName = w }
            let weight = try p.choice("weight", weights) ?? .regular
            let design = try p.choice("design", designs) ?? .default
            let italic = try p.bool("italic") == true
            let strike = try p.bool("strikethrough") == true
            let kerning = try p.num("kerning")
            var family: String?
            if let v = p.take("fontName") {
                guard case .str(let name) = v, fontFamilies.contains(where: { $0.name == name }) else {
                    throw p.fail("fontName", "one of \(fontFamilies.map { $0.name }.joined(separator: ", "))", v)
                }
                guard resolveFont(family: name, size: size, weight: weightName, italic: italic) != nil else {
                    throw LookError("font \"\(name)\" is not installed on this machine (text at \(path))")
                }
                family = name
                fontsUsed.insert(name)
            }
            let string = stringify(raw)
            let make: (String, CGFloat) -> Text = { value, scale in
                var t: Text
                if let family, let f = resolveFont(family: family, size: size * scale, weight: weightName, italic: italic) {
                    t = Text(value).font(Font(f as CTFont))
                } else {
                    t = Text(value).font(.system(size: size * scale, weight: weight, design: design))
                    if italic { t = t.italic() }
                }
                if strike { t = t.strikethrough() }
                if let kerning { t = t.kerning(kerning * scale) }
                return t
            }
            let color = try p.color("color") ?? .black
            let limit = try p.num("lineLimit")
            let minScale = try p.num("minScale") ?? 1
            let align = try p.choice("align", ["leading": TextAlignment.leading, "center": .center, "trailing": .trailing]) ?? .leading
            fit.leaf(path, "text", string)
            fit.texts.append(TextProbe(path: path, value: string, lineLimit: limit.map { Int($0) },
                                       smallest: { make($0, min(max(minScale, 0.01), 1)) }))
            view = AnyView(make(string, 1).foregroundStyle(color).lineLimit(limit.map { Int($0) }).minimumScaleFactor(minScale).multilineTextAlignment(align)
                .reportGeometry(fit) { c, geo in
                    c.frames[path] = geo.frame(in: .named("widget"))
                    c.localSizes[path] = geo.size
                })
        case "symbol":
            guard let name = try p.string("name") else { throw LookError("symbol at \(path) needs \"name\": an SF Symbol name") }
            guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
                throw LookError("unknown SF Symbol \"\(name)\" at \(path); use a real SF Symbols name such as \"plus\", \"flame.fill\", \"checkmark.circle.fill\"")
            }
            let size = try p.num("size") ?? 17
            let weight = try p.choice("weight", weights) ?? .regular
            let color = try p.color("color") ?? .black
            fit.leaf(path, "symbol", name)
            view = AnyView(Image(systemName: name).font(.system(size: size, weight: weight)).foregroundStyle(color)
                .reportGeometry(fit) { c, geo in c.frames[path] = geo.frame(in: .named("widget")) })
        case "image":
            guard let id = try p.string("asset") else { throw LookError("image at \(path) needs \"asset\": an asset id") }
            guard let asset = assetRegistry[id] else {
                let known = assetRegistry.keys.sorted()
                throw LookError("unknown image asset \"\(id)\" at \(path) (\(known.isEmpty ? "no image assets are available for this widget" : "available: " + known.joined(separator: ", ")))")
            }
            let fill = try p.choice("mode", ["fill": true, "fit": false]) ?? true
            var cg = asset.image
            if let v = p.take("crop") {
                guard case .arr(let a) = v, a.count == 4 else { throw p.fail("crop", "[x, y, width, height] with each value from 0 to 1", v) }
                var n: [CGFloat] = []
                for x in a {
                    guard case .num(let q) = x else { throw p.fail("crop", "[x, y, width, height] with each value from 0 to 1", v) }
                    n.append(CGFloat(q))
                }
                guard n[0] >= 0, n[1] >= 0, n[2] > 0, n[3] > 0, n[0] + n[2] <= 1.0001, n[1] + n[3] <= 1.0001 else {
                    throw LookError("image.crop at \(path) must stay inside the image: x, y, width, height from 0 to 1 with x + width <= 1 and y + height <= 1, got \(v.brief)")
                }
                let w = CGFloat(cg.width), h = CGFloat(cg.height)
                let rect = CGRect(x: n[0] * w, y: n[1] * h, width: n[2] * w, height: n[3] * h).integral
                guard let cropped = cg.cropping(to: rect), cropped.width > 0, cropped.height > 0 else {
                    throw LookError("image.crop at \(path) selects no pixels, got \(v.brief)")
                }
                cg = cropped
            }
            assetsUsed.insert(id)
            let img = Image(decorative: cg, scale: 1).resizable().interpolation(.high)
            view = fill
                ? AnyView(Color.clear.overlay { img.aspectRatio(contentMode: .fill) }.clipped())
                : AnyView(img.aspectRatio(contentMode: .fit))
        case "rect":
            let r = try p.num("cornerRadius") ?? 0
            view = try insettable(RoundedRectangle(cornerRadius: r, style: .continuous), p)
        case "circle":
            view = try insettable(Circle(), p)
        case "capsule":
            view = try insettable(Capsule(), p)
        case "ellipse":
            view = try insettable(Ellipse(), p)
        case "path":
            guard let dStr = try p.string("d") else { throw LookError("path at \(path) needs \"d\": SVG path data") }
            guard case .arr(let vb)? = p.take("viewBox"), vb.count == 4 else { throw LookError("path at \(path) needs \"viewBox\": [minX, minY, width, height]") }
            var nums: [CGFloat] = []
            for v in vb {
                guard case .num(let n) = v else { throw p.fail("viewBox", "four numbers", v) }
                nums.append(CGFloat(n))
            }
            let source: Path
            do { source = try parseSVGPath(dStr) } catch let e as LookError { throw LookError("path.d at \(path): \(e.message)") }
            let s = SVGShape(source: source, viewBox: CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3]))
            view = try shape(s, strokeShape: { _ in AnyShape(s) }, p)
        default:
            throw LookError("unknown node type \"\(type)\" at \(path)")
        }

        view = try applyCommon(view, p)
        if isRoot {
            _ = p.take("widgetBackground")
            view = AnyView(view.reportGeometry(fit) { c, geo in c.rootSize = geo.size })
        }
        try p.finish(extra: isRoot ? ["widgetBackground"] : [])
        return view
    }

    func length(_ v: JSON?, _ what: String, allowInfinity: Bool) throws -> CGFloat? {
        guard let v else { return nil }
        if case .num(let n) = v { return CGFloat(n) }
        if allowInfinity, case .str("infinity") = v { return .infinity }
        throw LookError("\(what) expects a number\(allowInfinity ? " or \"infinity\"" : " (\"infinity\" is only for maxWidth and maxHeight)"), got \(v.brief)")
    }

    func applyCommon(_ input: AnyView, _ p: Props) throws -> AnyView {
        var view = input
        var clipped = false
        let at = "at \(p.path)"

        if let r = try p.num("aspectRatio") { view = AnyView(view.aspectRatio(r, contentMode: .fit)) }

        if let v = p.take("padding") {
            switch v {
            case .num(let n): view = AnyView(view.padding(CGFloat(n)))
            case .obj(let d):
                let keys = ["top", "bottom", "leading", "trailing", "horizontal", "vertical"]
                var e: [String: CGFloat] = [:]
                for (k, x) in d {
                    guard keys.contains(k), case .num(let n) = x else {
                        throw LookError("\(p.type).padding \(at) expects a number or an object with numeric keys \(keys.joined(separator: ", ")); bad key \"\(k)\"")
                    }
                    e[k] = CGFloat(n)
                }
                view = AnyView(view.padding(EdgeInsets(
                    top: e["top"] ?? e["vertical"] ?? 0, leading: e["leading"] ?? e["horizontal"] ?? 0,
                    bottom: e["bottom"] ?? e["vertical"] ?? 0, trailing: e["trailing"] ?? e["horizontal"] ?? 0)))
            default: throw p.fail("padding", "a number or an object", v)
            }
        }

        if let v = p.take("frame") {
            guard case .obj(let d) = v else { throw p.fail("frame", "an object like {\"width\": 40, \"height\": 40}", v) }
            let keys = ["width", "height", "minWidth", "maxWidth", "minHeight", "maxHeight", "alignment"]
            for k in d.keys.sorted() where !keys.contains(k) {
                throw LookError("unknown key \"\(k)\" in \(p.type).frame \(at) (allowed: \(keys.joined(separator: ", ")))")
            }
            var alignment = Alignment.center
            if let a = d["alignment"] {
                guard case .str(let s) = a, let hit = alignments[s] else {
                    throw LookError("\(p.type).frame.alignment \(at) expects one of \(alignments.keys.sorted().joined(separator: ", ")), got \(a.brief)")
                }
                alignment = hit
            }
            let w = try length(d["width"], "\(p.type).frame.width \(at)", allowInfinity: false)
            let h = try length(d["height"], "\(p.type).frame.height \(at)", allowInfinity: false)
            let minW = try length(d["minWidth"], "\(p.type).frame.minWidth \(at)", allowInfinity: false)
            let minH = try length(d["minHeight"], "\(p.type).frame.minHeight \(at)", allowInfinity: false)
            let maxW = try length(d["maxWidth"], "\(p.type).frame.maxWidth \(at)", allowInfinity: true)
            let maxH = try length(d["maxHeight"], "\(p.type).frame.maxHeight \(at)", allowInfinity: true)
            for (k, x) in [("width", w), ("height", h), ("minWidth", minW), ("minHeight", minH), ("maxWidth", maxW), ("maxHeight", maxH)] {
                if let x, x < 0 || x.isNaN { throw LookError("\(p.type).frame.\(k) \(at) must not be negative, got \(formatNumber(Double(x)))") }
            }
            if w != nil || h != nil { view = AnyView(view.frame(width: w, height: h, alignment: alignment)) }
            if minW != nil || minH != nil || maxW != nil || maxH != nil {
                view = AnyView(view.frame(minWidth: minW, maxWidth: maxW, minHeight: minH, maxHeight: maxH, alignment: alignment))
            }
        }

        if let v = p.take("background") {
            if case .obj(let d) = v, d["type"] != nil {
                let bg = try build(v, "\(p.path).background")
                view = AnyView(view.background { bg })
            } else {
                view = AnyView(view.background(try parsePaint(v, "\(p.type).background \(at)")))
            }
        }

        if let v = p.take("overlay") {
            let ov = try build(v, "\(p.path).overlay")
            view = AnyView(view.overlay { ov })
        }

        if p.type != "rect", let r = try p.num("cornerRadius") {
            view = AnyView(view.clipShape(RoundedRectangle(cornerRadius: r, style: .continuous)))
            clipped = true
        }
        if let v = p.take("clip") {
            guard case .str(let s) = v, ["rect", "circle", "capsule", "ellipse"].contains(s) else {
                throw p.fail("clip", "one of rect, circle, capsule, ellipse", v)
            }
            switch s {
            case "circle": view = AnyView(view.clipShape(Circle()))
            case "capsule": view = AnyView(view.clipShape(Capsule()))
            case "ellipse": view = AnyView(view.clipShape(Ellipse()))
            default: view = AnyView(view.clipShape(Rectangle()))
            }
            clipped = true
        }
        if clipped {
            let path = p.path
            view = AnyView(view.reportGeometry(fit) { c, geo in c.clips[path] = geo.frame(in: .named("widget")) })
        }

        if let v = p.take("mask") {
            let m = try build(v, "\(p.path).mask")
            view = AnyView(view.mask { m })
        }

        if let o = try p.num("opacity") { view = AnyView(view.opacity(o)) }

        if let v = p.take("shadow") {
            guard case .obj(let d) = v else { throw p.fail("shadow", "an object like {\"color\": \"#00000040\", \"radius\": 4, \"x\": 0, \"y\": 2}", v) }
            for k in d.keys.sorted() where !["color", "radius", "x", "y"].contains(k) {
                throw LookError("unknown key \"\(k)\" in \(p.type).shadow \(at) (allowed: color, radius, x, y)")
            }
            func n(_ k: String, _ fallback: CGFloat) throws -> CGFloat {
                guard let x = d[k] else { return fallback }
                guard case .num(let y) = x else { throw LookError("\(p.type).shadow.\(k) \(at) expects a number, got \(x.brief)") }
                return CGFloat(y)
            }
            let color = try d["color"].map { try parseColor($0, "\(p.type).shadow.color \(at)") } ?? Color.black.opacity(0.33)
            view = AnyView(view.shadow(color: color, radius: try n("radius", 4), x: try n("x", 0), y: try n("y", 0)))
        }

        if let b = try p.num("blur") { view = AnyView(view.blur(radius: b)) }

        if let v = p.take("scale") {
            switch v {
            case .num(let n): view = AnyView(view.scaleEffect(CGFloat(n)))
            case .obj(let d):
                guard case .num(let x)? = d["x"] ?? .num(1), case .num(let y)? = d["y"] ?? .num(1), d.keys.allSatisfy({ $0 == "x" || $0 == "y" }) else {
                    throw p.fail("scale", "a number or {\"x\": number, \"y\": number}", v)
                }
                view = AnyView(view.scaleEffect(x: CGFloat(x), y: CGFloat(y)))
            default: throw p.fail("scale", "a number or {\"x\": number, \"y\": number}", v)
            }
        }

        if let r = try p.num("rotation") { view = AnyView(view.rotationEffect(.degrees(r))) }

        if let v = p.take("offset") {
            guard case .obj(let d) = v, case .num(let x)? = d["x"] ?? .num(0), case .num(let y)? = d["y"] ?? .num(0), d.keys.allSatisfy({ $0 == "x" || $0 == "y" }) else {
                throw p.fail("offset", "{\"x\": number, \"y\": number}", v)
            }
            view = AnyView(view.offset(x: CGFloat(x), y: CGFloat(y)))
        }

        return view
    }
}
