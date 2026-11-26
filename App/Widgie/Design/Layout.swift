import SwiftUI
import WidgetEngine
import WidgetHosting

/// The describe flow and the library share one column, the medium widget's width, centered on the screen.
enum Column {
    static let width = Family.medium.standardSize.width
    static let margin: CGFloat = 32
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
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
            }
        )
    }
}
