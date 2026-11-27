import SwiftUI
import WidgetEngine

/// The app's tabs: your widgets, and the chat that makes a new one.
struct RootView: View {
    let library: Library

    enum Page: Hashable {
        case widgets, make
    }

    @State private var page = Page.widgets
    /// The Make tab's session. It outlives a tab switch, so a draft is never lost by looking at your widgets.
    @State private var making = DescribeSession()

    var body: some View {
        TabView(selection: $page) {
            Tab("Widgets", systemImage: "square.grid.2x2", value: .widgets) {
                WidgetsFeed(library: library) { page = .make }
            }
            Tab("Make", systemImage: "plus.bubble", value: .make) {
                DescribeView(session: making, inTab: true) { saved in
                    making = DescribeSession()
                    library.refresh()
                    if saved != nil { page = .widgets }
                }
                .id(ObjectIdentifier(making))
            }
        }
        .tint(Palette.caret)
        // A save shows in Widgets at once, even when you switch tabs instead of tapping Done.
        .onChange(of: making.phase) { _, phase in
            if case .saved = phase { library.refresh() }
        }
        // Leaving Make after a save starts a fresh session, so Make never reopens on the Saved screen.
        .onChange(of: page) { _, page in
            if page != .make, case .saved = making.phase { making = DescribeSession() }
        }
        // A form link from a home screen widget opens its form over your widgets.
        .onOpenURL { url in
            page = .widgets
            library.open(url)
        }
    }
}
