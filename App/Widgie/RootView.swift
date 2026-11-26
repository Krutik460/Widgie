import SwiftUI
import WidgetEngine

/// The app's tabs: your widgets, and the chat that makes a new one.
struct RootView: View {
    let library: Library

    enum Section: Hashable {
        case widgets, make
    }

    @State private var section = Section.widgets
    /// The Make tab's session. It outlives a tab switch, so a draft is never lost by looking at your widgets.
    @State private var making = DescribeSession()

    var body: some View {
        TabView(selection: $section) {
            Tab("Widgets", systemImage: "square.grid.2x2", value: .widgets) {
                WidgetsFeed(library: library) { section = .make }
            }
            Tab("Make", systemImage: "plus.bubble", value: .make) {
                DescribeView(session: making) { saved in
                    making = DescribeSession()
                    library.refresh()
                    if saved != nil { section = .widgets }
                }
                .id(ObjectIdentifier(making))
            }
        }
        .tint(Palette.caret)
        // A form link from a home screen widget opens its form over your widgets.
        .onOpenURL { url in
            section = .widgets
            library.open(url)
        }
    }
}
