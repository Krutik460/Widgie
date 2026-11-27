import SwiftUI

extension View {
    /// A chat message coming in: it slides up 18 points from 94 percent, or only fades with Reduce Motion.
    func arriving() -> some View {
        modifier(Arriving())
    }
}

private struct Arriving: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .offset(y: 18).combined(with: .scale(scale: 0.94, anchor: .bottom)).combined(
                        with: .opacity),
                    removal: .opacity))
    }
}

/// Your words, in ink on the right, with the picture you sent.
struct YouSaid: View {
    let turn: DescribeSession.Turn

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let picture = turn.image {
                Thumbnail(picture: picture, size: 52)
            }
            Text(turn.words)
                .font(size: 15.5, weight: .semibold, relativeTo: .callout)
                .tracking(-0.15)
                .lineSpacing(2)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20,
                        style: .continuous
                    )
                    .fill(Palette.youFill)
                    .shadow(color: Palette.widgetShadow, radius: 10, y: 10)
                }
        }
        .frame(maxWidth: 262, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(turn.words)")
    }
}

/// Widgie's words in a white bubble on the left. While Widgie works the words end in the blinking bar, and VoiceOver
/// reads each new step politely, but nothing while you are on another tab.
struct WidgieSays: View {
    let words: String
    var working = false
    let voice: Bubble.Voice

    @Environment(\.pageHidden) private var pageHidden

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            Text(words)
                .contentTransition(.opacity)
            if working {
                CursorBar(color: Palette.ink, height: 17)
                    .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 3 }
            }
        }
        .font(size: 15.5, weight: .semibold, relativeTo: .callout)
        .tracking(-0.15)
        .lineSpacing(2)
        .foregroundStyle(Palette.ink)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 20, bottomLeadingRadius: 6, bottomTrailingRadius: 20, topTrailingRadius: 20,
                style: .continuous
            )
            .fill(Palette.bubble)
            .bubbleShadow()
        }
        .animation(.easeInOut(duration: 0.25), value: words)
        .frame(maxWidth: 262, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Widgie: \(words)")
        .accessibilityAddTraits(working ? .updatesFrequently : [])
        .announces(words, voice: pageHidden ? .silent : voice)
    }
}

/// What went wrong, from a grey Widgie slumped beside it, with the one way forward while it still applies.
struct WidgieFailed: View {
    let failure: DescribeSession.Failure
    let action: (title: String, run: () -> Void)?

    @Environment(\.pageHidden) private var pageHidden

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Caret(pose: .slump, size: 64, color: Palette.failureCaret, eye: Palette.failureGround, alive: false)
                .frame(width: 44, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.title)
                        .font(size: 15.5, weight: .semibold, relativeTo: .callout)
                        .tracking(-0.15)
                    #if DEBUG
                        if failure == .unreachable {
                            Text("Check that the bridge is running.")
                                .font(size: 13.5, weight: .medium, relativeTo: .footnote)
                                .opacity(0.75)
                        }
                    #endif
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Widgie: \(failure.title)")
                if let action {
                    Button(action.title, action: action.run)
                        .buttonStyle(
                            MiniButtonStyle(fill: Palette.failureButtonFill, label: Palette.failureButtonLabel))
                }
            }
            .foregroundStyle(Palette.failureText)
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 20, bottomLeadingRadius: 6, bottomTrailingRadius: 20, topTrailingRadius: 20,
                    style: .continuous
                )
                .fill(Palette.failureGround)
                .shadow(color: Palette.restShadow, radius: 12, y: 10)
            }
        }
        .frame(maxWidth: 310, alignment: .leading)
        .onAppear {
            if !pageHidden { AccessibilityNotification.Announcement(failure.title).post() }
        }
    }
}

/// The question before a draft goes, asked in the thread with the draft still in view. VoiceOver lands on Keep
/// editing.
struct Confirm: View {
    let question: Chat.Question
    let keep: () -> Void
    let replace: () -> Void

    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.words)
                .font(size: 14.5, weight: .semibold, relativeTo: .subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Keep editing", action: keep)
                    .buttonStyle(MiniButtonStyle())
                    .accessibilityFocused($focused)
                Button(question.replace, action: replace)
                    .buttonStyle(MiniButtonStyle(fill: Palette.keyFill, label: Palette.keyLabel))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface).restShadow())
        .accessibilityElement(children: .contain)
        .onAppear {
            AccessibilityNotification.Announcement(question.words).post()
            focused = true
        }
    }
}
