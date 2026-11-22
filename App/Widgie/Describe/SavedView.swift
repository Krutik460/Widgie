import SwiftUI
import WidgetEngine

/// After Save: the caret jumps in a burst of caret confetti, the widget, "Saved.", one line on putting it on
/// the home screen, and Done.
struct SavedScreen: View {
    let session: DescribeSession
    let done: () -> Void

    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let caret: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ZStack {
                        Confetti(burst: arrived)
                        KeyframeAnimator(initialValue: Hop(), trigger: arrived) { hop in
                            ZStack {
                                Caret(pose: .jump, size: Self.caret, lift: hop.lift, squash: hop.squash)
                                Motion().opacity(hop.lift > 20 ? 1 : 0)
                            }
                        } keyframes: { _ in
                            KeyframeTrack(\.lift) {
                                LinearKeyframe(0, duration: 0.16)
                                SpringKeyframe(Self.caret * 0.24, duration: 0.3, spring: .snappy)
                                CubicKeyframe(Self.caret * 0.24, duration: 0.08)
                                CubicKeyframe(0, duration: 0.24)
                                CubicKeyframe(0, duration: 0.3)
                            }
                            KeyframeTrack(\.squash) {
                                CubicKeyframe(0.86, duration: 0.16)
                                CubicKeyframe(1.1, duration: 0.3)
                                CubicKeyframe(1.04, duration: 0.08)
                                CubicKeyframe(0.9, duration: 0.24)
                                SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                            }
                        }
                    }
                    .frame(width: Column.width, height: Self.caret)
                    Impact()
                        .frame(width: Column.width + 28, height: 26)
                        .padding(.top, -8)
                    if let face = session.preview.faces[.medium] {
                        FaceView(face, host: .app(tap: { _ in }, form: { _ in }))
                            .allowsHitTesting(false)
                            .frame(width: Family.medium.standardSize.width, height: Family.medium.standardSize.height)
                            .faceShadow()
                            .padding(.top, -6)
                    }
                    Text("Saved.")
                        .font(size: 60, weight: .heavy, relativeTo: .largeTitle)
                        .tracking(-2)
                        .padding(.top, 34)
                    Text(
                        session.editing == nil
                            ? "Press and hold your home screen, then tap Edit to add it."
                            : "Your home screen shows the change."
                    )
                    .font(size: 18, weight: .semibold)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.horizontal, 8)
                }
                .frame(width: Column.width)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            Button("Done", action: done)
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: Column.width)
                .padding(.bottom, 8)
        }
        .onAppear {
            guard !reduceMotion else { return }
            arrived = true
        }
    }

    private struct Hop {
        var lift: CGFloat = 0
        var squash: CGFloat = 1
    }

    /// Three short lines under the caret while it is in the air.
    private struct Motion: View {
        var body: some View {
            Canvas { context, size in
                let mid = size.width / 2
                var lines = Path()
                for (x, top, bottom) in [(-27.0, 0.74, 0.88), (27.0, 0.74, 0.88), (0.0, 0.78, 0.95)] {
                    lines.move(to: CGPoint(x: mid + x, y: size.height * top))
                    lines.addLine(to: CGPoint(x: mid + x, y: size.height * bottom))
                }
                context.stroke(
                    lines, with: .color(Palette.caret.opacity(0.45)),
                    style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            }
            .accessibilityHidden(true)
        }
    }

    /// The tick marks at the widget's top corners, where the landing lands.
    private struct Impact: View {
        var body: some View {
            Canvas { context, size in
                var ticks = Path()
                for (from, to) in [
                    ((10.0, 24.0), (0.0, 14.0)), ((26.0, 14.0), (22.0, 0.0)),
                    (
                        (size.width - 10, 24.0), (size.width, 14.0)
                    ), ((size.width - 26, 14.0), (size.width - 22, 0.0)),
                ] {
                    ticks.move(to: CGPoint(x: from.0, y: from.1))
                    ticks.addLine(to: CGPoint(x: to.0, y: to.1))
                }
                context.stroke(ticks, with: .color(Palette.caret), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            }
            .accessibilityHidden(true)
        }
    }
}

/// Little caret-shaped bars in the Pop colors that burst out once and settle around the caret. With Reduce
/// Motion they are simply there.
private struct Confetti: View {
    let burst: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Piece {
        let color: Color
        let angle: Double
        let distance: CGFloat
        let tilt: Double
        let length: CGFloat
    }

    /// A fixed scatter, so the burst looks the same every time. No angle points straight up or down, where the
    /// caret stands.
    private static let pieces: [Piece] = [
        200, 215, 160, 145, 330, 345, 15, 30, 185, 355, 230, 310, 130, 50, 172, 2,
    ].enumerated().map { index, degrees in
        Piece(
            color: Palette.pops[index % Palette.pops.count],
            angle: Double(degrees) * .pi / 180,
            distance: [118, 146, 128, 156, 110, 138][index % 6],
            tilt: [-28, 34, -12, 22, -38, 16, 40, -20][index % 8],
            length: [14, 18, 12, 16][index % 4])
    }

    var body: some View {
        let shown = burst || reduceMotion
        ZStack {
            ForEach(Array(Self.pieces.enumerated()), id: \.offset) { _, piece in
                RoundedRectangle(cornerRadius: 2)
                    .fill(piece.color)
                    .frame(width: 4, height: piece.length)
                    .rotationEffect(.degrees(shown ? piece.tilt : 0))
                    .offset(
                        x: shown ? cos(piece.angle) * piece.distance * 1.15 : 0,
                        y: shown ? sin(piece.angle) * piece.distance * 0.72 - 6 : 0
                    )
                    .opacity(shown ? 1 : 0)
            }
        }
        .animation(.easeOut(duration: 0.8).delay(0.42), value: burst)
        .accessibilityHidden(true)
    }
}
