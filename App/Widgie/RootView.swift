import SwiftUI

/// The app's tabs over the sky: your widgets, the chat that makes a new one, and the templates. Each page is built
/// on its first visit and then stays alive, so it keeps its scroll and its work when you switch away.
struct RootView: View {
    let library: Library

    @State private var tabs = Tabs()
    /// The pages scrolled past the moon.
    @State private var pastMoon: Set<Tabs.Page> = []
    @State private var flights = Flights()
    @State private var skyCovers = SkyCovers()
    /// The keyboard is up in Make, so the tab bar steps aside as the system's does.
    @State private var typing = false
    /// The Make tab's chat. It outlives a tab switch, so a draft is never lost by looking at your widgets.
    @State private var chat = Chat()
    @State private var gallery = TemplateGallery()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Sky(moon: !pastMoon.contains(tabs.page), still: skyCovers.count > 0)
            ForEach(Tabs.Page.allCases, id: \.self) { shown in
                if tabs.visited.contains(shown) {
                    content(shown).modifier(
                        PageSwitch(shown: shown == tabs.page, side: shown.rawValue < tabs.page.rawValue ? -1 : 1))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !(typing && tabs.page == .make) {
                TabBar(page: tabs.page, unseen: tabs.arrivals.badge, caught: tabs.caught, pick: tabs.go) { [flights] in
                    flights.target = $0
                }
                .padding(.horizontal, 20)
                .padding(.bottom, -8)
            }
        }
        .overlay(alignment: .top) {
            ZStack {
                if let toast = tabs.toast {
                    ToastView(toast: toast)
                        .padding(.horizontal, 20)
                        .padding(.top, -8)
                        .transition(reduceMotion ? .opacity : .offset(y: -150))
                        .id(toast.id)
                }
            }
            .animation(
                reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.38, bounce: 0.3), value: tabs.toast?.id)
        }
        .environment(flights)
        .environment(skyCovers)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            typing = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            typing = false
        }
        .tint(Palette.caret)
        // The pile is as wide as the window, so its faces start drawing at launch, before Templates opens.
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            gallery.fit(column: width - 2 * TemplatesView.margin)
        }
        .onChange(of: tabs.page) {
            // Once the switch has applied, VoiceOver moves to the new page, as it does for a system tab bar.
            Task {
                await Task.yield()
                AccessibilityNotification.LayoutChanged().post()
            }
        }
        // A form link from a home screen widget opens its form over your widgets.
        .onOpenURL { url in
            tabs.go(.widgets)
            library.open(url)
        }
    }

    @ViewBuilder private func content(_ shown: Tabs.Page) -> some View {
        switch shown {
        case .widgets:
            WidgetsFeed(
                library: library, arrivals: tabs.arrivals, active: tabs.page == .widgets, pastMoon: pastMoon(.widgets)
            ) {
                tabs.go(.make)
            } browse: {
                tabs.go(.templates)
            } added: { id in
                tabs.arrive(id)
            }
        case .make:
            ChatView(chat: chat, pastMoon: pastMoon(.make)) { id, launch in
                library.refresh()
                Task {
                    await tabs.take(id, named: launch.name) {
                        if !reduceMotion { await flights.fly(launch) }
                    }
                    // The outline the tile left stays a moment with Widgie on it, as the prototype draws it.
                    if !reduceMotion { try? await Task.sleep(for: .milliseconds(320)) }
                    chat.saved()
                }
            }
        case .templates:
            TemplatesView(gallery: gallery, library: library, pastMoon: pastMoon(.templates)) { id, launch in
                Task {
                    await tabs.take(id, named: launch.name) {
                        if !reduceMotion { await flights.fly(launch) }
                    }
                }
            } chat: { source, name in
                tabs.go(.make)
                chat.change(source, named: name)
            }
        }
    }

    private func pastMoon(_ shown: Tabs.Page) -> Binding<Bool> {
        Binding(
            get: { pastMoon.contains(shown) },
            set: { past in
                if past { pastMoon.insert(shown) } else { pastMoon.remove(shown) }
            })
    }
}

extension EnvironmentValues {
    /// Whether the tab page holding this view has faded out. What a scroll view puts in its safe area inset
    /// escapes the page's `accessibilityHidden`, its own too, so Make leaves its composer out once hidden;
    /// otherwise VoiceOver reached Send from another tab.
    @Entry var pageHidden = false
}

/// A tab's page coming and going: the outgoing one fades out in 120 ms, and the incoming one fades in and slides 14
/// points from the side it lies on, after 40 ms. Only a fade with Reduce Motion.
private struct PageSwitch: ViewModifier {
    let shown: Bool
    /// -1 for a page left of the chosen one, 1 for one to its right.
    let side: CGFloat

    /// Whether the page has finished fading out, so what it leaves out while hidden leaves with it.
    @State private var gone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let fadeOut = 0.12

    func body(content: Content) -> some View {
        content
            .animation(shown ? .easeOut(duration: 0.22).delay(0.04) : .linear(duration: Self.fadeOut)) {
                $0.opacity(shown ? 1 : 0)
            }
            .animation(
                shown
                    ? .timingCurve(0.22, 0.8, 0.26, 1, duration: 0.28).delay(0.04)
                    : .linear(duration: 0).delay(Self.fadeOut)
            ) {
                $0.offset(x: shown || reduceMotion ? 0 : side * 14)
            }
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            .environment(\.pageHidden, gone)
            .task(id: shown) {
                if !shown { try? await Task.sleep(for: .seconds(Self.fadeOut)) }
                if !Task.isCancelled { gone = !shown }
            }
    }
}
