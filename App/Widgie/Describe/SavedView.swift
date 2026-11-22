import SwiftUI
import WidgetEngine

/// The celebration after Save: rays, a burst of confetti, Pip jumping, the widget bouncing in, and how to put
/// it on the home screen.
struct SavedScreen: View {
    let session: DescribeSession
    let done: () -> Void

    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            StepBar(step: .done)
                .padding(.horizontal, 18)
                .padding(.top, 2)
                .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 0) {
                    Mascot(mood: .cheering, size: 132)
                        .scaleEffect(arrived || reduceMotion ? 1 : 0.4)
                    Text(session.editing == nil ? "Widget saved!" : "Changes saved!")
                        .font(.largeTitle.weight(.black))
                        .shadow(color: .black.opacity(0.12), radius: 0, y: 3)
                        .padding(.top, 4)
                    Text(session.editing == nil ? "It's in your library now." : "Your home screen has it already.")
                        .font(.body.weight(.bold))
                        .opacity(0.9)
                        .padding(.top, 2)
                    if let face = session.preview.faces[.medium] {
                        FaceView(face, host: .app(tap: { _ in }, form: { _ in }))
                            .allowsHitTesting(false)
                            .frame(
                                width: Family.medium.standardSize.width, height: Family.medium.standardSize.height
                            )
                            .shadow(color: .black.opacity(0.18), radius: 0, y: 7)
                            .padding(.top, 22)
                            .offset(y: arrived || reduceMotion ? 0 : 60)
                            .opacity(arrived || reduceMotion ? 1 : 0)
                    }
                    if session.editing == nil {
                        HowTo().padding(.top, 26)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            Button("Continue", action: done)
                .buttonStyle(
                    ChunkyButtonStyle(
                        chunk: Chunk(
                            face: .white, lip: Color(rgb: 0x0A6FA8).opacity(0.55), text: Color(rgb: 0x0A7FC2)))
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
        }
        .background {
            ZStack {
                Rays().frame(width: 900, height: 900).offset(y: -170)
                Confetti(burst: arrived || reduceMotion)
            }
            .allowsHitTesting(false)
        }
        .foregroundStyle(.white)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.5)) { arrived = true }
        }
    }
}

/// The one line on adding the widget: hold the home screen, tap Edit, Add Widget, pick Widgie.
private struct HowTo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Put it on your home screen").font(.body.weight(.black))
            HStack(alignment: .top, spacing: 0) {
                step(Image(systemName: "hand.point.up.left.fill"), "Hold the home screen")
                arrow
                step(Text("Edit").font(.subheadline.weight(.black)), "Tap Edit")
                arrow
                step(Image(systemName: "plus"), "Add Widget")
                arrow
                step(Text("W").font(.headline.weight(.black)), "Pick Widgie", brand: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "To put it on your home screen, hold the home screen, tap Edit, tap Add Widget, and pick Widgie.")
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .black))
            .frame(height: 52)
            .frame(maxWidth: .infinity)
    }

    private func step(_ icon: some View, _ label: String, brand: Bool = false) -> some View {
        VStack(spacing: 6) {
            icon
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(brand ? .white : Color(rgb: 0x0A7FC2))
                .frame(width: 52, height: 52)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.15)).offset(y: 4)
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(
                            brand ? Color(rgb: 0xFF7A1A) : .white)
                    }
                }
            Text(label)
                .font(.footnote.weight(.heavy))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 70)
    }
}

/// Slow-turning rays behind the celebration, fading out from the middle.
private struct Rays: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let angle = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate / 30 * 360
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = max(size.width, size.height)
                for index in 0..<23 {
                    let start = Angle.degrees(Double(index) * 16)
                    var wedge = Path()
                    wedge.move(to: center)
                    wedge.addArc(
                        center: center, radius: radius, startAngle: start, endAngle: start + .degrees(8),
                        clockwise: false)
                    wedge.closeSubpath()
                    context.fill(wedge, with: .color(.white.opacity(0.16)))
                }
            }
            .rotationEffect(.degrees(angle.truncatingRemainder(dividingBy: 360)))
            .mask {
                RadialGradient(
                    stops: [.init(color: .black, location: 0.2), .init(color: .clear, location: 0.55)],
                    center: .center, startRadius: 0, endRadius: 450)
            }
        }
    }
}

/// Confetti that bursts out from behind Pip once, then rests where it landed.
private struct Confetti: View {
    let burst: Bool

    private struct Piece {
        let color: Color
        let size: CGSize
        let angle: Double
        let distance: CGFloat
        let spin: Double
    }

    private static let pieces: [Piece] = {
        let colors = [Color(rgb: 0xFFCB2E), Color(rgb: 0xFF7A1A), .white, Color(rgb: 0xF0384F)]
        var generator = SystemRandomNumberGenerator()
        return (0..<22).map { index in
            let round = index % 3 == 1
            return Piece(
                color: colors[index % colors.count],
                size: round ? CGSize(width: 10, height: 10) : CGSize(width: 11, height: 19),
                angle: Double(index) / 22 * 2 * .pi + Double.random(in: -0.12...0.12, using: &generator),
                distance: CGFloat.random(in: 120...190, using: &generator),
                spin: Double.random(in: -200...200, using: &generator))
        }
    }()

    var body: some View {
        ZStack {
            ForEach(Array(Self.pieces.enumerated()), id: \.offset) { _, piece in
                RoundedRectangle(cornerRadius: piece.size.width == piece.size.height ? 5 : 4)
                    .fill(piece.color)
                    .frame(width: piece.size.width, height: piece.size.height)
                    .rotationEffect(.degrees(burst ? piece.spin : 0))
                    .offset(
                        x: burst ? cos(piece.angle) * piece.distance : 0,
                        y: burst ? sin(piece.angle) * piece.distance : 0
                    )
                    .opacity(burst ? 1 : 0)
            }
        }
        .offset(y: 120)
        .animation(.easeOut(duration: 0.9), value: burst)
    }
}
