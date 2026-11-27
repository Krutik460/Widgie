import SwiftUI
import WidgetBuilder
import WidgetEngine

/// The app's tabs over the sky: your widgets, the chat that makes a new one, and the templates. Each page is built
/// on its first visit and then stays alive, so it keeps its scroll and its work when you switch away.
struct RootView: View {
    let library: Library

    enum Page: Int, CaseIterable, Hashable {
        case widgets, make, templates
    }

    @State private var page = Page.widgets
    @State private var visited: Set<Page> = [.widgets]
    @State private var scrolled: [Page: CGFloat] = [:]
    @State private var arrivals = Arrivals()
    /// The keyboard is up in Make, so the tab bar steps aside as the system's does.
    @State private var typing = false
    /// The Make tab's session. It outlives a tab switch, so a draft is never lost by looking at your widgets.
    @State private var making = DescribeSession()
    @State private var gallery = TemplateGallery()
    /// A template to change in chat while Make holds work of its own: waiting for a save to land, or for the
    /// person's choice.
    @State private var chosen: (source: WidgetSource, name: String)?
    @State private var asking = false

    var body: some View {
        ZStack {
            Sky(moon: Sky.moonShown(scrolled: scrolled[page] ?? 0))
            ForEach(Page.allCases, id: \.self) { shown in
                if visited.contains(shown) {
                    content(shown).modifier(
                        PageSwitch(shown: shown == page, side: shown.rawValue < page.rawValue ? -1 : 1))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !(typing && page == .make) {
                TabBar(page: page, unseen: arrivals.badge, pick: go)
                    .padding(.horizontal, 20)
                    .padding(.bottom, -8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            typing = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            typing = false
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
            if case .saved(let id) = phase {
                library.refresh()
                if making.editing == nil { arrivals.arrive(id, onWidgets: page == .widgets) }
            }
            handOver()
        }
        // Leaving Make after a save starts a fresh session, so Make never reopens on the Saved screen.
        .onChange(of: page) { _, page in
            if page != .make, case .saved = making.phase { making = DescribeSession() }
        }
        // A form link from a home screen widget opens its form over your widgets.
        .onOpenURL { url in
            go(.widgets)
            library.open(url)
        }
    }

    @ViewBuilder private func content(_ shown: Page) -> some View {
        switch shown {
        case .widgets:
            WidgetsFeed(
                library: library, arrivals: arrivals, active: page == .widgets, scrolled: scroll(.widgets)
            ) {
                go(.make)
            } browse: {
                go(.templates)
            } added: { id in
                arrivals.arrive(id, onWidgets: true)
            }
        case .make:
            DescribeView(session: making, inTab: true) { saved in
                making = DescribeSession()
                library.refresh()
                if saved != nil { go(.widgets) }
            }
            .id(ObjectIdentifier(making))
        case .templates:
            TemplatesView(gallery: gallery, library: library, scrolled: scroll(.templates)) { id in
                go(.widgets)
                arrivals.arrive(id, onWidgets: true)
            } chat: { source, name in
                go(.make)
                chosen = (source, name)
                handOver()
            }
        }
    }

    /// Switches tabs. Opening Widgets clears its count, and what arrived meanwhile lands.
    private func go(_ next: Page) {
        visited.insert(next)
        page = next
        if next == .widgets { arrivals.openWidgets() }
        // Once the 320 ms switch has run, VoiceOver reads the new page. Without it, VoiceOver kept the old page's
        // safe area content, such as Make's Build it, while another tab showed.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            AccessibilityNotification.LayoutChanged().post()
        }
    }

    private func scroll(_ shown: Page) -> Binding<CGFloat> {
        Binding(get: { scrolled[shown] ?? 0 }, set: { scrolled[shown] = $0 })
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

/// A tab's page coming and going: the outgoing one fades out in 120 ms, and the incoming one fades in and slides 14
/// points from the side it lies on, after 40 ms. Only a fade with Reduce Motion.
private struct PageSwitch: ViewModifier {
    let shown: Bool
    /// -1 for a page left of the chosen one, 1 for one to its right.
    let side: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(shown ? .easeOut(duration: 0.22).delay(0.04) : .linear(duration: 0.12)) {
                $0.opacity(shown ? 1 : 0)
            }
            .animation(
                shown ? .timingCurve(0.22, 0.8, 0.26, 1, duration: 0.28).delay(0.04) : .linear(duration: 0).delay(0.12)
            ) {
                $0.offset(x: shown || reduceMotion ? 0 : side * 14)
            }
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}
