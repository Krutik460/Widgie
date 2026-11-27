import SwiftUI

/// What each category shows: its chip and its banner, where Widgie acts the category out.
extension Template.Category {
    var title: String {
        switch self {
        case .forTwo: "For two"
        case .home: "Home"
        case .habits: "Habits"
        case .goals: "Goals"
        }
    }

    var line: String {
        switch self {
        case .forTwo: "Little signals for the two of you"
        case .home: "The jobs you share at home"
        case .habits: "See your weeks fill up"
        case .goals: "Little wins add up"
        }
    }

    var banner: Color {
        switch self {
        case .forTwo: Palette.bannerForTwo
        case .home: Palette.bannerHome
        case .habits: Palette.bannerHabits
        case .goals: Palette.bannerGoals
        }
    }
}

/// A category's glyph on its chip, filled on a 24 unit grid: a heart, a house, a leaf with its vein cut out, and a
/// star.
struct CategoryGlyph: Shape {
    let category: Template.Category

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        var path = Path()
        switch category {
        case .forTwo:
            path.move(to: point(12, 21))
            path.addCurve(to: point(2.4, 11.7), control1: point(12, 21), control2: point(4.5, 16.4))
            path.addCurve(to: point(6.6, 4.5), control1: point(0.9, 8.2), control2: point(3, 4.5))
            path.addCurve(to: point(12, 7.7), control1: point(8.7, 4.5), control2: point(10.2, 5.7))
            path.addCurve(to: point(17.4, 4.5), control1: point(13.8, 5.7), control2: point(15.3, 4.5))
            path.addCurve(to: point(21.6, 11.7), control1: point(21, 4.5), control2: point(23.1, 8.2))
            path.addCurve(to: point(12, 21), control1: point(19.5, 16.4), control2: point(12, 21))
        case .home:
            path.addLines(
                [
                    point(12, 3.2), point(2.8, 11), point(5.5, 11), point(5.5, 20.3), point(10.5, 20.3),
                    point(10.5, 15), point(13.5, 15), point(13.5, 20.3), point(18.5, 20.3), point(18.5, 11),
                    point(21.2, 11),
                ])
        case .habits:
            path.move(to: point(20.5, 3.5))
            path.addCurve(to: point(5, 14.2), control1: point(12, 3.5), control2: point(5, 7.6))
            path.addCurve(to: point(6.6, 18.8), control1: point(5, 16), control2: point(5.6, 17.6))
            for corner in [point(4, 21.4), point(5.4, 22.8), point(8, 20.2)] { path.addLine(to: corner) }
            path.addCurve(to: point(12.6, 21.8), control1: point(9.2, 21.2), control2: point(10.8, 21.8))
            path.addCurve(to: point(20.5, 3.5), control1: point(19.2, 21.8), control2: point(20.5, 12))
            path.closeSubpath()
            // The vein winds the other way from the leaf, so the nonzero fill cuts it out.
            path.move(to: point(9, 18.4))
            path.addCurve(to: point(17.4, 8.5), control1: point(10.7, 13.8), control2: point(13.6, 10.6))
            path.addCurve(to: point(10.6, 19), control1: point(14.4, 11.3), control2: point(12, 14.5))
        case .goals:
            path.addLines(
                [
                    point(12, 2.8), point(14.7, 8.8), point(21.2, 9.4), point(16.3, 13.7), point(17.8, 20.1),
                    point(12, 16.8), point(6.2, 20.1), point(7.7, 13.7), point(2.8, 9.4), point(9.3, 8.8),
                ])
        }
        path.closeSubpath()
        return path.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / 24, y: rect.height / 24))
    }
}

/// The category's banner: its line in the display face on its color, and Widgie acting it out on the right. The
/// color follows the chosen category at once; the line and the cast follow `shown`, which the page swaps after the
/// pile has scattered.
struct TemplateBanner: View {
    let chosen: Template.Category
    let shown: Template.Category
    /// Hidden while the pile scatters.
    let leaving: Bool
    /// Whether the cast acts as it comes on, which it does after a switch but not when the page first opens.
    let acting: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        // At the accessibility text sizes the line takes the banner's width and the cast stands under it.
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .trailing, spacing: 0) {
                    line.frame(maxWidth: .infinity, alignment: .leading)
                    cast
                }
            } else {
                ZStack(alignment: .bottomTrailing) {
                    cast
                    line
                        .frame(maxWidth: 168 + 2 * 22, alignment: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
        }
        .opacity(leaving ? 0 : 1)
        .offset(y: leaving && !reduceMotion ? 6 : 0)
        .frame(maxWidth: .infinity, minHeight: Cast.size.height)
        // Clips the cast and the line, not the background's shadow.
        .clipShape(shape)
        .background {
            shape
                .fill(chosen.banner)
                .overlay {
                    // A fixed light over the color, so a switch cross-fades only the hue.
                    ZStack {
                        LinearGradient(
                            colors: [.white.opacity(0.14), .black.opacity(0.06)], startPoint: .topLeading,
                            endPoint: .bottomTrailing)
                        RadialGradient(
                            colors: [.white.opacity(0.14), .clear], center: UnitPoint(x: 0.85, y: 1), startRadius: 0,
                            endRadius: 180)
                    }
                    .clipShape(shape)
                }
                .quietShadow()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: chosen)
    }

    private var cast: some View {
        Cast(category: shown, acting: acting)
            .id(shown)
            .frame(width: Cast.size.width, height: Cast.size.height)
            .padding(.trailing, 6)
            .accessibilityHidden(true)
    }

    private var line: some View {
        Balanced {
            Text(shown.line)
                .display(size: 27, relativeTo: .title, lineHeight: 1.02)
                .foregroundStyle(Palette.bannerText)
                .accessibilityAddTraits(.isHeader)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .id(shown)
    }
}

/// Widgie and its prop in a 196 by 136 box at the banner's right, standing on a floor 8 points above its bottom.
private struct Cast: View {
    static let size = CGSize(width: 196, height: 136)
    static let floor: CGFloat = 128

    let category: Template.Category
    let acting: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch category {
            case .forTwo:
                Actor(side: .right, size: 94, foot: 76, happy: true, acting: acting)
                Actor(side: .left, size: 94, foot: 146, acting: acting)
                Heartbeat().frame(width: 20, height: 20).position(x: 111, y: 22)
            case .home:
                Puppy().frame(width: 64, height: 60).position(x: 72, y: 106)
                Actor(side: .left, size: 112, foot: 138, acting: acting, turn: -6)
            case .habits:
                Actor(side: .right, size: 104, foot: 112, acting: acting, turn: 7)
                Squares(filling: acting).frame(width: 40, height: 40).rotationEffect(.degrees(6))
                    .position(x: 170, y: 104)
            case .goals:
                Actor(side: .right, size: 104, foot: 116, happy: true, acting: acting)
                Medal(swinging: acting).frame(width: 38, height: 50).position(x: 169, y: 95)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }
}

/// Widgie leaning toward `side`, the sole of its foot on the cast's floor at `foot`. As the banner comes on it hops,
/// and turns by `turn` degrees toward its prop. Still with Reduce Motion.
private struct Actor: View {
    let side: Caret.Side
    let size: CGFloat
    let foot: CGFloat
    var happy = false
    let acting: Bool
    var turn: Double = 0

    @State private var cue = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pose = Caret.Pose.lean(side)
        let sole = Caret.sole(pose)
        HoppingCaret(pose: pose, size: size, happy: happy, turn: turn, cue: cue)
            .position(
                x: foot + size * (0.5 - sole.x), y: Cast.floor + size * (0.5 - sole.y)
            )
            .task {
                guard acting, !reduceMotion else { return }
                cue += 1
            }
    }
}

/// A heart that beats, twice a breath. Still with Reduce Motion.
private struct Heartbeat: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let phase =
                reduceMotion
                ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
            let beat = phase < 0.2 ? phase / 0.2 : phase < 0.4 ? (0.4 - phase) / 0.2 : 0
            Image(systemName: "heart.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Palette.bannerHeart)
                .scaleEffect(1 + 0.18 * beat)
        }
    }
}

/// Luna, the landing page's puppy, looking up.
private struct Puppy: View {
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 64, y: size.height / 60)
            let ink = Color(red: 0x2B / 255, green: 0x1F / 255, blue: 0x14 / 255)
            let ear = Color(red: 0x8A / 255, green: 0x55 / 255, blue: 0x27 / 255)
            var left = Path()
            left.move(to: CGPoint(x: 12, y: 13))
            left.addCurve(to: CGPoint(x: 11, y: 41), control1: CGPoint(x: 2, y: 17), control2: CGPoint(x: 2, y: 37))
            left.addCurve(to: CGPoint(x: 17, y: 14), control1: CGPoint(x: 17, y: 37), control2: CGPoint(x: 19, y: 24))
            left.closeSubpath()
            context.fill(left, with: .color(ear))
            context.fill(left.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 64, ty: 0)), with: .color(ear))
            func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry))
            }
            context.fill(
                oval(32, 30, 20, 19), with: .color(Color(red: 0xF2 / 255, green: 0xB4 / 255, blue: 0x6B / 255)))
            context.fill(oval(32, 40, 11, 8.5), with: .color(Color(red: 1, green: 0xF1 / 255, blue: 0xDC / 255)))
            for x in [24.5, 39.5] {
                context.fill(oval(x, 27, 3, 3), with: .color(ink))
                context.fill(oval(x + 1.1, 25.8, 1, 1), with: .color(.white))
            }
            for x in [18.5, 45.5] {
                context.fill(
                    oval(x, 34.5, 3, 2), with: .color(Color(red: 1, green: 0x9A / 255, blue: 0xA8 / 255).opacity(0.85)))
            }
            context.fill(oval(32, 35.5, 4, 3), with: .color(ink))
            var mouth = Path()
            mouth.move(to: CGPoint(x: 32, y: 38.6))
            mouth.addLine(to: CGPoint(x: 32, y: 41))
            mouth.move(to: CGPoint(x: 28.4, y: 41.8))
            mouth.addQuadCurve(to: CGPoint(x: 35.6, y: 41.8), control: CGPoint(x: 32, y: 44.4))
            context.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .background(alignment: .bottom) { FloorShadow(width: 64).offset(y: -2) }
    }
}

/// Three habits by three days, one square still to fill, which fills as the banner comes on.
private struct Squares: View {
    let filling: Bool

    @State private var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 44, y: size.height / 44)
            for row in 0..<3 {
                for column in 0..<3 {
                    let index = row * 3 + column
                    let on = index == 5 ? filled : index % 4 != 1
                    let square = Path(
                        roundedRect: CGRect(x: column * 15, y: row * 15, width: 12, height: 12), cornerRadius: 3.5)
                    context.fill(square, with: .color(on ? Palette.squareOn : Palette.squareOff))
                }
            }
        }
        .background(alignment: .bottom) { FloorShadow(width: 44).offset(y: 10) }
        .task {
            guard filling, !reduceMotion else {
                filled = true
                return
            }
            try? await Task.sleep(for: .milliseconds(460))
            withAnimation(.easeOut(duration: 0.2)) { filled = true }
        }
    }
}

/// A gold medal on a two-color ribbon, which swings as the banner comes on.
private struct Medal: View {
    let swinging: Bool

    @State private var cue = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        KeyframeAnimator(initialValue: 0.0, trigger: cue) { angle in
            drawing.rotationEffect(.degrees(8 + angle), anchor: .top)
        } keyframes: { _ in
            CubicKeyframe(0, duration: 0.26)
            CubicKeyframe(-12, duration: 0.25)
            CubicKeyframe(6, duration: 0.24)
            CubicKeyframe(0, duration: 0.21)
        }
        .background(alignment: .bottom) { FloorShadow(width: 44).offset(y: 14) }
        .task {
            guard swinging, !reduceMotion else { return }
            cue += 1
        }
    }

    private var drawing: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 44, y: size.height / 58)
            let ink = Palette.ink.opacity(0.55)
            let gold = Color(red: 0xE8 / 255, green: 0xA4 / 255, blue: 0)
            func ribbon(_ points: [CGPoint], _ color: Color) {
                var path = Path()
                path.addLines(points)
                path.closeSubpath()
                context.fill(path, with: .color(color))
                context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            ribbon(
                [CGPoint(x: 8, y: 2), CGPoint(x: 19, y: 2), CGPoint(x: 25, y: 20), CGPoint(x: 14, y: 20)],
                Color(red: 1, green: 0x6B / 255, blue: 0x5C / 255))
            ribbon(
                [CGPoint(x: 36, y: 2), CGPoint(x: 25, y: 2), CGPoint(x: 19, y: 20), CGPoint(x: 30, y: 20)],
                Color(red: 0x9C / 255, green: 0xC3 / 255, blue: 0xF5 / 255))
            let disc = Path(ellipseIn: CGRect(x: 5, y: 21, width: 34, height: 34))
            context.fill(disc, with: .color(Color(red: 1, green: 0xD2 / 255, blue: 0x3C / 255)))
            context.stroke(disc, with: .color(ink), lineWidth: 2.4)
            context.stroke(
                Path(ellipseIn: CGRect(x: 10.5, y: 26.5, width: 23, height: 23)), with: .color(gold), lineWidth: 2)
            var star = Path()
            star.addLines(
                [
                    (22, 30.5), (24.3, 35.3), (29.5, 35.9), (25.6, 39.5), (26.7, 44.6), (22, 41.9), (17.3, 44.6),
                    (18.4, 39.5), (14.5, 35.9), (19.7, 35.3),
                ].map { CGPoint(x: $0.0, y: $0.1) })
            star.closeSubpath()
            context.fill(star, with: .color(gold))
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 4)
    }
}

/// A soft oval shadow on the banner floor under a prop.
private struct FloorShadow: View {
    let width: CGFloat

    var body: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [.black.opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: width / 2)
            )
            .frame(width: width, height: 12)
    }
}
