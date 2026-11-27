import SwiftUI
import WidgetEngine
import WidgetHosting

/// The space between a page's content and the sides of the screen, which the tab bar and the toast keep too.
enum Margin {
    static let page: CGFloat = 20
}

/// Wraps its text as CSS `text-wrap: balance` does: at the narrowest width that keeps the number of lines it takes
/// at the width offered, so its lines come out about even instead of ending on a short one. The text must wrap
/// freely: with a `lineLimit` or a `minimumScaleFactor` it never grows taller as it narrows, and the search would
/// shrink it to nothing.
struct Balanced: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        guard let offered = proposal.width, offered.isFinite else { return text.sizeThatFits(proposal) }
        let lines = text.sizeThatFits(ProposedViewSize(width: offered, height: nil)).height
        var (narrow, wide) = (CGFloat.zero, offered)
        while wide - narrow > 0.5 {
            let middle = (narrow + wide) / 2
            if text.sizeThatFits(ProposedViewSize(width: middle, height: nil)).height > lines {
                narrow = middle
            } else {
                wide = middle
            }
        }
        // The width found, not the text's own, so that placing the text at it breaks the same lines.
        return CGSize(width: wide, height: lines)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// A face drawn at `size` through `host`, lifted off the ground like a widget. A grey tile until it draws.
struct FaceTile: View {
    let face: Face?
    let size: CGSize
    var host = FaceHost.still

    /// The corner of a face, as on the home screen.
    static let corner: CGFloat = 22

    var body: some View {
        Group {
            if let face {
                FaceView(face, host: host)
            } else {
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous).fill(Palette.disabled.opacity(0.4))
            }
        }
        .frame(width: size.width, height: size.height)
        .faceShadow()
    }
}

extension FaceHost {
    /// Taps run in the app, form buttons open its form sheet, and the background is drawn under the content,
    /// clipped like a widget.
    @MainActor static func app(
        tap: @escaping @MainActor @Sendable (Tap) -> Void, form: @escaping @MainActor @Sendable (Tap) -> Void
    ) -> FaceHost {
        FaceHost(
            button: { tapped, label in
                AnyView(
                    Button {
                        tap(tapped)
                    } label: {
                        label
                    }.buttonStyle(.plain))
            },
            form: { tapped, label in
                AnyView(
                    Button {
                        form(tapped)
                    } label: {
                        label
                    }.buttonStyle(.plain))
            },
            root: { content, background in
                AnyView(
                    ZStack {
                        background
                        content
                    }
                    .clipShape(RoundedRectangle(cornerRadius: FaceTile.corner, style: .continuous)))
            }
        )
    }
}
