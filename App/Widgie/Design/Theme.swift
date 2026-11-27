import SwiftUI

/// The Sky tokens (`docs/design/app-feel/directions.md`, round 4). Each is a colorset in
/// `WidgieColors.xcassets` with a light and a dark value, so changing a token is one edit there.
enum Palette {
    static let skyTop = Color(.widgieSkyTop)
    static let skyMiddle = Color(.widgieSkyMiddle)
    static let skyBottom = Color(.widgieSkyBottom)
    static let moon = Color(.widgieMoon)
    /// Ink in both modes, for words and Widgie on a surface that stays light at night: a bubble, the sun key.
    static let ink = Color(red: 0x12 / 255, green: 0x1A / 255, blue: 0x2E / 255)
    /// Widgie's eyes when it is drawn in ink at night.
    static let inkEye = Color(red: 0xC4 / 255, green: 0xD8 / 255, blue: 0xF3 / 255)
    static let caret = Color(.widgieCaret)
    static let caretEye = Color(.widgieCaretEye)
    static let cheek = Color(.widgieCaretCheek)
    static let caretShadow = Color(.widgieCaretShadow)
    static let text = Color(.widgieTextPrimary)
    static let secondary = Color(.widgieTextSecondary)
    static let buttonFill = Color(.widgieButtonFill)
    static let buttonLabel = Color(.widgieButtonLabel)
    static let outline = Color(.widgieOutline)
    static let disabled = Color(.widgieFillDisabled)
    static let widgetShadow = Color(.widgieWidgetShadow)
    static let widgetShadowNear = Color(.widgieWidgetShadowNear)
    /// A hairline that lifts a face off the dusk at night. Clear by day.
    static let faceEdge = Color(.widgieFaceEdge)
    static let liftShadow = Color(.widgieLiftShadow)
    static let chipLabel = Color(.widgieChipLabel)
    /// A soft control resting on the ground: an unchosen category, a quiet key.
    static let surface = Color(.widgieSurface)
    static let chosenFill = Color(.widgieChosenFill)
    static let chosenLabel = Color(.widgieChosenLabel)
    /// The main key: ink by day, sun yellow by night.
    static let keyFill = Color(.widgieKeyFill)
    static let keyLabel = Color(.widgieKeyLabel)
    static let quietKeyFill = Color(.widgieQuietKeyFill)
    static let fieldFill = Color(.widgieFieldFill)
    /// The faint square behind a sheet's close mark.
    static let softFill = Color(.widgieSoftFill)
    static let sheetTop = Color(.widgieSheetTop)
    static let sheetBottom = Color(.widgieSheetBottom)
    static let spotGlow = Color(.widgieSpotGlow)
    static let bubble = Color(.widgieBubble)
    static let restShadow = Color(.widgieRestShadow)
    static let sun = Color(.widgieSun)
    /// The tab bar's frosted fill, its hairline, the chosen tab's highlight, and an unchosen tab's ink.
    static let bar = Color(.widgieBar)
    static let barEdge = Color(.widgieBarEdge)
    static let tabPill = Color(.widgieTabPill)
    static let tabIdle = Color(.widgieTabIdle)
    static let makeKeyFill = Color(.widgieMakeKeyFill)
    static let badge = Color(.widgieBadge)

    static let failureGround = Color(.widgieFailureGround)
    static let failureCaret = Color(.widgieFailureCaret)
    static let failureText = Color(.widgieFailureText)
    static let failureButtonFill = Color(.widgieFailureButtonFill)
    static let failureButtonLabel = Color(.widgieFailureButtonLabel)

    /// The confetti on Saved: bright versions of the chip hues.
    static let pops = [
        Color(.widgiePopMint), Color(.widgiePopButter), Color(.widgiePopPink), Color(.widgiePopLilac),
        Color(.widgiePopPeach),
    ]
}

/// The soft fill of a chip. Color on a chip always means "tap to use this"; outlined controls stay neutral.
enum ChipColor {
    case mint, butter, pink, lilac, peach

    var fill: Color {
        switch self {
        case .mint: Color(.widgieChipMint)
        case .butter: Color(.widgieChipButter)
        case .pink: Color(.widgieChipPink)
        case .lilac: Color(.widgieChipLilac)
        case .peach: Color(.widgieChipPeach)
        }
    }
}

extension View {
    /// SF Pro at the mock's point size, scaled with Dynamic Type like `style`.
    func font(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(ScaledFont(size: size, weight: weight, style: style))
    }

    /// The display face for titles and big words, at the prototype's point size and tight tracking, scaled with
    /// Dynamic Type like `style`.
    func display(size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> some View {
        modifier(DisplayFont(size: size, style: style))
    }

    /// The soft lift under a control that rests on the ground: a close contact shadow and a wide faint one.
    func restShadow() -> some View {
        shadow(color: Palette.restShadow.opacity(0.4), radius: 1, y: 1)
            .shadow(color: Palette.restShadow, radius: 7, y: 4)
    }

    /// The elevation under a widget face: a close shadow and a soft lifted one, no outline. At night a hairline
    /// joins them, because the faces nearly match the dusk.
    func faceShadow() -> some View {
        overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.faceEdge, lineWidth: 0.5)
        }
        .shadow(color: Palette.widgetShadowNear, radius: 3, y: 2)
        .shadow(color: Palette.widgetShadow, radius: 13, y: 14)
    }

    /// The lift under a control floating over the page, such as the tab bar.
    func liftShadow() -> some View {
        shadow(color: Palette.liftShadow.opacity(0.16), radius: 3, y: 2)
            .shadow(color: Palette.liftShadow, radius: 14, y: 14)
    }

    /// A sheet in the prototype's style: 36-point corners over the light gradient by day and the dusk at night,
    /// with the grabber.
    func sheetStyle() -> some View {
        presentationDragIndicator(.visible)
            .presentationCornerRadius(36)
            .presentationBackground {
                LinearGradient(colors: [Palette.sheetTop, Palette.sheetBottom], startPoint: .top, endPoint: .bottom)
            }
    }
}

private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight, style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

/// Bricolage Grotesque, which the engine bundles and registers for the whole process when the library's engine is
/// made at launch: Display (800 weight, 82 percent width) for titles and big words, and Key (700 weight, 92 percent
/// width) for keys.
enum Typeface {
    static let display = "Bricolage Grotesque Display"
    static let key = "Bricolage Grotesque Key"
}

private struct DisplayFont: ViewModifier {
    @ScaledMetric private var size: CGFloat

    init(size: CGFloat, style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
    }

    func body(content: Content) -> some View {
        content.font(.custom(Typeface.display, fixedSize: size)).tracking(-0.025 * size)
    }
}

private struct KeyFont: ViewModifier {
    @ScaledMetric private var size: CGFloat

    init(size: CGFloat) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    func body(content: Content) -> some View {
        content.font(.custom(Typeface.key, fixedSize: size)).tracking(-0.01 * size)
    }
}

/// The text cursor's bar, blinking 530 ms on and 530 ms off like the system caret. Steady with Reduce Motion.
struct CursorBar: View {
    var color: Color
    var height: CGFloat = 22
    var blinking = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { timeline in
            let on = !blinking || reduceMotion || Int(timeline.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3, height: height)
                .opacity(on ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}

/// The main action: an ink slab with its label and a blinking bar, so it reads as "type here, go". Pressing
/// stops the blink and nudges it down. Disabled, it goes flat with no bar.
struct PrimaryButtonStyle: ButtonStyle {
    var fill = Palette.buttonFill
    var label = Palette.buttonLabel

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButton(configuration: configuration, style: self)
    }
}

private struct PrimaryButton: View {
    let configuration: ButtonStyleConfiguration
    let style: PrimaryButtonStyle

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        HStack(spacing: 5) {
            configuration.label
            if isEnabled {
                CursorBar(color: style.label, blinking: !pressed)
            }
        }
        .font(size: 18, weight: .bold)
        .tracking(-0.3)
        .lineLimit(1)
        .foregroundStyle(isEnabled ? style.label : Palette.secondary)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isEnabled ? style.fill : Palette.disabled)
        )
        .offset(y: pressed ? 2 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.08), value: pressed)
        .sensoryFeedback(.impact(weight: .light), trigger: pressed) { _, now in now }
    }
}

/// A small filled button for a top bar, such as Save.
struct CompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompactButton(configuration: configuration)
    }
}

private struct CompactButton: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .font(size: 17, weight: .bold)
            .lineLimit(1)
            .foregroundStyle(isEnabled ? Palette.buttonLabel : Palette.secondary)
            .padding(.horizontal, 20)
            .frame(minWidth: 84, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(
                    isEnabled ? Palette.buttonFill : Palette.disabled)
            )
            .offset(y: pressed ? 1.5 : 0)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed) { _, now in now }
    }
}

/// A suggestion in its own soft color, with an ink label.
struct ChipButtonStyle: ButtonStyle {
    let color: ChipColor

    func makeBody(configuration: Configuration) -> some View {
        ChipButton(configuration: configuration, color: color)
    }
}

private struct ChipButton: View {
    let configuration: ButtonStyleConfiguration
    let color: ChipColor

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .font(size: 16, weight: .semibold)
            .tracking(-0.2)
            .lineLimit(1)
            .foregroundStyle(Palette.chipLabel)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(color.fill))
            .scaleEffect(pressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed) { _, now in now }
    }
}

/// The neutral 2-point outline that marks a control which is not the main action: the photo button, the
/// composer, the sample menu.
struct Outline: View {
    var corner: CGFloat = 14
    var color = Palette.outline

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(color, lineWidth: 2)
    }
}

/// The close button at the top left of every describe screen.
struct CloseButton: View {
    var color = Palette.text
    var label = "Close"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

/// A key in a sheet: the main one (ink by day, sun yellow by night) or a quiet one beside it. It squishes with a
/// spring when pressed.
struct KeyButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        KeyButton(configuration: configuration, prominent: prominent)
    }
}

private struct KeyButton: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .modifier(KeyFont(size: 17))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .foregroundStyle(prominent ? Palette.keyLabel : Palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
                if prominent {
                    shape.fill(Palette.keyFill).shadow(color: Palette.widgetShadow, radius: 10, y: 8)
                } else {
                    shape.fill(Palette.quietKeyFill).restShadow()
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed) { _, now in now }
    }
}

/// A sheet's close button: a 34-point soft square with the cross, inside a 44-point target.
struct SoftCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.text)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.softFill))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishStyle())
        .accessibilityLabel("Close")
    }
}

/// Shrinks a control a little while it is pressed, with a spring back. Still with Reduce Motion.
struct SquishStyle: ButtonStyle {
    var scale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        SquishBody(configuration: configuration, scale: scale)
    }
}

private struct SquishBody: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .animation(.spring(duration: 0.3, bounce: 0.45), value: configuration.isPressed)
    }
}
