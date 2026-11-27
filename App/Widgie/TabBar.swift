import SwiftUI

/// The app's own tab bar, frosted glass floating over the sky: Widgets, Make in the middle as a key with Widgie in
/// it, and Templates. A white highlight springs to the chosen tab. Widgets counts the widgets saved while you were
/// elsewhere, and its glyph squishes as each one flies into it.
struct TabBar: View {
    let page: Tabs.Page
    let unseen: Int
    /// Counts the widgets that flew into the Widgets glyph.
    let caught: Int
    let pick: (Tabs.Page) -> Void
    /// Where the Widgets glyph is, in the window, for a widget to fly to.
    let target: (CGRect) -> Void

    @Namespace private var highlight
    @State private var hops = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            tab(.widgets, "Widgets", label: unseen > 0 ? "Widgets, \(unseen) new" : "Widgets") { chosen in
                TabGlyph(kind: .widgets, chosen: chosen, caught: caught)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        target($0)
                    }
            }
            tab(.make, "Make", label: "Make") { chosen in
                MakeKey(chosen: chosen, hops: hops)
            }
            tab(.templates, "Templates", label: "Templates") { chosen in
                TabGlyph(kind: .templates, chosen: chosen)
            }
        }
        .padding(6)
        .frame(height: 68)
        .background {
            let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
            shape.fill(.ultraThinMaterial)
                .overlay { shape.fill(Palette.bar) }
                .overlay { shape.strokeBorder(Palette.barEdge, lineWidth: 0.5) }
                .liftShadow()
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.18), value: page)
        .onChange(of: page) { _, page in
            if page == .make { hops += 1 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }

    private func tab(
        _ target: Tabs.Page, _ title: String, label: String, @ViewBuilder glyph: (Bool) -> some View
    ) -> some View {
        let chosen = page == target
        return Button {
            pick(target)
        } label: {
            VStack(spacing: 3) {
                glyph(chosen)
                    .frame(height: 28)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(-0.1)
                    .lineLimit(1)
            }
            .foregroundStyle(chosen ? Palette.text : Palette.tabIdle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if chosen {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Palette.tabPill)
                        .shadow(color: Palette.restShadow.opacity(0.6), radius: 4, y: 2)
                        .matchedGeometryEffect(id: "highlight", in: highlight)
                }
            }
            .overlay(alignment: .top) {
                if target == .widgets { badge }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            glyph(chosen)
            Text(title)
        }
    }

    /// The coral count of widgets saved while you were away, just right of the glyph's middle.
    private var badge: some View {
        HStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity)
            HStack(spacing: 0) {
                Color.clear.frame(width: 7, height: 1)
                // Removed at zero rather than scaled to nothing, which VoiceOver still reads as "0".
                if unseen > 0 {
                    count.transition(reduceMotion ? .opacity : .scale(scale: 0.001))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 2)
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.45), value: unseen > 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var count: some View {
        Text("\(unseen)")
            .font(.system(size: 11, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.badge))
            .shadow(color: Palette.badge.opacity(0.45), radius: 4, y: 3)
    }
}

/// Squishes a tab's glyph while it is pressed.
private struct TabPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.tabPressed, configuration.isPressed)
    }
}

extension EnvironmentValues {
    @Entry fileprivate var tabPressed = false
}

/// A tab's outline glyph, drawn at 2.4 points when its tab is chosen and 2.1 otherwise. It squishes to take in each
/// widget caught.
private struct TabGlyph: View {
    enum Kind {
        case widgets, templates
    }

    let kind: Kind
    let chosen: Bool
    var caught = 0

    @Environment(\.tabPressed) private var pressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            let unit = size.width / 24
            let style = StrokeStyle(lineWidth: (chosen ? 2.4 : 2.1) * unit, lineJoin: .round)
            func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ corner: Double) -> Path {
                Path(
                    roundedRect: CGRect(x: x * unit, y: y * unit, width: width * unit, height: height * unit),
                    cornerRadius: corner * unit, style: .continuous)
            }
            func turned(_ path: Path, _ degrees: Double, _ x: Double, _ y: Double) -> Path {
                path.applying(
                    CGAffineTransform(translationX: x * unit, y: y * unit).rotated(by: degrees * .pi / 180)
                        .translatedBy(x: -x * unit, y: -y * unit))
            }
            switch kind {
            case .widgets:
                for part in [
                    box(3, 3, 8, 11, 2.6), box(13, 3, 8, 6.5, 2.6), box(3, 16, 8, 5, 2.4), box(13, 11.5, 8, 9.5, 2.6),
                ] {
                    context.stroke(part, with: .foreground, style: style)
                }
            case .templates:
                let front = turned(box(9, 4, 11.5, 15, 3), 7, 14.75, 11.5)
                context.drawLayer { layer in
                    layer.clip(to: turned(box(8, 3, 13.5, 17, 3.6), 7, 14.75, 11.5), options: .inverse)
                    layer.stroke(turned(box(3.5, 5, 12, 15, 3), -8, 9.5, 12.5), with: .foreground, style: style)
                }
                context.stroke(front, with: .foreground, style: style)
            }
        }
        .frame(width: 24, height: 24)
        .scaleEffect(pressed && !reduceMotion ? 0.86 : 1)
        .animation(.spring(duration: 0.32, bounce: 0.45), value: pressed)
        .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : caught) { glyph, scale in
            glyph.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(0.8, duration: 0.114)
            CubicKeyframe(1.08, duration: 0.152)
            CubicKeyframe(1, duration: 0.114)
        }
    }
}

/// Make's glyph: a small rounded key with Widgie peeking out of it, as on the app icon. Quiet when unchosen, sun
/// yellow when chosen, and Widgie hops each time you switch to it.
private struct MakeKey: View {
    let chosen: Bool
    let hops: Int

    @Environment(\.tabPressed) private var pressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack(alignment: .topLeading) {
            if chosen {
                shape.fill(
                    LinearGradient(
                        colors: [Color(red: 1, green: 0.894, blue: 0.475), Color(red: 1, green: 0.773, blue: 0.196)],
                        startPoint: UnitPoint(x: 0.4, y: 0), endPoint: UnitPoint(x: 0.6, y: 1)))
            } else {
                shape.fill(Palette.makeKeyFill)
            }
            HoppingCaret(
                size: 46, color: chosen ? Palette.ink : Palette.caret, eye: chosen ? Palette.inkEye : Palette.caretEye,
                grounded: false, height: 8, alive: chosen, cue: hops
            )
            .offset(x: -3, y: 1)
        }
        .frame(width: 40, height: 26)
        .clipShape(shape)
        .overlay {
            if chosen {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.7), .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 1)
            }
        }
        .scaleEffect((chosen ? 1.04 : 1) * (pressed && !reduceMotion ? 0.86 : 1))
        .animation(.spring(duration: 0.32, bounce: 0.45), value: chosen)
        .animation(.spring(duration: 0.32, bounce: 0.45), value: pressed)
    }
}
