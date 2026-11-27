import CoreGraphics
import Foundation
import Spec

/// The look vocabulary as one registry: every node type with its own props and how it reads them, the
/// common props every node takes in the order the renderer applies them, and the names a look may use
/// beyond the grammar. Unknown types and props fail with the allowed lists drawn from here, and
/// Reference/look.md teaches the same lists; a test fails if its tables and this registry disagree.
package enum Vocabulary {
    /// The named fonts. iOS and macOS both ship every family on this list but the last two, which the engine
    /// bundles (`BundledFonts`); `namedFontShipsHere` checks that each one draws.
    package static let fonts: [(name: String, style: String)] = [
        ("Bradley Hand", "handwriting, a quick pen"), ("Noteworthy", "handwriting, neat notes"),
        ("Marker Felt", "handwriting, felt marker"), ("Chalkduster", "display, chalk on a blackboard"),
        ("Snell Roundhand", "script, formal calligraphy"), ("American Typewriter", "typewriter"),
        ("Rockwell", "slab serif"), ("DIN Condensed", "condensed bold signage"),
        ("Avenir Next Condensed", "condensed, clean"), ("Futura", "geometric poster type"),
        ("Copperplate", "engraved small capitals"), ("Didot", "high contrast fashion serif"),
        ("Bricolage Grotesque Display", "chunky condensed grotesque for big numbers and titles"),
        ("Bricolage Grotesque Key", "bold grotesque for labels and buttons"),
    ]

    static let nodes: [NodeType] = [
        NodeType("vstack", ["spacing", "align", "children"]) { (props, parser) throws(Diagnostic) in
            .vstack(
                spacing: try props.number("spacing", in: spacing),
                align: try props.choice("align", HAlign.self) ?? .center,
                children: try parser.children(of: props))
        },
        NodeType("hstack", ["spacing", "align", "children"]) { (props, parser) throws(Diagnostic) in
            .hstack(
                spacing: try props.number("spacing", in: spacing),
                align: try props.choice("align", VAlign.self) ?? .center,
                children: try parser.children(of: props))
        },
        NodeType("zstack", ["align", "children"]) { (props, parser) throws(Diagnostic) in
            .zstack(align: try props.choice("align", Align.self) ?? .center, children: try parser.children(of: props))
        },
        NodeType("spacer", ["minLength"]) { (props, _) throws(Diagnostic) in
            .spacer(minLength: try props.number("minLength", in: 0...Limits.length))
        },
        NodeType(
            "text",
            [
                "value", "size", "weight", "design", "italic", "color", "lineLimit", "minScale", "align",
                "strikethrough",
                "kerning", "fontName",
            ]
        ) { (props, _) throws(Diagnostic) in
            guard let value = try props.read("value", Value.text) else {
                throw props.error("needs \"value\": the string or number to show")
            }
            let font: Typeface =
                if let name = try props.read("fontName", fontName) {
                    .named(name)
                } else {
                    .system(try props.choice("design", Design.self) ?? .default)
                }
            return .text(
                TextRun(
                    value: value, size: try props.number("size", in: Limits.fontSize) ?? 15,
                    weight: try props.choice("weight", Weight.self) ?? .regular, font: font,
                    italic: try props.bool("italic") ?? false, color: try props.color("color") ?? black,
                    lineLimit: try props.read("lineLimit") { (value, name) throws(Diagnostic) in
                        try Value.whole(value, name, in: 1...50)
                    },
                    minScale: try props.number("minScale", in: 0.01...1) ?? 1,
                    align: try props.choice("align", HAlign.self) ?? .leading,
                    strikethrough: try props.bool("strikethrough") ?? false,
                    kerning: try props.number("kerning", in: -20...50)))
        },
        NodeType("symbol", ["name", "size", "weight", "color"]) { (props, _) throws(Diagnostic) in
            guard let name = try props.read("name", symbolName) else {
                throw props.error(
                    "needs \"name\": an SF Symbol name such as \"plus\", \"flame.fill\", or \"checkmark.circle.fill\"")
            }
            return .symbol(
                Symbol(
                    name: name, size: try props.number("size", in: Limits.fontSize) ?? 17,
                    weight: try props.choice("weight", Weight.self) ?? .regular,
                    color: try props.color("color") ?? black))
        },
        NodeType("rect", ["cornerRadius"] + shapeProps) { (props, _) throws(Diagnostic) in
            .shape(
                .rect(cornerRadius: try props.number("cornerRadius", in: 0...Limits.length) ?? 0), try shapePaint(props)
            )
        },
        NodeType("circle", shapeProps) { (props, _) throws(Diagnostic) in .shape(.circle, try shapePaint(props)) },
        NodeType("capsule", shapeProps) { (props, _) throws(Diagnostic) in .shape(.capsule, try shapePaint(props)) },
        NodeType("ellipse", shapeProps) { (props, _) throws(Diagnostic) in .shape(.ellipse, try shapePaint(props)) },
        NodeType("path", ["d", "viewBox"] + shapeProps) { (props, _) throws(Diagnostic) in
            guard let d = try props.read("d", pathData) else {
                throw props.error("needs \"d\": SVG path data like \"M 0 0 L 10 10\"")
            }
            guard let viewBox = try props.read("viewBox", viewBox) else {
                throw props.error(
                    "needs \"viewBox\": [minX, minY, width, height], the area of \"d\" to fit in the frame")
            }
            return .shape(.path(d, viewBox: viewBox), try shapePaint(props))
        },
        NodeType("image", ["asset", "mode", "crop", "saturation", "brightness", "contrast", "tint"]) {
            (props, parser) throws(Diagnostic) in
            .image(try parser.picture(props))
        },
        NodeType("button", ["action", "rowId", "day", "children"]) { (props, parser) throws(Diagnostic) in
            let press = try parser.press(props)
            let children = try parser.children(of: props, place: .button)
            guard !children.isEmpty else {
                throw props.error("needs \"children\" to show; a button looks exactly like its children")
            }
            // A day the store would refuse today still draws, untappable, so a week strip stays valid.
            guard let press else { return .zstack(align: .center, children: children) }
            return .button(press, children: children)
        },
    ]

    /// Applied in this order whatever order a look writes them. A node's own prop of the same name wins, so
    /// on a `rect` `cornerRadius` rounds the shape instead of clipping it.
    static let common: [CommonProp] = [
        CommonProp("aspectRatio") { (props, _, style) throws(Diagnostic) in
            style.aspectRatio = try props.number("aspectRatio", in: 0.01...100)
        },
        CommonProp("padding") { (props, _, style) throws(Diagnostic) in
            style.padding = try props.read("padding", Value.padding)
        },
        CommonProp("frame") { (props, _, style) throws(Diagnostic) in
            style.frame = try props.read("frame", Value.frame)
        },
        CommonProp("background") { (props, parser, style) throws(Diagnostic) in
            style.background = try parser.layer(props, "background", place: props.place)
        },
        CommonProp("overlay") { (props, parser, style) throws(Diagnostic) in
            style.overlay = try parser.layer(props, "overlay", place: props.place)
        },
        CommonProp("cornerRadius") { (props, _, style) throws(Diagnostic) in
            guard let radius = try props.number("cornerRadius", in: 0...Limits.length) else { return }
            guard props["clip"] == nil else { throw props.error("has both \"cornerRadius\" and \"clip\"; use one") }
            style.clip = .rounded(radius)
        },
        CommonProp("clip") { (props, _, style) throws(Diagnostic) in
            switch try props.choice("clip", ClipShape.self) {
            case .rect?: style.clip = .rect
            case .circle?: style.clip = .circle
            case .capsule?: style.clip = .capsule
            case .ellipse?: style.clip = .ellipse
            case nil: break
            }
        },
        CommonProp("mask") { (props, parser, style) throws(Diagnostic) in
            style.mask = try parser.layer(
                props, "mask", place: .untappable("a mask only shapes what shows, so it cannot hold a button"))
        },
        CommonProp("opacity") { (props, _, style) throws(Diagnostic) in
            style.opacity = try props.number("opacity", in: 0...1)
        },
        CommonProp("shadow") { (props, _, style) throws(Diagnostic) in
            style.shadow = try props.read("shadow", Value.shadow)
        },
        CommonProp("blur") { (props, _, style) throws(Diagnostic) in
            style.blur = try props.number("blur", in: 0...Limits.blur)
        },
        CommonProp("scale") { (props, _, style) throws(Diagnostic) in
            style.scale = try props.read("scale", Value.scale)
        },
        CommonProp("rotation") { (props, _, style) throws(Diagnostic) in
            style.rotation = try props.number("rotation", in: -Limits.degrees...Limits.degrees)
        },
        CommonProp("offset") { (props, _, style) throws(Diagnostic) in
            style.offset = try props.read("offset", Value.offset)
        },
        CommonProp("blend") { (props, _, style) throws(Diagnostic) in
            style.blend = try props.choice("blend", Blend.self)
        },
        CommonProp("accent") { (props, _, style) throws(Diagnostic) in
            style.accent = try props.bool("accent") ?? false
        },
    ]

    /// Props only the root node takes.
    static let rootProps = ["widgetBackground"]

    static func node(named name: String) -> NodeType? { nodes.first { $0.name == name } }

    static var typeChoices: String { "(types: \(nodes.map(\.name).joined(separator: ", ")))" }

    private static let shapeProps = ["fill", "stroke", "trimFrom", "trimTo"]
    private static let spacing = -Limits.padding...Limits.padding
    private static let black = ColorPair(RGBA(r: 0, g: 0, b: 0, a: 1))

    private static func shapePaint(_ props: Props) throws(Diagnostic) -> ShapePaint {
        let fill = try props.fill("fill")
        let stroke = try props.read("stroke", Value.stroke)
        let from = try props.number("trimFrom", in: 0...1) ?? 0
        let to = try props.number("trimTo", in: 0...1) ?? 1
        guard from <= to else { throw props.error("\"trimFrom\" is larger than \"trimTo\"") }
        return ShapePaint(fill: fill ?? (stroke == nil ? .color(black) : nil), stroke: stroke, trim: from...to)
    }

    private static func fontName(_ value: JSONValue, _ name: String) throws(Diagnostic) -> String {
        guard case .string(let raw) = value, fonts.contains(where: { $0.name == raw }) else {
            throw Diagnostic(
                "\"\(name)\" must be one of \(fonts.map(\.name).joined(separator: ", ")), not \(Value.describe(value))")
        }
        // A static proof draws without an engine, so a look that names a bundled font registers it here.
        if BundledFonts.families.contains(raw) { BundledFonts.register() }
        return raw
    }

    private static func symbolName(_ value: JSONValue, _ name: String) throws(Diagnostic) -> String {
        let raw = try Value.string(value, name, maxLength: 100)
        guard Symbols.exist(raw) else {
            throw Diagnostic(
                "\"\(name)\" is \(Diagnostic.quote(raw)), which is not an SF Symbol here; use a real name such as \"plus\", \"flame.fill\", or \"checkmark.circle.fill\""
            )
        }
        return raw
    }

    private static func pathData(_ value: JSONValue, _ name: String) throws(Diagnostic) -> PathData {
        try PathData.parse(try Value.string(value, name, maxLength: Limits.pathLength))
    }

    private static func viewBox(_ value: JSONValue, _ name: String) throws(Diagnostic) -> CGRect {
        let request = "\"\(name)\" must be [minX, minY, width, height] with width and height above 0"
        guard case .array(let items) = value, items.count == 4 else {
            throw Diagnostic("\(request), not \(Value.describe(value))")
        }
        var parts: [Double] = []
        for item in items {
            guard case .number(let number) = item, abs(number) <= 100_000 else {
                throw Diagnostic("\(request), not \(Value.describe(value))")
            }
            parts.append(number)
        }
        guard parts[2] > 0, parts[3] > 0 else { throw Diagnostic("\(request), not \(Value.describe(value))") }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}

/// A node type: its own props, and how it reads them into a `Kind`.
struct NodeType: Sendable {
    let name: String
    let props: [String]
    let read: @Sendable (Props, inout TreeParser) throws(Diagnostic) -> Kind

    init(
        _ name: String, _ props: [String],
        _ read: @escaping @Sendable (Props, inout TreeParser) throws(Diagnostic) -> Kind
    ) {
        self.name = name
        self.props = props
        self.read = read
    }
}

/// A prop every node takes, and how it writes into the node's `Style`.
struct CommonProp: Sendable {
    let name: String
    let read: @Sendable (Props, inout TreeParser, inout Style) throws(Diagnostic) -> Void

    init(_ name: String, _ read: @escaping @Sendable (Props, inout TreeParser, inout Style) throws(Diagnostic) -> Void)
    {
        self.name = name
        self.read = read
    }
}

/// The validator's walk over one tree: node count, the taps in tree order, and the references a tree may
/// make, resolved against `bindings`.
struct TreeParser {
    let bindings: Bindings
    private(set) var taps: [Tap] = []
    private var count = 0

    init(bindings: Bindings) { self.bindings = bindings }

    mutating func node(_ value: JSONValue, at path: String, depth: Int, place: Place, extra: [String] = [])
        throws(Diagnostic) -> Node
    {
        let (type, props, common) = try header(value, at: path, depth: depth, place: place, extra: extra)
        let kind = try type.read(props, &self)
        var style = Style()
        for prop in common { try prop.read(props, &self, &style) }
        return Node(kind: kind, style: style, path: path)
    }

    /// Everything `node` checks before it reads props. Kept out of `node` so the frame that recurses into
    /// children stays small: the error lines built here would otherwise take stack space at every level.
    @inline(never)
    private mutating func header(_ value: JSONValue, at path: String, depth: Int, place: Place, extra: [String])
        throws(Diagnostic) -> (NodeType, Props, [CommonProp])
    {
        let label = "node at \(path)"
        guard case .object(let members) = value else {
            throw Diagnostic(
                "must be a node object like {\"type\": \"text\", \"value\": \"Hi\"}, not \(Value.describe(value))",
                at: [label])
        }
        guard case .string(let name)? = members["type"] else {
            throw Diagnostic("needs \"type\" \(Vocabulary.typeChoices)", at: [label])
        }
        guard let type = Vocabulary.node(named: name) else {
            throw Diagnostic("unknown type \(Diagnostic.quote(name)) \(Vocabulary.typeChoices)", at: [label])
        }
        count += 1
        guard count <= Limits.nodes else {
            throw Diagnostic(
                "the tree has more than \(Limits.nodes) nodes; draw fewer, for example fewer rows or grid cells",
                at: [label])
        }
        guard depth <= Limits.depth else {
            throw Diagnostic("is nested more than \(Limits.depth) levels deep; flatten the tree", at: [label])
        }
        let props = Props(type: name, path: path, depth: depth, place: place, members: members)
        let common = Vocabulary.common.filter { !type.props.contains($0.name) }
        if let unknown = props.keys.first(where: { key in
            !type.props.contains(key) && !common.contains { $0.name == key } && !extra.contains(key)
        }) {
            let only = extra.isEmpty ? "" : "; root only: \(extra.joined(separator: ", "))"
            throw props.error(
                "unknown prop \(Diagnostic.quote(unknown)) (\(name) props: \(type.props.joined(separator: ", ")); common props: \(common.map(\.name).joined(separator: ", "))\(only))"
            )
        }
        return (type, props, common)
    }

    /// `children`, flattened: nested lists are spliced in place, and `null`, `false`, `0`, and `""` are
    /// skipped, so `list.map(...)` and `test && node` both work. The children sit where their parent sits
    /// unless `place` says otherwise, as it does for a button's.
    mutating func children(of props: Props, place: Place? = nil) throws(Diagnostic) -> [Node] {
        guard let value = props["children"] else { return [] }
        guard case .array(let items) = value else {
            throw props.error("\"children\" must be a list of nodes, not \(Value.describe(value))")
        }
        var flat: [JSONValue] = []
        Self.flatten(items, into: &flat)
        var nodes: [Node] = []
        for (index, item) in flat.enumerated() {
            nodes.append(
                try node(
                    item, at: "\(props.path).children[\(index)]", depth: props.depth + 1, place: place ?? props.place))
        }
        return nodes
    }

    /// A fill, or a whole node when the value has a `type`.
    mutating func layer(_ props: Props, _ key: String, place: Place) throws(Diagnostic) -> Layer? {
        guard let value = props[key] else { return nil }
        if case .object(let members) = value, members["type"] != nil {
            return .node(try node(value, at: "\(props.path).\(key)", depth: props.depth + 1, place: place))
        }
        if case .object(let members) = value, members["gradient"] == nil, members["light"] == nil,
            members["dark"] == nil
        {
            throw props.error(
                "\"\(key)\" must be a hex color, a gradient, or a node with a \"type\", not an object without either")
        }
        return try props.fill(key).map(Layer.fill)
    }

    /// Nil for a button whose well-formed `day` is outside `loggableDays` of the render's day: a day after
    /// today in a week strip, or a row's day more than a year back. It draws without a tap until its day
    /// comes into range, and the store checks the day again on every tap.
    mutating func press(_ props: Props) throws(Diagnostic) -> Press? {
        switch props.place {
        case .tree: break
        case .button: throw props.error("is inside another button; a button cannot hold a button")
        case .untappable(let reason): throw props.error(reason)
        }
        let spec = bindings.spec
        let actions = Value.choices(
            "actions", spec.actions.map(\.id.raw), none: "this widget has no actions, so it has no buttons")
        guard
            let raw = try props.read(
                "action", { (value, name) throws(Diagnostic) in try Value.string(value, name, maxLength: 64) })
        else {
            throw props.error("needs \"action\": the id of the action a tap runs \(actions)")
        }
        guard let action = spec.action(named: raw) else {
            throw props.error("no action \(Diagnostic.quote(raw)) \(actions)")
        }
        let row = try props.read("rowId") { (value, name) throws(Diagnostic) in
            try Value.string(value, name, maxLength: 64)
        }
        let effect = action.effect
        switch (effect.rowUse, row) {
        case (.never, _?):
            throw props.error("action \(Diagnostic.quote(raw)) adds a new row, so it takes no \"rowId\"")
        case (.required, nil):
            throw props.error(
                "action \(Diagnostic.quote(raw)) needs \"rowId\": the id of the row \(Self.rowRole(effect))")
        case (_, let id?) where bindings.rows[effect.table]?.contains(id) != true:
            let sources = spec.queries.filter { query in
                switch query.shape {
                case .latest(let table, _, _), .list(let table, _, _, _, _): table.id == effect.table
                default: false
                }
            }
            let choices = Value.choices(
                "\(effect.table.raw) rows come from", sources.map(\.id.raw),
                none: "no query returns rows of \(effect.table.raw); add a latest or list query on it")
            throw props.error(
                "\"rowId\" \(Diagnostic.quote(id)) is not the id of a row the look received \(choices); use a row's id field"
            )
        default:
            break
        }
        let day = try props.read("day") { (value, name) throws(Diagnostic) in
            try Value.string(value, name, maxLength: 10)
        }
        switch (effect.needsDay, day) {
        case (false, _?):
            throw props.error(
                "action \(Diagnostic.quote(raw)) does not write to a chosen day, so it takes no \"day\"; use an insertOn action to add a row on another day"
            )
        case (true, nil):
            throw props.error(
                "action \(Diagnostic.quote(raw)) needs \"day\": the date it adds a row on, like \"\(bindings.today.iso)\" (take dates from ctx.today or a daily entry)"
            )
        case (true, let iso?):
            guard let parsed = Day(iso: iso) else {
                throw props.error(
                    "\"day\" must be a date as \"YYYY-MM-DD\", like \"\(bindings.today.iso)\", not \(Diagnostic.quote(iso))"
                )
            }
            guard Spec.Effect.loggableDays(from: bindings.today).contains(parsed) else { return nil }
        case (false, nil):
            break
        }
        let tap = Tap(
            widget: bindings.widget.rawValue, revision: bindings.revision, action: raw, row: row, day: day)
        taps.append(tap)
        if case .form = effect { return .form(tap) }
        return .run(tap)
    }

    mutating func picture(_ props: Props) throws(Diagnostic) -> Picture {
        let spec = bindings.spec
        let assets = Value.choices(
            "assets", spec.assets.map(\.id.raw), none: "this widget has no image assets, so it cannot use image")
        guard
            let raw = try props.read(
                "asset", { (value, name) throws(Diagnostic) in try Value.string(value, name, maxLength: 64) })
        else {
            throw props.error("needs \"asset\": the id of an image asset \(assets)")
        }
        guard let asset = spec.asset(named: raw) else {
            throw props.error("no asset \(Diagnostic.quote(raw)) \(assets)")
        }
        let crop = try props.read("crop", Value.crop)
        let pixels = CGSize(
            width: bindings.size.width * bindings.pixelScale, height: bindings.size.height * bindings.pixelScale)
        let image: DecodedImage
        do throws(AssetImages.Failure) {
            image = try bindings.images.image(asset.id, crop: crop, maxPixels: pixels)
        } catch {
            switch error {
            case .unreadable:
                throw props.error("asset \(Diagnostic.quote(raw)) has no readable image; send the image again")
            case .overBudget:
                throw props.error(
                    "images decode to more than 1.5 megapixels in this render; draw fewer images, or fewer distinct crops of one asset, since each crop decodes again at the widget's size",
                    kind: .overImageBudget)
            }
        }
        return Picture(
            image: image, mode: try props.choice("mode", ImageMode.self) ?? .fill,
            adjust: ColorAdjust(
                saturation: try props.number("saturation", in: 0...4),
                brightness: try props.number("brightness", in: -1...1),
                contrast: try props.number("contrast", in: 0...4)),
            tint: try props.choice("tint", ImageTint.self) ?? .desaturated)
    }

    private static func flatten(_ items: [JSONValue], into flat: inout [JSONValue]) {
        for item in items {
            switch item {
            case .array(let inner): flatten(inner, into: &flat)
            case .null, .bool(false), .number(0), .string(""): continue
            default: flat.append(item)
            }
        }
    }

    private static func rowRole(_ effect: Spec.Effect) -> String {
        switch effect {
        case .delete: "it deletes"
        case .toggle(let field): "whose \"\(field.id.raw)\" it flips"
        case .set(let value): "whose \"\(value.field.id.raw)\" it sets"
        case .insert, .insertOn, .form: "it is about"
        }
    }
}
