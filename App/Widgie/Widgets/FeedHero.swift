import SwiftUI
import WidgetEngine

/// Where Widgie stands on the feed's first row: on the right card of a pair, on a wide card clear of the count
/// line, or on a lone small, talking toward the empty half of the row.
enum Perch: Equatable {
    case wide(WidgetID)
    case right(WidgetID)
    case lone(WidgetID)

    init?(_ row: FeedRow<WidgetID>?) {
        switch row {
        case .wide(let id): self = .wide(id)
        case .pair(_, let right?): self = .right(right)
        case .pair(let lone, nil): self = .lone(lone)
        case nil: return nil
        }
    }

    var id: WidgetID {
        switch self {
        case .wide(let id), .right(let id), .lone(let id): id
        }
    }

    /// The side of Widgie its bubble sits on. Widgie leans toward it.
    var bubble: Caret.Side {
        if case .lone = self { .right } else { .left }
    }

    /// Where Widgie's foot stands across a column this wide. With `large` text Widgie stands near the edge, so its
    /// bubble gets the most room.
    func x(column: CGFloat, small: CGFloat, large: Bool) -> CGFloat {
        switch self {
        case .wide: large ? column - 44 : (column * 214 / 362).rounded()
        case .right: column - small / 2
        case .lone: ((large ? 0.3 : 0.7) * small).rounded()
        }
    }

    /// The widest Widgie's bubble grows, given where Widgie stands.
    func bubbleWidth(column: CGFloat, x: CGFloat, large: Bool) -> CGFloat {
        switch self {
        case .wide: large ? x - 31 : 176
        case .right: large ? x - 31 : 236
        case .lone: column - x - 31
        }
    }

    /// The room between the count line and the first row. A wide card's perch sits under the count line, so it
    /// needs more.
    var room: CGFloat {
        if case .wide = self { 124 } else { 102 }
    }
}

/// Something Widgie does once on the feed. A new serial replays it.
struct HeroAct: Equatable {
    enum Kind: Equatable {
        case rest, hop, smallHop, glance, blink
        /// A hop from the old perch, this far away, to the new one.
        case move(CGSize)
    }

    var kind = Kind.rest
    var serial = 0
    var at = Date.distantPast

    mutating func play(_ kind: Kind) {
        self.kind = kind
        serial += 1
        at = .now
    }
}

/// Widgie on the feed: what it acts out, what it says in place of its greeting, and whether it is speaking. The
/// feed drives it, and only the views that draw Widgie read it, so an idle beat or a new line never rebuilds the
/// feed.
@MainActor @Observable
final class FeedWidgie {
    private(set) var act = HeroAct()
    /// A line said for a moment in place of the greeting.
    private(set) var said: String?
    /// Quiet until it has settled in, and while it hops between perches.
    private(set) var speaking = false
    var bubbleHeight: CGFloat = 42

    @ObservationIgnored private var saying: Task<Void, Never>?
    @ObservationIgnored private var hops = 0
    /// Where Widgie last stood in view. It hops from there when the first row has changed.
    @ObservationIgnored private var perchedAt: CGPoint?

    /// What the bubble shows: the line of the moment, else the greeting, and nothing while Widgie is quiet.
    func words(greeting: String) -> String? {
        speaking ? said ?? greeting : nil
    }

    func play(_ kind: HeroAct.Kind) {
        act.play(kind)
    }

    /// Settled in: Widgie starts talking, unless a hop already holds its voice.
    func wake() {
        if hops == 0 { speaking = true }
    }

    /// Hops from where Widgie last stood to `new`, and speaks again once it lands. Returns whether it hopped.
    @discardableResult func hop(to new: CGPoint?, reduceMotion: Bool) -> Bool {
        guard let new else { return false }
        let old = perchedAt
        perchedAt = new
        guard let old, old != new, !reduceMotion else { return false }
        act.play(.move(CGSize(width: old.x - new.x, height: old.y - new.y)))
        hops += 1
        let hop = hops
        speaking = false
        Task {
            try? await Task.sleep(for: .milliseconds(560))
            if hops == hop { speaking = true }
        }
        return true
    }

    /// Says `line` for a while, then goes back to the greeting.
    func say(_ line: String, for seconds: Double) {
        saying?.cancel()
        said = line
        saying = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            said = nil
        }
    }

    /// How VoiceOver reads the bubble: nothing from a page that is not showing, the greeting after whatever it is
    /// saying, and a reply at once.
    func voice(active: Bool) -> Bubble.Voice {
        !active ? .silent : said == nil ? .low : .normal
    }
}

/// The room above the first row where Widgie stands, with its bubble beside it.
struct FeedStage: View {
    let widgie: FeedWidgie
    let perch: Perch
    let point: CGPoint
    let column: CGFloat
    /// The name of the widget Widgie stands on.
    let name: String?
    /// Whether Widgets is the chosen tab.
    let active: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // How far the bubble's top sits above the first row: 82 points, or more for a bubble of many lines.
        let lift = max(82, widgie.bubbleHeight + 12)
        let height = max(perch.room, lift + 20)
        let side = perch.bubble
        let sole = Caret.sole(.lean(side))
        // An overlay, so Widgie, who stands taller than the room, never pushes the first row down.
        Color.clear.frame(height: height)
            .overlay(alignment: .topLeading) {
                TimelineView(.everyMinute) { timeline in
                    Bubble(
                        words: widgie.words(greeting: Speech.greeting(name, Daypart(timeline.date))),
                        tail: side == .left ? .right : .left, voice: widgie.voice(active: active))
                }
                .frame(maxWidth: perch.bubbleWidth(column: column, x: point.x, large: typeSize.isAccessibilitySize))
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: { height in
                    if height > 0 { widgie.bubbleHeight = max(42, height) }
                }
                .frame(width: side == .left ? point.x - 31 : nil, alignment: .trailing)
                .padding(.leading, side == .left ? 0 : point.x + 31)
                .padding(.top, height - lift)
            }
            .overlay(alignment: .bottomLeading) {
                FeedHero(leaning: side, act: widgie.act, alive: active)
                    .offset(x: point.x - sole.x * FeedHero.size, y: 2 - (sole.y - 1) * FeedHero.size)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The big Widgie of an empty feed, asking for a widget.
struct EmptyHero: View {
    let widgie: FeedWidgie
    let active: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            TimelineView(.everyMinute) { timeline in
                Bubble(
                    words: widgie.words(greeting: Speech.greeting(nil, Daypart(timeline.date))), tail: .right,
                    voice: widgie.voice(active: active))
            }
            .frame(maxWidth: 212, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 18)
            HoppingCaret(pose: .lean(.left), size: 190, alive: active, cue: widgie.act.serial)
                .padding(.trailing, -24)
        }
    }
}

/// Widgie standing on a point with its foot planted 2 points into the face below, a small contact shadow under
/// it, swaying and acting out each `act`. Still with Reduce Motion.
struct FeedHero: View {
    let leaning: Caret.Side
    let act: HeroAct
    /// Whether it blinks and fidgets between acts.
    var alive = true
    /// Stretched tall with happy eyes instead of leaning, as on a saved draft.
    var jumping = false

    static let size: CGFloat = 116

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Motion {
        var offset = CGSize.zero
        var lift: CGFloat = 0
        var stretch = CGSize(width: 1, height: 1)
        var turn: Double = 0
        var shadow: Double = 1
    }

    private var pose: Caret.Pose { jumping ? .jump : .lean(leaning) }

    var body: some View {
        let sole = Caret.sole(pose)
        let size = Self.size
        KeyframeAnimator(initialValue: Motion(), trigger: reduceMotion ? HeroAct() : act) { motion in
            ZStack(alignment: .topLeading) {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [.black.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 18)
                    )
                    .frame(width: 36, height: 5)
                    .offset(x: sole.x * size - 18, y: sole.y * size - 2)
                    .opacity(motion.shadow)
                Caret(
                    pose: pose, size: size, alive: alive, grounded: false,
                    blinked: act.kind == .blink ? act.at : .distantPast
                )
                .scaleEffect(x: motion.stretch.width, y: motion.stretch.height, anchor: sole)
                .rotationEffect(.degrees(motion.turn), anchor: sole)
                .offset(x: motion.offset.width, y: motion.offset.height - motion.lift)
            }
            .frame(width: size, height: size, alignment: .topLeading)
        } keyframes: { _ in
            let big = act.kind == .hop
            KeyframeTrack(\.offset) {
                if case .move(let from) = act.kind {
                    MoveKeyframe(from)
                    CubicKeyframe(CGSize(width: from.width / 2, height: from.height / 2), duration: 0.252)
                    CubicKeyframe(.zero, duration: 0.218)
                } else {
                    LinearKeyframe(.zero, duration: 0.01)
                }
            }
            KeyframeTrack(\.lift) {
                switch act.kind {
                case .hop, .smallHop:
                    CubicKeyframe(0, duration: 0.086)
                    CubicKeyframe(big ? 30 : 16, duration: 0.202)
                    CubicKeyframe(0, duration: 0.158)
                case .move:
                    CubicKeyframe(40, duration: 0.252)
                    CubicKeyframe(0, duration: 0.218)
                case .rest, .blink, .glance:
                    LinearKeyframe(0, duration: 0.01)
                }
            }
            KeyframeTrack(\.stretch) {
                switch act.kind {
                case .hop, .smallHop:
                    CubicKeyframe(CGSize(width: big ? 1.1 : 1.06, height: big ? 0.88 : 0.92), duration: 0.086)
                    CubicKeyframe(CGSize(width: big ? 0.94 : 0.96, height: big ? 1.08 : 1.05), duration: 0.202)
                    CubicKeyframe(CGSize(width: big ? 1.06 : 1.04, height: big ? 0.93 : 0.95), duration: 0.158)
                    CubicKeyframe(CGSize(width: 0.98, height: 1.02), duration: 0.13)
                    SpringKeyframe(CGSize(width: 1, height: 1), duration: 0.144)
                case .move:
                    LinearKeyframe(CGSize(width: 1, height: 1), duration: 0.47)
                    MoveKeyframe(CGSize(width: 1.08, height: 0.9))
                    SpringKeyframe(CGSize(width: 1, height: 1), duration: 0.2)
                case .rest, .blink, .glance:
                    LinearKeyframe(CGSize(width: 1, height: 1), duration: 0.01)
                }
            }
            KeyframeTrack(\.turn) {
                if act.kind == .glance {
                    CubicKeyframe(-7, duration: 0.42)
                    CubicKeyframe(-7, duration: 0.56)
                    CubicKeyframe(0, duration: 0.42)
                } else {
                    LinearKeyframe(0, duration: 0.01)
                }
            }
            KeyframeTrack(\.shadow) {
                if case .move = act.kind {
                    LinearKeyframe(0, duration: 0.118)
                    LinearKeyframe(0, duration: 0.324)
                    LinearKeyframe(1, duration: 0.118)
                } else {
                    LinearKeyframe(1, duration: 0.01)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
