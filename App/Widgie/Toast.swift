import SwiftUI

/// A line that drops in at the top of the screen for a moment, with a happy Widgie: "Hearts for Sam is in your
/// widgets." VoiceOver reads it out as it comes.
struct Toast: Identifiable, Equatable {
    let id: Int
    let words: String
    /// Shown on Make, it sits below Make's bar and leaves when Make does.
    let low: Bool

    static let shownFor = Duration.milliseconds(2400)
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            avatar
            Text(toast.words)
                .font(size: 15, weight: .semibold, relativeTo: .subheadline)
                .tracking(-0.15)
                .foregroundStyle(Palette.toastText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .frame(minWidth: 248, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            shape.fill(Palette.toast)
                .overlay { shape.strokeBorder(Palette.toastEdge, lineWidth: 0.5) }
                .liftShadow()
        }
        .frame(maxWidth: 362)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toast.words)
        .onAppear { AccessibilityNotification.Announcement(toast.words).post() }
    }

    /// Widgie's happy face in a small rounded square of sky.
    private var avatar: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Caret(size: 92, alive: false, grounded: false, happy: true)
            .offset(x: -28, y: -1)
            .frame(width: 36, height: 36, alignment: .topLeading)
            .background {
                LinearGradient(
                    colors: [Palette.toastSkyTop, Palette.toastSkyBottom],
                    startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1))
            }
            .clipShape(shape)
            .restShadow()
    }
}
