import SwiftUI

/// The mascot, one view with a mood per moment of the flow. Today it is Pip, the paint drop, drawn from the SVG in
/// `docs/design/app-feel/b-paint-quest.html` on its 120-point grid. Its mood follows what is happening.
struct Mascot: View {
    enum Mood {
        /// Bobbing, smiling, waiting for an idea.
        case idle
        /// Wiggling with a brush while a build runs.
        case working
        /// Arms up and jumping after a save.
        case cheering
        /// Brows up and a bead of sweat after a failure.
        case worried
    }

    var mood: Mood = .idle
    var size: CGFloat = 92

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            drawing
                .rotationEffect(.degrees(tilt(at: time)), anchor: UnitPoint(x: 0.5, y: 0.9))
                .offset(y: lift(at: time))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func lift(at time: TimeInterval) -> CGFloat {
        switch mood {
        case .idle: -3 * size / 120 * CGFloat(sin(time * 2.4))
        case .cheering: -12 * size / 120 * CGFloat(abs(sin(time * 3.4)))
        case .working, .worried: 0
        }
    }

    private func tilt(at time: TimeInterval) -> Double {
        switch mood {
        case .working: 6 * sin(time * 5.2)
        case .worried: 2 * sin(time * 9)
        case .idle, .cheering: 0
        }
    }

    private var drawing: some View {
        Canvas { context, canvas in
            context.scaleBy(x: canvas.width / 120, y: canvas.height / 120)
            draw(in: &context)
        }
    }

    private static let ink = Color(rgb: 0x14204A)
    private static let body = Color(rgb: 0xFF7A1A)
    private static let lip = Color(rgb: 0xD65A00)
    private static let cheek = Color(rgb: 0xFF4F7A)
    private static let sky = Color(rgb: 0x1FA4F0)

    private func draw(in context: inout GraphicsContext) {
        let round = StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
        context.fill(
            Path(ellipseIn: CGRect(x: 32, y: 112, width: 56, height: 8)), with: .color(.black.opacity(0.12)))
        if mood == .cheering {
            var arms = Path()
            arms.move(to: CGPoint(x: 28, y: 78))
            arms.addQuadCurve(to: CGPoint(x: 10, y: 52), control: CGPoint(x: 12, y: 72))
            arms.move(to: CGPoint(x: 92, y: 78))
            arms.addQuadCurve(to: CGPoint(x: 110, y: 52), control: CGPoint(x: 108, y: 72))
            context.stroke(arms, with: .color(Self.lip), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        }
        context.fill(Self.drop.offsetBy(dx: 0, dy: 5), with: .color(Self.lip))
        context.fill(Self.drop, with: .color(Self.body))
        var shine = Path()
        shine.move(to: CGPoint(x: 46, y: 44))
        shine.addQuadCurve(to: CGPoint(x: 37, y: 66), control: CGPoint(x: 38, y: 55))
        context.stroke(
            shine, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 7, lineCap: .round))

        switch mood {
        case .idle:
            eyes(at: [49, 71], look: 2, in: &context)
            cheeks(y: 90, opacity: 0.5, in: &context)
            var smile = Path()
            smile.move(to: CGPoint(x: 53, y: 92))
            smile.addQuadCurve(to: CGPoint(x: 67, y: 92), control: CGPoint(x: 60, y: 99))
            context.stroke(smile, with: .color(Self.ink), style: round)
        case .working:
            var handle = Path()
            handle.move(to: CGPoint(x: 30, y: 86))
            handle.addLine(to: CGPoint(x: 4, y: 52))
            context.stroke(
                handle, with: .color(Color(rgb: 0x8A5A2B)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            var tip = Path()
            tip.move(to: CGPoint(x: 4, y: 52))
            tip.addLine(to: CGPoint(x: 0, y: 40))
            tip.addQuadCurve(to: CGPoint(x: 12, y: 40), control: CGPoint(x: 6, y: 34))
            tip.closeSubpath()
            context.fill(tip, with: .color(Self.sky))
            eyes(at: [45, 67], look: -1, in: &context)
            var mouth = Path()
            mouth.move(to: CGPoint(x: 50, y: 93))
            mouth.addLine(to: CGPoint(x: 62, y: 93))
            context.stroke(mouth, with: .color(Self.ink), style: round)
            context.fill(Path(ellipseIn: CGRect(x: 58, y: 92, width: 8, height: 8)), with: .color(Self.cheek))
        case .cheering:
            var closed = Path()
            closed.move(to: CGPoint(x: 41, y: 76))
            closed.addQuadCurve(to: CGPoint(x: 57, y: 76), control: CGPoint(x: 49, y: 66))
            closed.move(to: CGPoint(x: 63, y: 76))
            closed.addQuadCurve(to: CGPoint(x: 79, y: 76), control: CGPoint(x: 71, y: 66))
            context.stroke(closed, with: .color(Self.ink), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            cheeks(y: 88, opacity: 0.6, in: &context)
            var mouth = Path()
            mouth.move(to: CGPoint(x: 50, y: 86))
            mouth.addQuadCurve(to: CGPoint(x: 70, y: 86), control: CGPoint(x: 60, y: 104))
            mouth.closeSubpath()
            context.fill(mouth, with: .color(Self.ink))
            var tongue = Path()
            tongue.move(to: CGPoint(x: 55, y: 93))
            tongue.addQuadCurve(to: CGPoint(x: 65, y: 93), control: CGPoint(x: 60, y: 99))
            tongue.closeSubpath()
            context.fill(tongue, with: .color(Self.cheek))
        case .worried:
            var brows = Path()
            brows.move(to: CGPoint(x: 40, y: 65))
            brows.addLine(to: CGPoint(x: 54, y: 59))
            brows.move(to: CGPoint(x: 80, y: 65))
            brows.addLine(to: CGPoint(x: 66, y: 59))
            context.stroke(brows, with: .color(Self.ink), style: round)
            for x in [49.0, 71.0] {
                context.fill(Path(ellipseIn: CGRect(x: x - 6, y: 71, width: 12, height: 12)), with: .color(Self.ink))
            }
            context.fill(Path(ellipseIn: CGRect(x: 54, y: 91, width: 12, height: 10)), with: .color(Self.ink))
            var sweat = Path()
            sweat.move(to: CGPoint(x: 98, y: 40))
            sweat.addQuadCurve(to: CGPoint(x: 98, y: 55), control: CGPoint(x: 104, y: 50))
            sweat.addQuadCurve(to: CGPoint(x: 98, y: 40), control: CGPoint(x: 92, y: 50))
            context.fill(sweat, with: .color(Self.sky))
        }
    }

    /// Two tall eyes with a white glint, the glint shifted by `look` toward where Pip is looking.
    private func eyes(at xs: [CGFloat], look: CGFloat, in context: inout GraphicsContext) {
        for x in xs {
            context.fill(Path(ellipseIn: CGRect(x: x - 7, y: 67, width: 14, height: 18)), with: .color(Self.ink))
            context.fill(
                Path(ellipseIn: CGRect(x: x + look - 2.5, y: 69.5, width: 5, height: 5)), with: .color(.white))
        }
    }

    private func cheeks(y: CGFloat, opacity: Double, in context: inout GraphicsContext) {
        for x in [38.0, 82.0] {
            context.fill(
                Path(ellipseIn: CGRect(x: x - 6, y: y - 4, width: 12, height: 8)),
                with: .color(Self.cheek.opacity(opacity)))
        }
    }

    /// The drop: a point at the top, curving out into a circle of radius 36 centered at (60, 76).
    private static let drop: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 60, y: 10))
        path.addCurve(to: CGPoint(x: 96, y: 76), control1: CGPoint(x: 60, y: 10), control2: CGPoint(x: 96, y: 52))
        path.addArc(
            center: CGPoint(x: 60, y: 76), radius: 36, startAngle: .degrees(0), endAngle: .degrees(180),
            clockwise: false)
        path.addCurve(to: CGPoint(x: 60, y: 10), control1: CGPoint(x: 24, y: 52), control2: CGPoint(x: 60, y: 10))
        path.closeSubpath()
        return path
    }()
}
