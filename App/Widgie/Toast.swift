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

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            avatar
            Text(toast.words)
                .font(size: 15, weight: .semibold, relativeTo: .subheadline)
                .tracking(-0.15)
                .foregroundStyle(night ? .white : Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .frame(minWidth: 248, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            shape.fill(night ? Color(red: 24 / 255, green: 46 / 255, blue: 84 / 255).opacity(0.96) : .white)
                .overlay { if night { shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5) } }
                .liftShadow()
        }
        .frame(maxWidth: 362)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toast.words)
        .onAppear { AccessibilityNotification.Announcement(toast.words).post() }
    }

    private var night: Bool { scheme == .dark }

    /// Widgie's happy face in a small rounded square of sky.
    private var avatar: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Caret(size: 92, alive: false, grounded: false, happy: true)
            .offset(x: -28, y: -1)
            .frame(width: 36, height: 36, alignment: .topLeading)
            .background {
                LinearGradient(
                    colors: night
                        ? [
                            Color(red: 0x3A / 255, green: 0x5D / 255, blue: 0x96 / 255),
                            Color(red: 0x28 / 255, green: 0x4A / 255, blue: 0x7C / 255),
                        ]
                        : [
                            Color(red: 0xD8 / 255, green: 0xE8 / 255, blue: 0xFD / 255),
                            Color(red: 0xB0 / 255, green: 0xCF / 255, blue: 0xF7 / 255),
                        ],
                    startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1))
            }
            .clipShape(shape)
            .restShadow()
    }
}
