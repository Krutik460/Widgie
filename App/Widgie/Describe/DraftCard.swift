import SwiftUI
import WidgetEngine

/// The live draft, Widgie standing on its top edge. Its own buttons work on scratch rows. It keeps its identity as
/// it redraws, so VoiceOver stays on the button it was on.
struct DraftCard: View {
    let face: Face
    let name: String?
    let size: CGSize
    let act: HeroAct
    /// Where Widgie's foot stands on the face's top edge.
    let perch: CGPoint
    /// Widgie jumps for joy on a saved draft.
    let saved: Bool
    /// The saved tile has flown to the Widgets tab, leaving its outline behind, and Widgie drops away once it lands.
    /// With Reduce Motion the tile only dims and Widgie stays.
    let flown: Bool
    let tap: @MainActor @Sendable (Tap) -> Void
    let form: @MainActor @Sendable (Tap) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let headroom: CGFloat = 112

    var body: some View {
        let sole = Caret.sole(saved ? .jump : .lean(.left))
        let dropped = flown && !reduceMotion
        VStack(spacing: 0) {
            Color.clear.frame(width: size.width, height: Self.headroom)
            FaceTile(face: face, size: size, host: .app(tap: tap, form: form))
                .opacity(flown ? (reduceMotion ? 0.4 : 0) : 1)
                .background {
                    if flown && !reduceMotion {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Palette.caret.opacity(0.35), lineWidth: 3)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(name ?? "Your widget"), your draft")
        }
        .overlay(alignment: .topLeading) {
            FeedHero(leaning: .left, act: act, jumping: saved)
                .offset(
                    x: perch.x - sole.x * FeedHero.size,
                    y: Self.headroom + perch.y + 2 - sole.y * FeedHero.size + (dropped ? 44 : 0)
                )
                .opacity(dropped ? 0 : 1)
                .animation(.timingCurve(0.5, 0, 0.75, 0.4, duration: 0.36).delay(Flights.flightTime), value: dropped)
        }
    }
}

/// The widget's outline as Widgie draws it: from where Widgie will stand, clockwise round the edge and back in 2.2
/// seconds, the parts going from dashed to solid as the pen passes them. A build takes about 40 seconds, so the pen
/// then keeps riding the edge, a lap every 7 seconds, until the widget lands. Drawn and still with Reduce Motion.
struct Sketch: View {
    let size: CGSize
    let perch: CGPoint
    let started: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let headroom: CGFloat = 112
    private static let pen: CGFloat = 116
    private static let trace: TimeInterval = 2.2
    private static let lap: TimeInterval = 7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let elapsed = reduceMotion ? .infinity : max(0, timeline.date.timeIntervalSince(started))
            drawing(elapsed: elapsed)
        }
        .frame(width: size.width, height: size.height + Self.headroom, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func drawing(elapsed: TimeInterval) -> some View {
        let outline = Self.outline(size, from: perch.x)
        let k = min(1, elapsed / Self.trace)
        let drawn = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
        let riding =
            reduceMotion ? 0 : k < 1 ? drawn : ((elapsed - Self.trace) / Self.lap).truncatingRemainder(dividingBy: 1)
        let tip = riding > 0 ? outline.trimmedPath(from: 0, to: riding).currentPoint ?? perch : perch
        // The pen leans inward, so it never leaves the screen.
        let side: Caret.Side = tip.x > size.width / 2 ? .left : .right
        let foot = Caret.foot(.draw(side))
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                outline.trimmedPath(from: 0, to: drawn).stroke(
                    Palette.caret, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                ForEach(Array(Self.parts(size).enumerated()), id: \.offset) { _, part in
                    let solid = drawn >= part.at
                    RoundedRectangle(cornerRadius: part.radius, style: .continuous)
                        .fill(Palette.caret.opacity(solid ? 0.32 : 0))
                        .overlay {
                            RoundedRectangle(cornerRadius: part.radius, style: .continuous)
                                .stroke(
                                    Palette.caret.opacity(solid ? 0 : 0.5),
                                    style: StrokeStyle(lineWidth: 2, dash: [4, 5]))
                        }
                        .scaleEffect(solid ? 1 : 0.94)
                        .opacity(drawn >= part.at - 0.12 ? 1 : 0)
                        .animation(.easeOut(duration: 0.38), value: solid)
                        .frame(width: part.rect.width, height: part.rect.height)
                        .offset(x: part.rect.minX, y: part.rect.minY)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .offset(y: Self.headroom)
            Caret(pose: .draw(side), size: Self.pen, grounded: false)
                .position(
                    x: tip.x + Self.pen * (0.5 - foot.x), y: Self.headroom + tip.y + Self.pen * (0.5 - foot.y))
        }
    }

    /// The edge, from `x` on the top edge clockwise and back to it.
    private static func outline(_ size: CGSize, from x: CGFloat) -> Path {
        let (width, height, radius) = (size.width, size.height, 24.0)
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: width - radius, y: 0))
        path.addArc(tangent1End: CGPoint(x: width, y: 0), tangent2End: CGPoint(x: width, y: radius), radius: radius)
        path.addLine(to: CGPoint(x: width, y: height - radius))
        path.addArc(
            tangent1End: CGPoint(x: width, y: height), tangent2End: CGPoint(x: width - radius, y: height),
            radius: radius)
        path.addLine(to: CGPoint(x: radius, y: height))
        path.addArc(
            tangent1End: CGPoint(x: 0, y: height), tangent2End: CGPoint(x: 0, y: height - radius), radius: radius)
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addArc(tangent1End: .zero, tangent2End: CGPoint(x: radius, y: 0), radius: radius)
        path.closeSubpath()
        return path
    }

    /// A label, a big number and two buttons, each turning solid once the pen has passed it.
    private static func parts(_ size: CGSize) -> [(rect: CGRect, radius: CGFloat, at: Double)] {
        let (width, height) = (size.width, size.height)
        return [
            (CGRect(x: 18, y: 22, width: 64, height: 12), 6, 0.7),
            (CGRect(x: 18, y: 50, width: 118, height: 40), 10, 0.62),
            (CGRect(x: 18, y: height - 52, width: 34, height: 34), 17, 0.48),
            (CGRect(x: width - 60, y: height - 60, width: 42, height: 42), 21, 0.2),
        ]
    }
}
