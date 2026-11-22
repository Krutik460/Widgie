import SwiftUI
import UIKit

/// The Paint Quest palette (`docs/design/app-feel/b-paint-quest.html`). Dark mode is a night sky over the same
/// paints: the ground and cards go deep blue, and tangerine, sky, and sun stay bright.
enum Palette {
    static let ground = Color(light: 0xCDEAFF, dark: 0x0B1A31)
    static let surface = Color(light: 0xFFFFFF, dark: 0x15294A)
    static let line = Color(light: 0xAED6F3, dark: 0x274A75)
    static let divider = Color(light: 0xE6F2FB, dark: 0x203E66)
    static let dash = Color(light: 0x8CC3EC, dark: 0x3F6A9C)
    static let track = Color(light: 0xE3F1FC, dark: 0x0F2140)

    static let tangerine = Color(light: 0xFF7A1A, dark: 0xFF7A1A)
    static let tangerineLip = Color(light: 0xD65A00, dark: 0xB24700)
    static let tangerineTint = Color(light: 0xFFF1E6, dark: 0x3B2416)
    static let tangerineText = Color(light: 0xD65A00, dark: 0xFF9A4D)
    static let sky = Color(light: 0x1FA4F0, dark: 0x2AADF5)
    static let skyLip = Color(light: 0x0A7FC2, dark: 0x0A68A3)
    static let skyText = Color(light: 0x0A7FC2, dark: 0x6CC8FF)
    static let sun = Color(light: 0xFFCB2E, dark: 0xFFC629)
    static let sunLip = Color(light: 0xDDA300, dark: 0xB98A00)
    static let berry = Color(light: 0xF0384F, dark: 0xFF4D63)
    static let berryLip = Color(light: 0xBF1C34, dark: 0xB31F35)
    static let berryTint = Color(light: 0xFFDDE2, dark: 0x3A1828)
    static let berryText = Color(light: 0xBF1C34, dark: 0xFF8696)

    static let ink = Color(light: 0x14204A, dark: 0xEAF3FF)
    static let muted = Color(light: 0x55688F, dark: 0x9DB4D6)
    static let placeholder = Color(light: 0x8DA4BE, dark: 0x6F89B0)
    static let off = Color(light: 0xB7CDE0, dark: 0x30496E)
    static let offLip = Color(light: 0x98B3CA, dark: 0x213753)
    static let offText = Color(light: 0xFFFFFF, dark: 0x7F98BC)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }

    init(rgb: UInt32) {
        self.init(uiColor: UIColor(rgb: rgb))
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// The colors of one pressable surface: its face, the darker lip under it, its label, and an optional border.
struct Chunk {
    var face: Color
    var lip: Color
    var text: Color
    var border: Color?
    var borderWidth: CGFloat = 2

    static let primary = Chunk(face: Palette.tangerine, lip: Palette.tangerineLip, text: .white)
    static let plain = Chunk(face: Palette.surface, lip: Palette.line, text: Palette.skyText, border: Palette.line)
    static let sky = Chunk(face: Palette.sky, lip: Palette.skyLip, text: .white)
    static let danger = Chunk(face: Palette.berry, lip: Palette.berryLip, text: .white)
    static let card = Chunk(face: Palette.surface, lip: Palette.line, text: Palette.ink, border: Palette.line)
    static let picked = Chunk(
        face: Palette.tangerineTint, lip: Palette.tangerineLip, text: Palette.tangerineText,
        border: Palette.tangerine, borderWidth: 3)
    static let off = Chunk(face: Palette.off, lip: Palette.offLip, text: Palette.offText)
}

/// A chunky button: the face sits on a darker lip and presses down into it, with a light tap of haptics.
/// Disabled, it turns the flat off color. `wide` stretches it across its container.
struct ChunkyButtonStyle: ButtonStyle {
    var chunk: Chunk = .primary
    var corner: CGFloat = 16
    var lip: CGFloat = 5
    var height: CGFloat = 56
    var wide = true
    var font: Font = .headline.weight(.black)

    func makeBody(configuration: Configuration) -> some View {
        ChunkyButton(configuration: configuration, style: self)
    }
}

private struct ChunkyButton: View {
    let configuration: ButtonStyleConfiguration
    let style: ChunkyButtonStyle

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let chunk = isEnabled ? style.chunk : .off
        let pressed = configuration.isPressed && isEnabled
        let shape = RoundedRectangle(cornerRadius: style.corner, style: .continuous)
        configuration.label
            .font(style.font)
            .foregroundStyle(chunk.text)
            .multilineTextAlignment(.center)
            .padding(.horizontal, style.wide ? 18 : 12)
            .frame(maxWidth: style.wide ? .infinity : nil, minHeight: style.height)
            .background(shape.fill(chunk.face))
            .overlay {
                if let border = chunk.border { shape.strokeBorder(border, lineWidth: chunk.borderWidth) }
            }
            .offset(y: pressed ? style.lip : 0)
            .background { shape.fill(chunk.lip).offset(y: style.lip) }
            .padding(.bottom, style.lip)
            .contentShape(shape)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.07), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed) { _, now in now }
    }
}

extension View {
    /// A white card on a lip of the line color, as every Paint Quest card sits.
    func card(corner: CGFloat = 22, lip: CGFloat = 5, fill: Color = Palette.surface) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return background {
            ZStack {
                shape.fill(Palette.line).offset(y: lip)
                shape.fill(fill)
                shape.strokeBorder(Palette.line, lineWidth: 2)
            }
        }
    }
}

/// Where the person is in the describe flow. The bar has four chunky segments and no numbers.
enum FlowStep: Int, CaseIterable {
    case describe, build, tryIt, save, done
}

struct StepBar: View {
    let step: FlowStep

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                Segment(fill: index < step.rawValue ? 1 : index == step.rawValue ? 0.55 : 0)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.3), value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(min(step.rawValue + 1, 4)) of 4")
    }

    private struct Segment: View {
        let fill: CGFloat

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    shape.fill(Palette.surface)
                    shape.strokeBorder(Palette.line, lineWidth: 2)
                    ZStack(alignment: .top) {
                        shape.fill(Palette.tangerineLip)
                        shape.fill(Palette.tangerine).padding(.bottom, 5)
                        RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.55)).frame(height: 3)
                            .padding(.horizontal, 6).padding(.top, 3)
                            .opacity(fill == 1 ? 1 : 0)
                    }
                    .clipShape(shape)
                    .frame(width: box.size.width * fill)
                    .opacity(fill > 0 ? 1 : 0)
                }
            }
            .frame(height: 16)
        }
    }
}
