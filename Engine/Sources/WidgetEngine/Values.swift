import CoreGraphics
import Foundation
import Spec

/// One node object of the tree, read prop by prop. Knows where the node sits, so every error names it:
/// `text at root.children[0]: "color" must be a hex color like "#RRGGBB" or "#RRGGBBAA", not the string "red"`.
struct Props {
    let type: String
    let path: String
    let depth: Int
    let place: Place
    private let members: [String: JSONValue]

    init(type: String, path: String, depth: Int, place: Place, members: [String: JSONValue]) {
        self.type = type
        self.path = path
        self.depth = depth
        self.place = place
        self.members = members.filter { $0.key != "type" && $0.value != .null }
    }

    var keys: [String] { members.keys.sorted() }

    subscript(key: String) -> JSONValue? { members[key] }

    var label: String { "\(type) at \(path)" }

    func error(_ message: String, kind: Diagnostic.Kind = .mistake) -> Diagnostic {
        Diagnostic(message, at: [label], kind: kind)
    }

    /// Parses one prop with a value reader, naming this node in any error. Nil when the prop is absent.
    func read<T>(_ key: String, _ parse: (JSONValue, String) throws(Diagnostic) -> T) throws(Diagnostic) -> T? {
        guard let value = members[key] else { return nil }
        do throws(Diagnostic) {
            return try parse(value, key)
        } catch {
            throw error.within(label)
        }
    }

    func number(_ key: String, in range: ClosedRange<Double>) throws(Diagnostic) -> Double? {
        try read(key) { (value, name) throws(Diagnostic) in try Value.number(value, name, in: range) }
    }

    func choice<E: RawRepresentable & CaseIterable>(_ key: String, _ type: E.Type) throws(Diagnostic) -> E?
    where E.RawValue == String {
        try read(key) { (value, name) throws(Diagnostic) in try Value.choice(value, name, type) }
    }

    func bool(_ key: String) throws(Diagnostic) -> Bool? { try read(key, Value.bool) }
    func color(_ key: String) throws(Diagnostic) -> ColorPair? { try read(key, Value.color) }
    func fill(_ key: String) throws(Diagnostic) -> Fill? { try read(key, Value.fill) }
}

/// Where a node sits, which decides whether it may hold a button.
enum Place {
    case tree
    case button
    /// A mask or the widget background: drawn, or used as a shape, but never tappable.
    case untappable(String)
}

/// Readers for prop values. Each throws a message that names the prop and shows what would be valid;
/// `Props.read` adds the node.
enum Value {
    static func number(_ value: JSONValue, _ name: String, in range: ClosedRange<Double>) throws(Diagnostic) -> Double {
        guard case .number(let number) = value, range.contains(number) else {
            throw Diagnostic(
                "\"\(name)\" must be a number from \(format(range.lowerBound)) to \(format(range.upperBound)), not \(describe(value))"
            )
        }
        return number
    }

    static func whole(_ value: JSONValue, _ name: String, in range: ClosedRange<Int>) throws(Diagnostic) -> Int {
        guard case .number(let number) = value, let whole = Int(exactly: number), range.contains(whole) else {
            throw Diagnostic(
                "\"\(name)\" must be a whole number from \(range.lowerBound) to \(range.upperBound), not \(describe(value))"
            )
        }
        return whole
    }

    static func bool(_ value: JSONValue, _ name: String) throws(Diagnostic) -> Bool {
        guard case .bool(let flag) = value else {
            throw Diagnostic("\"\(name)\" must be true or false, not \(describe(value))")
        }
        return flag
    }

    static func string(_ value: JSONValue, _ name: String, maxLength: Int) throws(Diagnostic) -> String {
        guard case .string(let text) = value else {
            throw Diagnostic("\"\(name)\" must be a string, not \(describe(value))")
        }
        guard text.count <= maxLength else {
            throw Diagnostic("\"\(name)\" is \(text.count) characters; keep it to \(maxLength) or fewer")
        }
        return text
    }

    /// A string or a number, as text shows it. Whole numbers show without a fraction.
    static func text(_ value: JSONValue, _ name: String) throws(Diagnostic) -> String {
        switch value {
        case .number(let number): return format(number)
        case .string: return try string(value, name, maxLength: Limits.textLength)
        default: throw Diagnostic("\"\(name)\" must be a string or a number, not \(describe(value))")
        }
    }

    static func choice<E: RawRepresentable & CaseIterable>(_ value: JSONValue, _ name: String, _: E.Type)
        throws(Diagnostic) -> E
    where E.RawValue == String {
        guard case .string(let raw) = value, let choice = E(rawValue: raw) else {
            throw Diagnostic(
                "\"\(name)\" must be one of \(E.allCases.map(\.rawValue).joined(separator: ", ")), not \(describe(value))"
            )
        }
        return choice
    }

    /// A hex color, or `{ light, dark }` with a hex color for each color scheme.
    static func color(_ value: JSONValue, _ name: String) throws(Diagnostic) -> ColorPair {
        if case .object = value {
            let pair = try object(value, name, keys: ["light", "dark"])
            guard let light = pair["light"], let dark = pair["dark"] else {
                throw Diagnostic("\"\(name)\" needs both \"light\" and \"dark\"")
            }
            return ColorPair(light: try hexColor(light, "\(name).light"), dark: try hexColor(dark, "\(name).dark"))
        }
        return ColorPair(try hexColor(value, name))
    }

    private static func hexColor(_ value: JSONValue, _ name: String) throws(Diagnostic) -> RGBA {
        guard case .string(let text) = value, let color = hex(text) else {
            throw Diagnostic(
                "\"\(name)\" must be a hex color like \"#RRGGBB\" or \"#RRGGBBAA\", not \(describe(value))")
        }
        return color
    }

    /// A color or a gradient.
    static func fill(_ value: JSONValue, _ name: String) throws(Diagnostic) -> Fill {
        if case .string = value { return .color(try color(value, name)) }
        if case .object(let members) = value, members["gradient"] == nil,
            members["light"] != nil || members["dark"] != nil
        {
            return .color(try color(value, name))
        }
        guard case .object(let members) = value, case .string(let kind)? = members["gradient"] else {
            throw Diagnostic(
                "\"\(name)\" must be a hex color like \"#RRGGBB\" or a gradient like {\"gradient\": \"linear\", \"stops\": [\"#1B2A41\", \"#0C1821\"]}, not \(describe(value))"
            )
        }
        let keys: [String]
        switch kind {
        case "linear": keys = ["gradient", "stops", "from", "to"]
        case "radial": keys = ["gradient", "stops", "center", "startRadius", "endRadius"]
        case "angular": keys = ["gradient", "stops", "center", "startAngle", "endAngle"]
        default:
            throw Diagnostic(
                "\"\(name).gradient\" must be one of linear, radial, angular, not \(describe(.string(kind)))")
        }
        let gradient = try object(value, name, keys: keys)
        let stops = try stops(gradient["stops"], "\(name).stops")
        func point(_ key: String, _ fallback: Align) throws(Diagnostic) -> CGPoint {
            try gradient[key].map { (value) throws(Diagnostic) in try Value.point(value, "\(name).\(key)") }
                ?? fallback.unitPoint
        }
        func measure(_ key: String, _ range: ClosedRange<Double>, _ fallback: Double) throws(Diagnostic) -> Double {
            try gradient[key].map { (value) throws(Diagnostic) in try number(value, "\(name).\(key)", in: range) }
                ?? fallback
        }
        switch kind {
        case "linear":
            return .linear(stops: stops, from: try point("from", .top), to: try point("to", .bottom))
        case "radial":
            return .radial(
                stops: stops, center: try point("center", .center),
                startRadius: try measure("startRadius", 0...Limits.length, 0),
                endRadius: try measure("endRadius", 0...Limits.length, 80))
        default:
            return .angular(
                stops: stops, center: try point("center", .center),
                startAngle: try measure("startAngle", -Limits.degrees...Limits.degrees, 0),
                endAngle: try measure("endAngle", -Limits.degrees...Limits.degrees, 360))
        }
    }

    /// A list of colors spaced evenly, or of `{ color, at }`. A color may be a `{ light, dark }` pair.
    private static func stops(_ value: JSONValue?, _ name: String) throws(Diagnostic) -> [Stop] {
        let request = "\"\(name)\" must be a list of 2 to 16 colors, or of {\"color\": \"#RRGGBB\", \"at\": 0 to 1}"
        guard case .array(let items)? = value, (2...16).contains(items.count) else {
            throw Diagnostic("\(request), not \(value.map(describe) ?? "missing")")
        }
        var stops: [Stop] = []
        for (index, item) in items.enumerated() {
            let itemName = "\(name)[\(index)]"
            if case .object(let members) = item, members["light"] == nil, members["dark"] == nil {
                let stop = try object(item, itemName, keys: ["color", "at"])
                guard let color = stop["color"], let at = stop["at"] else {
                    throw Diagnostic("\"\(itemName)\" needs both \"color\" and \"at\"")
                }
                stops.append(
                    Stop(
                        color: try self.color(color, "\(itemName).color"),
                        location: try number(at, "\(itemName).at", in: 0...1)))
            } else {
                stops.append(Stop(color: try color(item, itemName), location: Double(index) / Double(items.count - 1)))
            }
        }
        // Gradients need ascending locations; equal locations keep their written order, for hard edges.
        return stops.enumerated().sorted { ($0.element.location, $0.offset) < ($1.element.location, $1.offset) }
            .map(\.element)
    }

    /// An alignment name, or `[x, y]` in unit coordinates.
    static func point(_ value: JSONValue, _ name: String) throws(Diagnostic) -> CGPoint {
        if case .string(let raw) = value, let align = Align(rawValue: raw) { return align.unitPoint }
        if case .array(let pair) = value, pair.count == 2, case .number(let x) = pair[0], case .number(let y) = pair[1],
            (0...1).contains(x), (0...1).contains(y)
        {
            return CGPoint(x: x, y: y)
        }
        throw Diagnostic(
            "\"\(name)\" must be an alignment name (\(Align.allCases.map(\.rawValue).joined(separator: ", "))) or [x, y] with each from 0 to 1, not \(describe(value))"
        )
    }

    static func padding(_ value: JSONValue, _ name: String) throws(Diagnostic) -> Insets {
        let range = -Limits.padding...Limits.padding
        if case .number = value {
            let all = try number(value, name, in: range)
            return Insets(top: all, leading: all, bottom: all, trailing: all)
        }
        guard case .object = value else {
            throw Diagnostic(
                "\"\(name)\" must be a number or an object with any of top, bottom, leading, trailing, horizontal, vertical, not \(describe(value))"
            )
        }
        let sides = try object(value, name, keys: ["top", "bottom", "leading", "trailing", "horizontal", "vertical"])
        func side(_ key: String) throws(Diagnostic) -> Double? {
            try sides[key].map { (value) throws(Diagnostic) in try number(value, "\(name).\(key)", in: range) }
        }
        let horizontal = try side("horizontal") ?? 0
        let vertical = try side("vertical") ?? 0
        return Insets(
            top: try side("top") ?? vertical, leading: try side("leading") ?? horizontal,
            bottom: try side("bottom") ?? vertical, trailing: try side("trailing") ?? horizontal)
    }

    static func frame(_ value: JSONValue, _ name: String) throws(Diagnostic) -> Frame {
        let keys = ["width", "height", "minWidth", "maxWidth", "minHeight", "maxHeight", "alignment"]
        let members = try object(value, name, keys: keys, example: "{\"width\": 40, \"height\": 40}")
        func length(_ key: String) throws(Diagnostic) -> Double? {
            guard let value = members[key] else { return nil }
            if key.hasPrefix("max"), value == .string("infinity") { return .infinity }
            guard case .number(let number) = value, (0...Limits.length).contains(number) else {
                let infinity = key.hasPrefix("max") ? " or \"infinity\"" : ""
                throw Diagnostic(
                    "\"\(name).\(key)\" must be a number from 0 to \(format(Limits.length))\(infinity), not \(describe(value))"
                )
            }
            return number
        }
        let frame = Frame(
            width: try length("width"), height: try length("height"), minWidth: try length("minWidth"),
            minHeight: try length("minHeight"), maxWidth: try length("maxWidth"), maxHeight: try length("maxHeight"),
            alignment: try members["alignment"].map { (value) throws(Diagnostic) in
                try choice(value, "\(name).alignment", Align.self)
            } ?? .center)
        for (axis, low, high) in [
            ("Width", frame.minWidth, frame.maxWidth), ("Height", frame.minHeight, frame.maxHeight),
        ] {
            if let low, let high, low > high {
                throw Diagnostic("\"\(name).min\(axis)\" is larger than \"\(name).max\(axis)\"")
            }
        }
        return frame
    }

    static func stroke(_ value: JSONValue, _ name: String) throws(Diagnostic) -> Stroke {
        let members = try object(
            value, name, keys: ["color", "width", "cap", "dash"],
            example: "{\"color\": \"#FFFFFF\", \"width\": 2, \"dash\": \"dashed\"}")
        guard let color = members["color"] else {
            throw Diagnostic("\"\(name)\" needs \"color\": a hex color or a gradient")
        }
        let width =
            try members["width"].map { (value) throws(Diagnostic) in
                try number(value, "\(name).width", in: 0.1...Limits.strokeWidth)
            } ?? 1
        var cap =
            try members["cap"].map { (value) throws(Diagnostic) in try choice(value, "\(name).cap", Cap.self) } ?? .butt
        var dash: [Double] = []
        switch members["dash"] {
        case nil:
            break
        case .string("dashed")?:
            dash = [max(3 * width, 3), max(2 * width, 2)]
        case .string("dotted")?:
            dash = [0, max(2 * width, 2)]
            cap = .round
        case .array(let lengths)? where (1...8).contains(lengths.count):
            for (index, length) in lengths.enumerated() {
                dash.append(try number(length, "\(name).dash[\(index)]", in: 0...Limits.length))
            }
            guard dash.contains(where: { $0 > 0 }) else {
                throw Diagnostic("\"\(name).dash\" needs at least one length above 0")
            }
        case let other?:
            throw Diagnostic(
                "\"\(name).dash\" must be \"dashed\", \"dotted\", or a list of 1 to 8 dash and gap lengths like [6, 3], not \(describe(other))"
            )
        }
        return Stroke(fill: try fill(color, "\(name).color"), width: width, cap: cap, dash: dash)
    }

    static func shadow(_ value: JSONValue, _ name: String) throws(Diagnostic) -> Shadow {
        let members = try object(
            value, name, keys: ["color", "radius", "x", "y"],
            example: "{\"color\": \"#00000040\", \"radius\": 4, \"x\": 0, \"y\": 2}")
        func measure(_ key: String, _ range: ClosedRange<Double>, _ fallback: Double) throws(Diagnostic) -> Double {
            try members[key].map { (value) throws(Diagnostic) in try number(value, "\(name).\(key)", in: range) }
                ?? fallback
        }
        return Shadow(
            color: try members["color"].map { (value) throws(Diagnostic) in try color(value, "\(name).color") }
                ?? ColorPair(RGBA(r: 0, g: 0, b: 0, a: 0.33)),
            radius: try measure("radius", 0...Limits.blur, 4),
            offset: CGSize(
                width: try measure("x", -Limits.length...Limits.length, 0),
                height: try measure("y", -Limits.length...Limits.length, 0)))
    }

    /// A number for both axes, or `{ x, y }`.
    static func scale(_ value: JSONValue, _ name: String) throws(Diagnostic) -> CGSize {
        if case .number = value {
            let both = try number(value, name, in: -Limits.scale...Limits.scale)
            return CGSize(width: both, height: both)
        }
        return try pair(value, name, range: -Limits.scale...Limits.scale, fallback: 1)
    }

    static func offset(_ value: JSONValue, _ name: String) throws(Diagnostic) -> CGSize {
        try pair(value, name, range: -Limits.length...Limits.length, fallback: 0)
    }

    private static func pair(_ value: JSONValue, _ name: String, range: ClosedRange<Double>, fallback: Double)
        throws(Diagnostic) -> CGSize
    {
        let members = try object(value, name, keys: ["x", "y"], example: "{\"x\": 0, \"y\": 4}")
        func axis(_ key: String) throws(Diagnostic) -> Double {
            try members[key].map { (value) throws(Diagnostic) in try number(value, "\(name).\(key)", in: range) }
                ?? fallback
        }
        return CGSize(width: try axis("x"), height: try axis("y"))
    }

    /// `[x, y, width, height]` in fractions of the image, inside it.
    static func crop(_ value: JSONValue, _ name: String) throws(Diagnostic) -> CGRect {
        let request = "\"\(name)\" must be [x, y, width, height] with each from 0 to 1, inside the image"
        guard case .array(let items) = value, items.count == 4 else {
            throw Diagnostic("\(request), not \(describe(value))")
        }
        var parts: [Double] = []
        for item in items {
            guard case .number(let number) = item, (0...1).contains(number) else {
                throw Diagnostic("\(request), not \(describe(value))")
            }
            parts.append(number)
        }
        guard parts[2] > 0, parts[3] > 0, parts[0] + parts[2] <= 1.0001, parts[1] + parts[3] <= 1.0001 else {
            throw Diagnostic("\(request): width and height above 0, x + width and y + height at most 1")
        }
        return CGRect(x: parts[0], y: parts[1], width: min(parts[2], 1 - parts[0]), height: min(parts[3], 1 - parts[1]))
    }

    /// The members of an object prop, failing on any key that `keys` does not list.
    static func object(_ value: JSONValue, _ name: String, keys: [String], example: String? = nil) throws(Diagnostic)
        -> [String: JSONValue]
    {
        guard case .object(let members) = value else {
            throw Diagnostic(
                "\"\(name)\" must be an object\(example.map { " like \($0)" } ?? ""), not \(describe(value))")
        }
        let present = members.filter { $0.value != .null }
        if let key = present.keys.sorted().first(where: { !keys.contains($0) }) {
            throw Diagnostic("\"\(name)\" has no key \(Diagnostic.quote(key)) (keys: \(keys.joined(separator: ", ")))")
        }
        return present
    }

    static func hex(_ text: String) -> RGBA? {
        let digits = Array(text.utf8.dropFirst())
        guard text.hasPrefix("#"), digits.count == 6 || digits.count == 8 else { return nil }
        var components: [Double] = []
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            components.append(Double(high * 16 + low) / 255)
        }
        return RGBA(r: components[0], g: components[1], b: components[2], a: components.count == 4 ? components[3] : 1)
    }

    private static func nibble(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: Int(byte - 0x30)
        case 0x41...0x46: Int(byte - 0x41 + 10)
        case 0x61...0x66: Int(byte - 0x61 + 10)
        default: nil
        }
    }

    /// `(actions: drink, undo)`, or `(<none>)` when there is nothing to list.
    static func choices(_ label: String, _ items: [String], none: String) -> String {
        items.isEmpty ? "(\(none))" : "(\(label): \(items.joined(separator: ", ")))"
    }

    /// How an error line names a value: `the string "red"`, `the number 3`, `a list`.
    static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number): "the number \(format(number))"
        case .string(let text): "the string \(Diagnostic.quote(text))"
        case .array: "a list"
        case .object: "an object"
        }
    }

    /// Whole numbers without a fraction, as JavaScript shows them.
    static func format(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        return "\(number)"
    }
}

/// Bounds that keep a tree inside the extension's memory and every value inside what SwiftUI draws well.
enum Limits {
    static let nodes = 2000
    static let depth = 40
    static let textLength = 1000
    static let length = 2000.0
    static let padding = 500.0
    static let fontSize = 1.0...300.0
    static let strokeWidth = 100.0
    static let blur = 100.0
    static let scale = 20.0
    static let degrees = 3600.0
    static let pathLength = 20_000
}
