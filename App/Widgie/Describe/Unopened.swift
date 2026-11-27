import SwiftUI

/// The widget the chat was to open could not be put into the preview, so there is nothing to refine: a grey
/// Widgie at a broken bridge, the one line, and a way out.
struct Unopened: View {
    let failure: DescribeSession.Failure
    let leave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            BrokenBridge()
            Text(failure.title)
                .font(size: 30, weight: .heavy, relativeTo: .title)
                .tracking(-1)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.failureText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
            Button("Close", action: leave)
                .buttonStyle(KeyButtonStyle())
                .padding(.horizontal, 32)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.failureGround.ignoresSafeArea())
        .onAppear { AccessibilityNotification.Announcement(failure.title).post() }
    }
}

/// A bridge with a gap in it, and the caret bent over the gap.
private struct BrokenBridge: View {
    var body: some View {
        let width: CGFloat = 338
        let deck: CGFloat = 170
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let round = StrokeStyle(lineWidth: 5, lineCap: .round)
                var span = Path()
                span.move(to: CGPoint(x: -8, y: deck))
                span.addLine(to: CGPoint(x: width * 0.46, y: deck))
                span.move(to: CGPoint(x: width * 0.66, y: deck))
                span.addLine(to: CGPoint(x: width + 8, y: deck))
                context.stroke(span, with: .color(Palette.failureCaret), style: round)
                var ends = Path()
                ends.move(to: CGPoint(x: width * 0.46, y: deck))
                ends.addLine(to: CGPoint(x: width * 0.46 + 9, y: deck + 18))
                ends.move(to: CGPoint(x: width * 0.66, y: deck))
                ends.addLine(to: CGPoint(x: width * 0.66 - 8, y: deck + 17))
                context.stroke(
                    ends, with: .color(Palette.failureCaret.opacity(0.5)),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            }
            let size: CGFloat = 190
            let foot = Caret.foot(.slump)
            Caret(pose: .slump, size: size, color: Palette.failureCaret, eye: Palette.failureGround)
                .position(x: width * 0.36 + size * (0.5 - foot.x), y: deck + size * (0.5 - foot.y))
        }
        .frame(width: width, height: deck + 24)
        .accessibilityHidden(true)
    }
}
