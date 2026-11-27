import WidgetEngine

/// Changes that fit the draft on show, read off its face without asking the model: a color across the wheel from
/// the one it paints most, and a bigger number when it shows one. As in the prototype, a change whose turn landed
/// leaves, and a used recolor gives way to new colors. None when nothing fits.
enum Changes {
    enum Change: Hashable {
        case recolor, biggerNumber, newColors
    }

    struct Chip: Hashable {
        let change: Change
        let words: String
    }

    static func suggested(for traits: FaceTraits, used: Set<Change>) -> [Chip] {
        var chips: [Chip] = []
        if let hue = traits.hue, !used.contains(.recolor) {
            chips.append(Chip(change: .recolor, words: "Make it \(colorName(at: hue + 180))"))
        }
        if traits.showsNumber, !used.contains(.biggerNumber) {
            chips.append(Chip(change: .biggerNumber, words: "Bigger number"))
        }
        if traits.hue != nil, used.contains(.recolor), !used.contains(.newColors) {
            chips.append(Chip(change: .newColors, words: "Change the colors"))
        }
        return chips
    }

    /// The nearest everyday color name to a hue in degrees.
    static func colorName(at hue: Double) -> String {
        let names: [(hue: Double, name: String)] = [
            (0, "red"), (30, "orange"), (55, "yellow"), (125, "green"), (180, "teal"), (220, "blue"),
            (275, "purple"), (325, "pink"), (360, "red"),
        ]
        let hue = hue.truncatingRemainder(dividingBy: 360)
        return names.min { abs($0.hue - hue) < abs($1.hue - hue) }!.name
    }
}
