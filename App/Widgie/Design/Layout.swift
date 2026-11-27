import SwiftUI
import WidgetEngine
import WidgetHosting

/// The space between a page's content and the sides of the screen, which the tab bar and the toast keep too.
enum Page {
    static let margin: CGFloat = 20
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
