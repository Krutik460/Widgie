import SwiftUI
import WidgetEngine

/// Your widgets as live faces, the size each sits on the home screen: wide ones fill a row and smalls sit in
/// pairs. Widgie stands on the first row and talks: it greets the widget under it, says what a tap did, and points
/// out a widget that just arrived. A face's buttons work as on the home screen; a tap anywhere else opens the
/// widget.
struct WidgetsFeed: View {
    let library: Library
    let arrivals: Arrivals
    /// Whether Widgets is the chosen tab. Widgie lives, idles and talks only then.
    let active: Bool
    /// Whether the feed is scrolled past the moon, which then steps aside.
    @Binding var pastMoon: Bool
    /// Switches to the Make tab.
    let make: () -> Void
    /// Switches to the Templates tab.
    let browse: () -> Void
    /// A widget was added from the feed itself, by the debug menu.
    let added: (WidgetID) -> Void

    @State private var shown: Shown?
    /// The widget changing in Make's chat over the feed.
    @State private var changing: Chat?
    @State private var deleting: WidgetID?
    @State private var widgie = FeedWidgie()
    @State private var activity = Activity()
    /// The last widget that finished landing. Until `arrivals.landing` matches it, the landing owns Widgie's hop.
    @State private var landed: WidgetID?
    /// The last widget whose card settled in. The newest card waits hidden until then, from the moment it is
    /// added, so it never shows before it lands.
    @State private var settled: WidgetID?
    @State private var risen = false
    @State private var column: CGFloat = 0
    /// The visible height of the scroll view and of the header, so the empty state fills the screen.
    @State private var viewport: CGFloat = 0
    @State private var headerHeight: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    struct Shown: Identifiable {
        let id: WidgetID
    }

    /// How far the feed is scrolled and when the person last touched it. Taps, the landing and the idle loop read
    /// these but `body` never does, so scrolling does not rebuild the feed.
    private final class Activity {
        var offset: CGFloat = 0
        var touched = Date.distantPast
    }

    private static let top = "top"
    /// How far the feed scrolls before Widgie, on the first row, counts as out of view.
    private static let widgieInView: CGFloat = 140

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TimelineView(.everyMinute) { header($0.date) }
                        .id(Self.top)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            headerHeight = $0
                        }
                    // Nothing below the header until the first load, so the empty state never flashes at launch.
                    if library.loaded && library.items.isEmpty {
                        empty
                    } else if library.loaded {
                        stage.zIndex(1)
                        feed
                    }
                }
                .padding(.horizontal, Margin.page)
                .padding(.bottom, 40)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y + $0.contentInsets.top
            } action: { [activity] _, offset in
                activity.offset = offset
            }
            .onScrollGeometryChange(for: Bool.self) {
                !Sky.moonShown(scrolled: $0.contentOffset.y + $0.contentInsets.top)
            } action: { _, past in
                pastMoon = past
            }
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.containerSize.height
            } action: { _, height in
                viewport = height
            }
            .onScrollPhaseChange { [activity] _, phase in
                if phase != .idle { activity.touched = .now }
            }
            .task(id: arrivals.landing) {
                if let landing = arrivals.landing { await land(landing, scroller: scroller) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Palette.text)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            column = width - 2 * Margin.page
            library.fit(column: column)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 700))
            widgie.wake()
        }
        .task(id: active && !reduceMotion) { await idle() }
        .onChange(of: active ? perchPoint : nil, initial: true) { _, point in
            if arrivals.landing == landed { widgie.hop(to: point, reduceMotion: reduceMotion) }
        }
        .sheet(item: $shown) { shown in
            WidgetDetail(library: library, id: shown.id)
        }
        .fullScreenCover(item: $changing) { chat in
            EditChat(library: library, chat: chat)
        }
        // The detail sheet shows the form and the message itself while it is up.
        .sheet(item: Binding(get: { shown == nil ? library.form : nil }, set: { library.form = $0 })) { form in
            FormSheet(form: form.form) { input in
                perform(form.form.tap, input: input)
                library.form = nil
            }
        }
        .failureAlert(Bindable(library).message, when: shown == nil)
        .confirmsDelete($deleting, in: library)
    }

    // MARK: Header

    /// The date, a greeting from the clock, and how many widgets there are and how many are on the home screen. The
    /// prototype places them from the top of the date (the title 24 points down and the count 74), which the gaps
    /// below give with its 16.25-point date line.
    private func header(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(size: 14, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(Palette.secondary)
            title(Daypart(now).title)
                .padding(.top, 7.75)
            if !library.items.isEmpty {
                CountLine(widgets: library.items.count, placed: library.placedCount)
                    .padding(.top, 10.8)
            }
        }
        .padding(.top, 6)
    }

    /// In debug builds, a long press on the title installs a reference widget.
    @ViewBuilder private func title(_ words: String) -> some View {
        let title = Text(words).display(size: 40).accessibilityAddTraits(.isHeader)
        #if DEBUG
            title.contextMenu {
                Section("Install reference widget") {
                    ForEach(library.fixtures, id: \.folder) { fixture in
                        Button(fixture.name) {
                            Task { if let id = await library.install(fixture.folder) { added(id) } }
                        }
                    }
                }
            }
        #else
            title
        #endif
    }

    // MARK: Widgie

    private var rows: [FeedRow<WidgetID>] {
        // At the accessibility text sizes each widget takes its own row, so a small's name has room to wrap.
        typeSize.isAccessibilitySize
            ? FeedRow.singles(library.shown) : FeedRow.rows(library.shown, fresh: arrivals.fresh)
    }

    private var perch: Perch? { Perch(rows.first) }

    /// Where Widgie's foot stands: across the column, and the room above the first row. A bubble that grows the
    /// room does not count, so Widgie never hops because of its own words.
    private var perchPoint: CGPoint? {
        guard let perch, column > 0 else { return nil }
        return CGPoint(
            x: perch.x(column: column, small: library.sizes.small.width, large: typeSize.isAccessibilitySize),
            y: perch.room)
    }

    @ViewBuilder private var stage: some View {
        if let perch, let point = perchPoint {
            FeedStage(
                widgie: widgie, perch: perch, point: point, column: column, name: item(perch.id)?.summary.name,
                active: active)
        }
    }

    /// A tap on a face: the widget's own action, then Widgie hops and says so. Scrolled away from Widgie, the line
    /// is only read out.
    private func perform(_ tap: Tap, input: [String: InputValue] = [:]) {
        activity.touched = .now
        library.perform(tap, input: input)
        guard let name = library.items.first(where: { $0.id.rawValue == tap.widget })?.summary.name else { return }
        let line = Speech.tapped(name)
        if activity.offset > Self.widgieInView {
            AccessibilityNotification.Announcement(line).post()
            return
        }
        widgie.play(.hop)
        widgie.say(line, for: 2.4)
    }

    /// The new card settles in where you can see it, under Widgie, and Widgie points it out as it touches down.
    /// A newer landing cancels this one, so only one ever runs.
    private func land(_ id: WidgetID, scroller: ScrollViewProxy) async {
        for _ in 0..<40 where item(id) == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled else { return }
        guard let arrived = item(id) else {
            settled = id
            landed = id
            return
        }
        let scrolled = activity.offset
        if scrolled > 4 {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) { scroller.scrollTo(Self.top, anchor: .top) }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : min(480, 160 + Int(scrolled * 0.5))))
            guard !Task.isCancelled else { return }
        }
        withAnimation(reduceMotion ? .linear(duration: 0.15) : .arrival(duration: 0.26)) {
            settled = id
        }
        let moved = widgie.hop(to: perchPoint, reduceMotion: reduceMotion)
        if !reduceMotion {
            try? await Task.sleep(for: .milliseconds(moved ? 560 : 200))
            guard !Task.isCancelled else { return }
            if !moved, perch?.id == id { widgie.play(.smallHop) }
        }
        widgie.say(
            Speech.landed(arrived.summary.name, buttons: arrived.faces.values.contains { $0.hasButtons }), for: 3.2)
        landed = id
    }

    /// Now and then, while you are not busy with something, Widgie blinks twice, glances at your widgets, or
    /// hops a little: every 8 to 11 seconds, only on Widgets, at the top of the feed, after 4 untouched seconds.
    private func idle() async {
        guard active, !reduceMotion else { return }
        var beat = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(8000 + (beat % 3) * 1500))
            guard !Task.isCancelled else { return }
            let quiet =
                Date.now.timeIntervalSince(activity.touched) > 4 && activity.offset < Self.widgieInView && shown == nil
                && changing == nil
            guard quiet, perch != nil else { continue }
            widgie.play([HeroAct.Kind.blink, .glance, .smallHop][beat % 3])
            beat += 1
        }
    }

    /// Whether this is the newest card, hidden until its landing settles it in.
    private func waiting(_ id: WidgetID) -> Bool {
        arrivals.fresh == id && settled != id
    }

    /// Opens Make's chat over the feed on the widget.
    private func change(_ id: WidgetID) {
        changing = Chat(.library(id), close: { changing = nil })
    }

    private func item(_ id: WidgetID) -> Library.Item? {
        library.items.first { $0.id == id }
    }

    // MARK: Feed

    private var feed: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Group {
                    switch row {
                    case .wide(let id):
                        card(id, .medium)
                    case .pair(let first, let second):
                        HStack(alignment: .top, spacing: FaceSizes.gap) {
                            card(first, .small)
                            if let second { card(second, .small) }
                        }
                    }
                }
                .rise(risen, after: Double(index) * 0.05)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.15), value: rows)
        .onAppear { risen = true }
    }

    @ViewBuilder private func card(_ id: WidgetID, _ family: Family) -> some View {
        if let item = item(id) {
            FeedCard(
                item: item, family: family, size: library.sizes[family], placed: library.placed[id] != nil,
                fresh: arrivals.fresh == id
            ) {
                perform($0)
            } form: {
                activity.touched = .now
                library.showForm(for: $0)
            } open: {
                activity.touched = .now
                shown = Shown(id: id)
            } change: {
                change(id)
            }
            .scaleEffect(waiting(id) ? 0.94 : 1)
            .opacity(waiting(id) ? 0 : 1)
            .contextMenu {
                Button("Change it", systemImage: "pencil") { change(id) }
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = id }
            }
        }
    }

    // MARK: Empty

    /// No widgets yet: the big Widgie asks for one.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            EmptyHero(widgie: widgie, active: active)
            Text("Say what you want to see on your home screen, and I’ll make it. Or start from a template.")
                .font(size: 17, weight: .medium)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 36)
            Spacer(minLength: 24)
            HStack(spacing: 10) {
                Button("Browse templates", action: browse)
                    .buttonStyle(KeyButtonStyle(prominent: false))
                Button("Make one", action: make)
                    .buttonStyle(KeyButtonStyle())
            }
        }
        .frame(minHeight: max(0, viewport - headerHeight - 40))
    }
}
