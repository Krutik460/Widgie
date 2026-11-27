import SwiftUI
import WidgetBuilder
import WidgetEngine

/// The app's tabs: your widgets, the chat that makes a new one, and the templates.
struct RootView: View {
    let library: Library

    enum Page: Hashable {
        case widgets, make, templates
    }

    @State private var page = Page.widgets
    /// The Make tab's session. It outlives a tab switch, so a draft is never lost by looking at your widgets.
    @State private var making = DescribeSession()
    @State private var gallery = TemplateGallery()
    /// The widget a template just added, which the feed highlights.
    @State private var arrived: WidgetID?
    /// A template to change in chat while Make holds work of its own, waiting on the person's choice.
    @State private var swapping: (source: WidgetSource, name: String)?

    var body: some View {
        TabView(selection: $page) {
            Tab("Widgets", systemImage: "square.grid.2x2", value: .widgets) {
                WidgetsFeed(library: library, arrived: arrived) {
                    page = .make
                } browse: {
                    page = .templates
                }
            }
            Tab("Make", systemImage: "plus.bubble", value: .make) {
                DescribeView(session: making, inTab: true) { saved in
                    making = DescribeSession()
                    library.refresh()
                    if saved != nil { page = .widgets }
                }
                .id(ObjectIdentifier(making))
            }
            Tab("Templates", systemImage: "square.on.square", value: .templates) {
                TemplatesView(gallery: gallery, library: library) { id in
                    arrived = id
                    page = .widgets
                } chat: { source, name in
                    page = .make
                    if makingHasWork {
                        swapping = (source, name)
                    } else {
                        startMaking(from: source)
                    }
                }
            }
        }
        .tint(Palette.caret)
        .confirmationDialog(
            "Swap your draft for \(swapping?.name ?? "this template")?",
            isPresented: Binding(get: { swapping != nil }, set: { if !$0 { swapping = nil } }),
            titleVisibility: .visible, presenting: swapping
        ) { swap in
            Button("Replace draft", role: .destructive) { startMaking(from: swap.source) }
            Button("Keep editing", role: .cancel) {}
        }
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

    /// Whether Make holds something a template would replace: a draft, or a build or save under way.
    private var makingHasWork: Bool {
        switch making.phase {
        case .saved: false
        case .opening, .building, .saving: true
        case .composing, .failed: making.draft != nil
        }
    }

    /// Opens Make on a filled template as the draft, so the person's first message refines it.
    private func startMaking(from source: WidgetSource) {
        making.cancel()
        making = DescribeSession(draft: source)
    }
}
