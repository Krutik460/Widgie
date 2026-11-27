import SwiftUI
import WidgetEngine

/// "9 widgets · 6 on Home Screen", with a phone mark before the second half. It wraps onto two lines when the
/// text is large.
struct CountLine: View {
    let widgets: Int
    let placed: Int

    @ScaledMetric(relativeTo: .subheadline) private var mark: CGFloat = 15

    var body: some View {
        let total = widgets == 1 ? "1 widget" : "\(widgets) widgets"
        let count = Text(total)
            .font(size: 14, weight: .semibold, relativeTo: .subheadline)
            .foregroundStyle(Palette.text)
        let home = HStack(spacing: 3) {
            PhoneMark().frame(width: mark, height: mark)
            Text("\(placed) on Home Screen")
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                count
                Text("·").padding(.horizontal, 6).foregroundStyle(Palette.secondary.opacity(0.9))
                home
            }
            .lineLimit(1)
            VStack(alignment: .leading, spacing: 4) {
                count
                home.fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(size: 14, weight: .medium, relativeTo: .subheadline)
        .foregroundStyle(Palette.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(total), \(placed) on your home screen")
    }
}

/// A phone with two little widgets on its screen: "on your home screen".
struct PhoneMark: View {
    var body: some View {
        Canvas { context, size in
            let grid = IconGrid(size)
            context.stroke(grid.box(5, 2, 14, 20, 3.4), with: .foreground, lineWidth: 1.9 * grid.unit)
            context.fill(grid.box(7.8, 5.5, 3.8, 3.8, 1), with: .foreground)
            context.fill(grid.box(12.4, 5.5, 3.8, 3.8, 1), with: .foreground)
            context.opacity = 0.55
            context.fill(grid.box(7.8, 10.3, 8.4, 3.2, 1), with: .foreground)
        }
        .accessibilityHidden(true)
    }
}

/// A live face and its caption: the name, the New tag on the newest widget, and a mark when it is on the home
/// screen. A tap on one of the face's own buttons runs it, and a tap anywhere else opens the widget with a little
/// squish of the face, so where the whole face is one button (a countdown, whose tap sets its date) only the
/// caption opens it. VoiceOver reads the caption first, the one element that opens the widget, and then each of
/// the face's buttons.
struct FeedCard: View {
    let item: Library.Item
    let family: Family
    let size: CGSize
    let placed: Bool
    let fresh: Bool
    let tap: @MainActor @Sendable (Tap) -> Void
    let form: @MainActor @Sendable (Tap) -> Void
    let open: () -> Void
    let change: () -> Void

    /// Counts the taps that opened the widget, each of which squishes the face.
    @State private var opens = 0
    @ScaledMetric(relativeTo: .subheadline) private var mark: CGFloat = 18
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            FaceTile(face: item.faces[family], size: size, host: .app(tap: tap, form: form))
                .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : opens) { face, scale in
                    face.scaleEffect(scale)
                } keyframes: { _ in
                    CubicKeyframe(0.965, duration: 0.08)
                    SpringKeyframe(1, duration: 0.3, spring: .init(duration: 0.3, bounce: 0.45))
                }
            caption
        }
        .frame(width: size.width)
        .contentShape(Rectangle())
        // A tap gesture, not a button around the face, which would fold the face's own buttons into one element for
        // VoiceOver. Nothing tracks the press, since that blocks the feed's scrolling, the context menu or the tap,
        // so the squish plays on the tap and a hold gets the context menu's own lift.
        .onTapGesture {
            opens += 1
            open()
        }
        .accessibilityElement(children: .contain)
    }

    private var caption: some View {
        HStack(spacing: 6) {
            Text(item.summary.name)
                .font(size: 15, weight: .semibold, relativeTo: .subheadline)
                .tracking(-0.2)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            if fresh {
                Text("New")
                    .font(size: 12, weight: .bold, relativeTo: .caption)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.sun))
                    .fixedSize()
            }
            Spacer(minLength: 4)
            if placed {
                PhoneMark()
                    .frame(width: mark, height: mark)
                    .foregroundStyle(Palette.secondary)
            }
        }
        .frame(minHeight: 22)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: "Change it", change)
        .accessibilitySortPriority(1)
    }

    private var label: String {
        let parts: [String?] = [item.summary.name, fresh ? "new" : nil, placed ? "on your home screen" : nil]
        return parts.compactMap(\.self).joined(separator: ", ")
    }
}
