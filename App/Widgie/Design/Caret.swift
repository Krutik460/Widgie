import SwiftUI

/// Widgie: the text cursor come alive. One round-capped stroke with two eyes and blush cheeks, acting only
/// through posture (`docs/design/app-feel/c2-caret-sky.html`). Each pose is one cubic curve in a unit square,
/// so a spring morphs any pose into any other.
struct Caret: View {
    enum Side {
        case left, right
    }

    enum Pose: Equatable {
        /// Standing, blinking: waiting for words.
        case idle
        /// Leaning toward the text on that side: listening.
        case lean(Side)
        /// Tilted like a pencil with its foot on the line it draws, the top toward `side`.
        case draw(Side)
        /// Stretched tall with happy eyes: saved.
        case jump
        /// Bent over with its eyes shut: the builder could not be reached.
        case slump
    }

    var pose: Pose = .idle
    /// The side of the square the caret is drawn in. The foot sits near the bottom.
    var size: CGFloat
    var color = Palette.caret
    var eye = Palette.caretEye
    /// Whether it blinks and fidgets. Off for the small marks, which stand still like a glyph.
    var alive = true
    /// Whether it stands on the ground with a shadow, as opposed to sitting in a line of text.
    var grounded = true
    /// Points above the ground, and the vertical scale about the foot, for the jump on Saved.
    var lift: CGFloat = 0
    var squash: CGFloat = 1
    /// Happy eyes and fuller cheeks in any pose, as the jump has.
    var happy = false
    /// When it last blinked twice on cue, as Widgie does now and then on the feed.
    var blinked = Date.distantPast

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the foot is in the square, so a caller can stand it on a point.
    static func foot(_ pose: Pose) -> UnitPoint {
        let curve = Curve(pose)
        return UnitPoint(x: curve.p[0], y: curve.p[1])
    }

    /// The bottom of the foot's round cap, which reaches below the square: the point that touches the ground.
    static func sole(_ pose: Pose) -> UnitPoint {
        let curve = Curve(pose)
        return UnitPoint(x: curve.p[0], y: curve.p[1] + curve.width / 2)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !alive)) { timeline in
            let time = reduceMotion || !alive ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Figure(
                curve: Curve(pose), cheeks: happy ? Caret.Pose.jump.cheeks : pose.cheeks, eyes: eyes,
                blink: blink(at: time),
                turn: turn(at: time), size: size, color: color, eye: eye, grounded: grounded, lift: lift, squash: squash
            )
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.3), value: pose)
        .accessibilityHidden(true)
    }

    private var eyes: Pose.Eyes { happy ? .happy : pose.eyes }

    /// How open the eyes are: shut for the last 140 ms of every 3.6 seconds, so a still caret, whose time is
    /// zero, has them open, and shut twice in the 600 ms after a cue.
    private func blink(at time: TimeInterval) -> CGFloat {
        guard eyes == .open else { return 1 }
        let since = time - blinked.timeIntervalSinceReferenceDate
        if (0.07..<0.17).contains(since) || (0.31..<0.41).contains(since) { return 0.15 }
        let phase = time.truncatingRemainder(dividingBy: 3.6)
        return phase > 3.6 - 0.14 ? 0.15 : 1
    }

    /// A small turn about the foot: the scribble while drawing, a slow sway otherwise.
    private func turn(at time: TimeInterval) -> Angle {
        switch pose {
        case .draw: .degrees(3.2 * sin(time * 15))
        case .idle, .lean: .degrees(1.6 * sin(time * 1.7))
        case .jump, .slump: .zero
        }
    }
}

extension Caret.Pose {
    fileprivate enum Eyes {
        case open, happy, shut
    }

    fileprivate var eyes: Eyes {
        switch self {
        case .jump: .happy
        case .slump: .shut
        case .idle, .lean, .draw: .open
        }
    }

    /// The cheeks' scale: bigger when happy, gone when slumped.
    fileprivate var cheeks: CGFloat {
        switch self {
        case .jump: 1.3
        case .slump: 0
        case .idle, .lean, .draw: 1
        }
    }
}

/// The stroke's four control points (x0 y0 ... x3 y3) in the unit square and its width.
private struct Curve: VectorArithmetic {
    var p: SIMD8<Double>
    var width: Double

    init(p: SIMD8<Double>, width: Double) {
        self.p = p
        self.width = width
    }

    /// Measured from the mock's SVG paths, scaled so the standing caret spans 78% of the square.
    init(_ pose: Caret.Pose) {
        switch pose {
        case .idle: self.init(p: [0.5, 0.94, 0.5, 0.68, 0.5, 0.42, 0.5, 0.16], width: 0.17)
        case .lean(let side): self.init(p: [0.42, 0.94, 0.42, 0.578, 0.484, 0.296, 0.581, 0.16], width: 0.177, side)
        case .draw(let side): self.init(p: [0.22, 0.94, 0.339, 0.644, 0.474, 0.364, 0.576, 0.16], width: 0.186, side)
        case .jump: self.init(p: [0.5, 0.94, 0.528, 0.626, 0.472, 0.383, 0.5, 0.16], width: 0.153)
        case .slump: self.init(p: [0.35, 0.94, 0.337, 0.497, 0.565, 0.32, 0.628, 0.56], width: 0.175)
        }
    }

    /// The right-leaning shape, mirrored for the left.
    private init(p: SIMD8<Double>, width: Double, _ side: Caret.Side) {
        var p = p
        if side == .left {
            for index in stride(from: 0, to: 8, by: 2) { p[index] = 1 - p[index] }
        }
        self.init(p: p, width: width)
    }

    static var zero: Curve { Curve(p: .zero, width: 0) }
    static func + (a: Curve, b: Curve) -> Curve { Curve(p: a.p + b.p, width: a.width + b.width) }
    static func - (a: Curve, b: Curve) -> Curve { Curve(p: a.p - b.p, width: a.width - b.width) }
    mutating func scale(by rhs: Double) {
        p *= rhs
        width *= rhs
    }
    var magnitudeSquared: Double { (p * p).sum() + width * width }

    func point(_ index: Int) -> CGPoint { CGPoint(x: p[index * 2], y: p[index * 2 + 1]) }
}

/// One frame of the caret. Its curve, cheeks, and lift interpolate, so pose changes morph.
private struct Figure: View, Animatable {
    var curve: Curve
    var cheeks: CGFloat
    let eyes: Caret.Pose.Eyes
    let blink: CGFloat
    let turn: Angle
    let size: CGFloat
    let color: Color
    let eye: Color
    /// Whether it stands on the ground with a shadow, as opposed to sitting in a line of text.
    let grounded: Bool
    var lift: CGFloat
    let squash: CGFloat

    nonisolated var animatableData: AnimatablePair<Curve, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(curve, AnimatablePair(cheeks, lift)) }
        set {
            curve = newValue.first
            cheeks = newValue.second.first
            lift = newValue.second.second
        }
    }

    var body: some View {
        // The round foot cap reaches below the square, and the draw pose's tip past its side, so the canvas
        // overhangs the frame the caret takes in layout instead of clipping them.
        let overhang = size * 0.25
        Canvas { context, _ in
            context.translateBy(x: overhang, y: overhang)
            draw(in: &context)
        }
        .padding(-overhang)
        // Decoration only: the overhanging canvas must not catch taps meant for the field or menu beside it.
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext) {
        let foot = curve.point(0).scaled(size)
        let width = curve.width * size
        // Stands the point on the foot: squashed, lifted, and turned about it.
        let rotation = CGAffineTransform(rotationAngle: turn.radians)
        func place(_ unit: CGPoint) -> CGPoint {
            let point = unit.scaled(size)
            let local = CGPoint(x: point.x - foot.x, y: (point.y - foot.y) * squash).applying(rotation)
            return CGPoint(x: foot.x + local.x, y: foot.y + local.y - lift)
        }
        let points = (0..<4).map { place(curve.point($0)) }

        if grounded {
            let rise = min(1, lift / (size * 0.4))
            let shadow = CGSize(width: 3 * width * (1 - 0.4 * rise), height: 0.56 * width * (1 - 0.4 * rise))
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        origin: CGPoint(x: foot.x - shadow.width / 2, y: foot.y + 2 - shadow.height / 2), size: shadow)),
                with: .color(Palette.caretShadow.opacity(1 - 0.5 * rise)))
        }

        var body = Path()
        body.move(to: points[0])
        body.addCurve(to: points[3], control1: points[1], control2: points[2])
        context.stroke(body, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))

        func along(_ t: CGFloat) -> (center: CGPoint, normal: CGPoint) {
            let center = bezier(points, t)
            let tangent = derivative(points, t)
            let length = max(0.001, hypot(tangent.x, tangent.y))
            return (center, CGPoint(x: -tangent.y / length, y: tangent.x / length))
        }

        let face = along(0.88)
        let spread = 0.22 * width
        let rx = 0.134 * width
        let ry = 0.169 * width
        for sign in [-1.0, 1.0] {
            let center = CGPoint(
                x: face.center.x + sign * face.normal.x * spread, y: face.center.y + sign * face.normal.y * spread)
            switch eyes {
            case .open:
                let height = 2 * ry * blink
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - height / 2, width: 2 * rx, height: height)),
                    with: .color(eye))
            case .happy, .shut:
                var arc = Path()
                let bend = eyes == .happy ? -1.6 * ry : 1.1 * ry
                arc.move(to: CGPoint(x: center.x - 1.35 * rx, y: center.y))
                arc.addQuadCurve(
                    to: CGPoint(x: center.x + 1.35 * rx, y: center.y), control: CGPoint(x: center.x, y: center.y + bend)
                )
                context.stroke(
                    arc, with: .color(eye), style: StrokeStyle(lineWidth: max(1, 0.1 * width), lineCap: .round))
            }
        }

        guard cheeks > 0.01, size >= 40 else { return }
        let blush = along(0.77)
        let cheek = CGSize(width: 0.28 * width * cheeks, height: 0.19 * width * cheeks)
        for sign in [-1.0, 1.0] {
            let center = CGPoint(
                x: blush.center.x + sign * blush.normal.x * 0.3 * width,
                y: blush.center.y + sign * blush.normal.y * 0.3 * width)
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        origin: CGPoint(x: center.x - cheek.width / 2, y: center.y - cheek.height / 2), size: cheek)),
                with: .color(Palette.cheek.opacity(0.95)))
        }
    }

    private func bezier(_ p: [CGPoint], _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return CGPoint(
            x: a * p[0].x + b * p[1].x + c * p[2].x + d * p[3].x, y: a * p[0].y + b * p[1].y + c * p[2].y + d * p[3].y)
    }

    private func derivative(_ p: [CGPoint], _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = 3 * u * u
        let b = 6 * u * t
        let c = 3 * t * t
        return CGPoint(
            x: a * (p[1].x - p[0].x) + b * (p[2].x - p[1].x) + c * (p[3].x - p[2].x),
            y: a * (p[1].y - p[0].y) + b * (p[2].y - p[1].y) + c * (p[3].y - p[2].y))
    }
}

extension CGPoint {
    fileprivate func scaled(_ factor: CGFloat) -> CGPoint { CGPoint(x: x * factor, y: y * factor) }
}

/// The caret hopping once each time `cue` changes: a squash, a lift of `height` points, a squash on touchdown,
/// and a turn of `turn` degrees about its foot toward something beside it. Still with Reduce Motion.
struct HoppingCaret: View {
    var pose: Caret.Pose = .idle
    let size: CGFloat
    var color = Palette.caret
    var eye = Palette.caretEye
    var grounded = true
    var happy = false
    var height: CGFloat = 16
    var turn: Double = 0
    /// Whether it blinks and fidgets between hops.
    var alive = true
    let cue: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Motion {
        var lift: CGFloat = 0
        var squash: CGFloat = 1
        var turn: Double = 0
    }

    var body: some View {
        let give = height / 250
        KeyframeAnimator(initialValue: Motion(), trigger: reduceMotion ? 0 : cue) { motion in
            Caret(
                pose: pose, size: size, color: color, eye: eye, alive: alive, grounded: grounded, lift: motion.lift,
                squash: motion.squash, happy: happy
            )
            .rotationEffect(.degrees(motion.turn), anchor: Caret.foot(pose))
        } keyframes: { _ in
            KeyframeTrack(\.squash) {
                CubicKeyframe(1 - give, duration: 0.09)
                CubicKeyframe(1 + 0.7 * give, duration: 0.2)
                CubicKeyframe(1 - 0.5 * give, duration: 0.16)
                SpringKeyframe(1, duration: 0.27)
            }
            KeyframeTrack(\.lift) {
                CubicKeyframe(0, duration: 0.09)
                CubicKeyframe(height, duration: 0.2)
                CubicKeyframe(0, duration: 0.16)
            }
            KeyframeTrack(\.turn) {
                CubicKeyframe(0, duration: 0.3)
                CubicKeyframe(turn, duration: 0.2)
                CubicKeyframe(0, duration: 0.24)
            }
        }
    }
}

/// The wordmark: "widgie" ending in the caret, the cursor after the last letter.
struct Wordmark: View {
    @ScaledMetric(relativeTo: .title2) private var bar: CGFloat = 38

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text("widgie")
                .font(size: 26, weight: .heavy, relativeTo: .title2)
                .tracking(-1)
            Caret(size: bar, alive: false, grounded: false)
                .padding(.leading, -bar * 0.29)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Widgie")
        .accessibilityAddTraits(.isHeader)
    }
}
