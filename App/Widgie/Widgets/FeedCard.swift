import SwiftUI
import WidgetEngine

/// "9 widgets · 6 on Home Screen", with a phone mark before the second half. It wraps onto two lines when the
/// text is large.
struct CountLine: View {
    let widgets: Int
    let placed: Int

    @ScaledMetric(relativeTo: .subheadline) private var mark: CGFloat = 15

    var body: some View {
        let count = Text(widgets == 1 ? "1 widget" : "\(widgets) widgets")
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
        .accessibilityLabel(
            "\(widgets == 1 ? "1 widget" : "\(widgets) widgets"), \(placed) on your home screen")
    }
}

/// A phone with two little widgets on its screen: "on your home screen".
struct PhoneMark: View {
    var body: some View {
        Canvas { context, size in
            let unit = size.width / 24
            func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ corner: Double) -> Path {
                Path(
                    roundedRect: CGRect(x: x * unit, y: y * unit, width: width * unit, height: height * unit),
                    cornerRadius: corner * unit, style: .continuous)
            }
            context.stroke(box(5, 2, 14, 20, 3.4), with: .foreground, lineWidth: 1.9 * unit)
            context.fill(box(7.8, 5.5, 3.8, 3.8, 1), with: .foreground)
            context.fill(box(12.4, 5.5, 3.8, 3.8, 1), with: .foreground)
            context.opacity = 0.55
            context.fill(box(7.8, 10.3, 8.4, 3.2, 1), with: .foreground)
        }
        .accessibilityHidden(true)
    }
}

/// A live face and its caption: the name, the New tag on the newest widget, and a mark when it is on the home
/// screen. The face squishes a little with a spring while pressed.
struct FeedCard: View {
    let item: Library.Item
    let family: Family
    let size: CGSize
    let placed: Bool
    var fresh = false
    let tap: @MainActor @Sendable (Tap) -> Void
    let form: @MainActor @Sendable (Tap) -> Void
    let open: () -> Void

    @ScaledMetric(relativeTo: .subheadline) private var mark: CGFloat = 18
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: open) {
                LiveFace(face: item.faces[family], size: size, tap: tap, form: form)
            }
            .buttonStyle(PressStyle())
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
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
        .frame(width: size.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var label: String {
        let parts: [String?] = [item.summary.name, fresh ? "new" : nil, placed ? "on your home screen" : nil]
        return parts.compactMap(\.self).joined(separator: ", ")
    }
}

/// Squishes a face to 96.5 percent with a spring while it is pressed. Still with Reduce Motion.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration)
    }
}

private struct PressBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.45), value: configuration.isPressed)
    }
}

/// A face drawn at `size`, its buttons live, lifted off the ground like a widget. A grey tile until it draws.
struct LiveFace: View {
    let face: Face?
    let size: CGSize
    let tap: @MainActor @Sendable (Tap) -> Void
    let form: @MainActor @Sendable (Tap) -> Void

    var body: some View {
        Group {
            if let face {
                FaceView(face, host: .app(tap: tap, form: form))
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.disabled.opacity(0.4))
            }
        }
        .frame(width: size.width, height: size.height)
        .faceShadow()
    }
}
