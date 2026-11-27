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
    /// The pages scrolled past the moon.
    @State private var pastMoon: Set<Page> = []
    @State private var arrivals = Arrivals()
    @State private var flights = Flights()
    /// Counts the widgets that flew into the Widgets tab.
    @State private var caught = 0
    @State private var toast: Toast?
    /// The full screen covers up, each with a sky of its own over this one.
    @State private var covers = 0
    /// The keyboard is up in Make, so the tab bar steps aside as the system's does.
    @State private var typing = false
    /// The Make tab's session. It outlives a tab switch, so a draft is never lost by looking at your widgets.
    @State private var making = DescribeSession()
    @State private var gallery = TemplateGallery()
    /// A template to change in chat while Make holds work of its own: waiting for a save to land, or for the
    /// person's choice.
    @State private var chosen: (source: WidgetSource, name: String)?
    @State private var asking = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Sky(moon: !pastMoon.contains(page), still: covers > 0)
            ForEach(Page.allCases, id: \.self) { shown in
                if visited.contains(shown) {
                    content(shown).modifier(
                        PageSwitch(shown: shown == page, side: shown.rawValue < page.rawValue ? -1 : 1))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !(typing && page == .make) {
                TabBar(page: page, unseen: arrivals.badge, caught: caught, pick: go) { [flights] in
                    flights.target = $0
                }
                .padding(.horizontal, 20)
                .padding(.bottom, -8)
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                ToastView(toast: toast)
                    .padding(.horizontal, 20)
                    .padding(.top, -8)
                    .transition(reduceMotion ? .opacity : .offset(y: -150))
                    .id(toast.id)
            }
        }
        .environment(flights)
        .environment(\.coverSky) { covers += $0 ? 1 : -1 }
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
        .onChange(of: page) { _, page in
            // Leaving Make after a save starts a fresh session, so Make never reopens on the Saved screen.
            if page != .make, case .saved = making.phase { making = DescribeSession() }
            if page == .widgets { withAnimation(toastMotion) { toast = nil } }
            // Once the switch has applied, VoiceOver moves to the new page, as it does for a system tab bar.
            Task {
                await Task.yield()
                AccessibilityNotification.LayoutChanged().post()
            }
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
                library: library, arrivals: arrivals, active: page == .widgets, pastMoon: pastMoon(.widgets)
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
            TemplatesView(gallery: gallery, library: library, pastMoon: pastMoon(.templates)) { id, launch in
                Task { await take(id, from: launch) }
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
    }

    private func pastMoon(_ shown: Page) -> Binding<Bool> {
        Binding(
            get: { pastMoon.contains(shown) },
            set: { past in
                if past { pastMoon.insert(shown) } else { pastMoon.remove(shown) }
            })
    }

    /// A widget added from a template flies into the Widgets tab while the person stays where they are. The glyph
    /// takes it in, the count goes up, and a toast says so; it lands when they open Widgets.
    private func take(_ id: WidgetID, from launch: Launch) async {
        if !reduceMotion { await flights.fly(launch) }
        caught += 1
        arrivals.arrive(id, onWidgets: page == .widgets)
        guard page != .widgets, let name = library.items.first(where: { $0.id == id })?.summary.name else { return }
        let shown = Toast(id: (toast?.id ?? 0) + 1, words: "\(name) is in your widgets.")
        withAnimation(toastMotion) { toast = shown }
        try? await Task.sleep(for: Toast.shownFor)
        if toast == shown { withAnimation(toastMotion) { toast = nil } }
    }

    private var toastMotion: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.38, bounce: 0.3)
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

extension EnvironmentValues {
    /// Whether the tab page holding this view is not the one showing. What a scroll view puts in its safe area
    /// inset escapes the page's `accessibilityHidden`, its own too, so Make leaves its composer out while hidden;
    /// otherwise VoiceOver reached Build it from another tab.
    @Entry var pageHidden = false
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
            .environment(\.pageHidden, !shown)
    }
}
