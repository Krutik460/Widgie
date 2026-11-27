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
    /// A template to change in chat while Make holds work of its own: waiting for a save to land, or for the
    /// person's choice.
    @State private var chosen: (source: WidgetSource, name: String)?
    @State private var asking = false

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
                    chosen = (source, name)
                    handOver()
                }
            }
        }
        .tint(Palette.caret)
        .confirmationDialog(
            "Swap your draft for \(chosen?.name ?? "this template")?",
            isPresented: Binding(
                get: { asking },
                set: { shown in
                    asking = shown
                    if !shown, making.replacement != .waits { chosen = nil }
                }),
            titleVisibility: .visible, presenting: chosen
        ) { choice in
            Button("Replace draft", role: .destructive) { replace(with: choice.source) }
            Button("Keep editing", role: .cancel) { chosen = nil }
        }
        .onChange(of: making.phase) { _, phase in
            // A save shows in Widgets at once, even when you switch tabs instead of tapping Done.
            if case .saved = phase { library.refresh() }
            handOver()
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

    /// Puts the chosen template into Make once that loses nothing, asks first while it would discard a draft,
    /// and waits out a save, which then lands and shows in Widgets before the template takes its place.
    private func handOver() {
        guard let chosen else { return }
        switch making.replacement {
        case .free: replace(with: chosen.source)
        case .discards: asking = true
        case .waits: asking = false
        }
    }

    /// Opens Make on a filled template as the draft, so the person's first message refines it.
    private func replace(with source: WidgetSource) {
        guard making.replacement != .waits else { return }
        chosen = nil
        asking = false
        making.cancel()
        making = DescribeSession(draft: source)
    }
}
