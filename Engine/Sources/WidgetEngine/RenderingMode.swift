import SwiftUI

/// How the system draws the widget. WidgetKit tells only the view, never the timeline provider, so the look
/// cannot branch on it: one tree draws in every mode, and the renderer resolves the mode here. The widget host
/// maps WidgetKit's `widgetRenderingMode` into it, and proofs set it directly.
package enum RenderingMode: Sendable {
    case fullColor
    /// Tinted, including iOS 26 tinted and clear. The renderer draws it the way the system does: the
    /// background becomes a dark backdrop, every color becomes white at its own opacity, accent nodes take the
    /// tint color, and images follow their `tint`. On a device the system recolors the same views again by
    /// their opacity, which leaves this unchanged; only a device can confirm the match.
    case accented
}

/// The colors the renderer resolves a look's colors to, from the rendering mode, the color scheme, and whether
/// the view sits inside an `accent: true` node.
package struct Palette {
    /// The emulated tinted backdrop and tint color.
    package static let backdrop = RGBA(r: 0.13, g: 0.14, b: 0.16, a: 1)
    package static let tint = RGBA(r: 1, g: 0.70, b: 0.25, a: 1)
    private static let white = RGBA(r: 1, g: 1, b: 1, a: 1)

    let mode: RenderingMode
    let dark: Bool
    let accent: Bool

    func color(_ pair: ColorPair) -> Color {
        let picked = dark ? pair.dark : pair.light
        switch mode {
        case .fullColor: return picked.color
        case .accented:
            let ink = accent ? Self.tint : Self.white
            return RGBA(r: ink.r, g: ink.g, b: ink.b, a: picked.a).color
        }
    }

    func paint(_ fill: Fill) -> AnyShapeStyle {
        switch fill {
        case .color(let pair):
            AnyShapeStyle(color(pair))
        case .linear(let stops, let from, let to):
            AnyShapeStyle(
                LinearGradient(
                    stops: gradient(stops), startPoint: UnitPoint(x: from.x, y: from.y),
                    endPoint: UnitPoint(x: to.x, y: to.y)))
        case .radial(let stops, let center, let startRadius, let endRadius):
            AnyShapeStyle(
                RadialGradient(
                    stops: gradient(stops), center: UnitPoint(x: center.x, y: center.y), startRadius: startRadius,
                    endRadius: endRadius))
        case .angular(let stops, let center, let startAngle, let endAngle):
            AnyShapeStyle(
                AngularGradient(
                    stops: gradient(stops), center: UnitPoint(x: center.x, y: center.y),
                    startAngle: .degrees(startAngle), endAngle: .degrees(endAngle)))
        }
    }

    private func gradient(_ stops: [Stop]) -> [Gradient.Stop] {
        stops.map { Gradient.Stop(color: color($0.color), location: $0.location) }
    }
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

// Hand-written keys, not `@Entry`: the Command Line Tools ship no SwiftUI macro plugin.
private struct RenderingModeKey: EnvironmentKey {
    static let defaultValue = RenderingMode.fullColor
}

private struct AccentGroupKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    package var renderingMode: RenderingMode {
        get { self[RenderingModeKey.self] }
        set { self[RenderingModeKey.self] = newValue }
    }

    /// True inside a node with `accent: true`.
    var accentGroup: Bool {
        get { self[AccentGroupKey.self] }
        set { self[AccentGroupKey.self] = newValue }
    }

    var palette: Palette { Palette(mode: renderingMode, dark: colorScheme == .dark, accent: accentGroup) }
}
