import SwiftUI
import WidgetEngine

/// Your widgets as live faces, the size each sits on the home screen: wide ones fill a row and smalls sit in
/// pairs. Widgie stands on the first row and talks: it greets the widget under it, says what a tap did, and points
/// out a widget that just arrived. A face's buttons work as on the home screen; a tap anywhere else opens the
/// widget.
struct WidgetsFeed: View {
    let library: Library
    let arrivals: Arrivals
    /// Whether Widgets is the chosen tab. Widgie's idle life runs only then.
    let active: Bool
    @Binding var scrolled: CGFloat
    /// Switches to the Make tab.
    let make: () -> Void
    /// Switches to the Templates tab.
    let browse: () -> Void
    /// A widget was added from the feed itself, by the debug menu.
    let added: (WidgetID) -> Void

    @State private var shown: Shown?
    @State private var session: DescribeSession?
    @State private var deleting: WidgetID?
    /// A line Widgie says for a moment in place of its greeting.
    @State private var said: String?
    @State private var saying: Task<Void, Never>?
    /// Widgie keeps quiet until it has settled in, and while it hops between perches.
    @State private var speaking = false
    @State private var hops = 0
    @State private var act = HeroAct()
    /// Where Widgie last stood in view. It hops from there when the first row has changed.
    @State private var perchedAt: CGPoint?
    /// The last widget that finished landing. Until `arrivals.landing` matches it, the landing owns Widgie's hop.
    @State private var landed: WidgetID?
    @State private var settling: WidgetID?
    @State private var risen = false
    @State private var touched = Date.distantPast
    @State private var bubbleHeight: CGFloat = 42
    @State private var column: CGFloat = 0
    /// The visible height of the scroll view and of the header, so the empty state fills the screen.
    @State private var viewport: CGFloat = 0
    @State private var headerHeight: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    struct Shown: Identifiable {
        let id: WidgetID
    }

    static let margin: CGFloat = 20
    private static let top = "top"

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                TimelineView(.everyMinute) { timeline in
                    VStack(alignment: .leading, spacing: 0) {
                        header(timeline.date)
                            .id(Self.top)
                            .onGeometryChange(for: CGFloat.self) {
                                $0.size.height
                            } action: {
                                headerHeight = $0
                            }
                        // Nothing below the header until the first load, so the empty state never flashes at launch.
                        if library.loaded && library.items.isEmpty {
                            empty(timeline.date)
                        } else if library.loaded {
                            stage(timeline.date).zIndex(1)
                            feed
                        }
                    }
                    .padding(.horizontal, Self.margin)
                    .padding(.bottom, 40)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollIndicators(.hidden)
            .refreshable { await library.reload() }
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y + $0.contentInsets.top
            } action: { _, offset in
                scrolled = offset
            }
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.containerSize.height
            } action: { _, height in
                viewport = height
            }
            .onScrollPhaseChange { _, phase in
                if phase != .idle { touched = .now }
            }
            .onChange(of: arrivals.landing, initial: true) { _, landing in
                guard let landing else { return }
                Task { await land(landing, scroller: scroller) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Palette.text)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            column = width - 2 * Self.margin
            library.fit(column: column)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 700))
            if hops == 0 { speaking = true }
        }
        .task(id: active) { await idle() }
        .onChange(of: perchPoint, initial: true) { _, new in
            if active && arrivals.landing == landed { hop(to: new) }
        }
        .onChange(of: active) { _, active in
            if active && arrivals.landing == landed { hop(to: perchPoint) }
        }
        .sheet(item: $shown) { shown in
            WidgetDetail(library: library, id: shown.id)
        }
        .fullScreenCover(item: $session) { session in
            DescribeView(session: session) { _ in
                self.session = nil
                library.refresh()
            }
        }
        // The detail sheet shows the form and the message itself while it is up.
        .sheet(item: Binding(get: { shown == nil ? library.form : nil }, set: { library.form = $0 })) { form in
            FormSheet(form: form.form) { input in
                perform(form.form.tap, input: input)
                library.form = nil
            }
        }
        .confirmationDialog(
            "Delete this widget?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { id in
            Button("Delete", role: .destructive) { library.delete(id) }
            Button("Keep it", role: .cancel) {}
        } message: { id in
            Text(WidgetDetail.deleteMessage(placed: library.placed[id] != nil))
        }
        .alert(
            "Something went wrong", isPresented: .constant(shown == nil && library.message != nil),
            actions: { Button("OK") { library.message = nil } },
            message: { Text(library.message ?? "") }
        )
    }

    // MARK: Header

    /// The date, a greeting from the clock, and how many widgets there are and how many are on the home screen.
    private func header(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(size: 14, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(Palette.secondary)
            title(Daypart(now).title)
                .padding(.top, 6)
            if !library.items.isEmpty {
                CountLine(widgets: library.items.count, placed: library.placedCount)
                    .padding(.top, 10)
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
        let rows = FeedRow.rows(
            library.items.enumerated().map { index, item in (item.id, library.family(of: item, at: index)) },
            fresh: arrivals.fresh)
        guard typeSize.isAccessibilitySize else { return rows }
        // At the accessibility text sizes each small takes its own row, so its name has room to wrap.
        return rows.flatMap { row -> [FeedRow<WidgetID>] in
            if case .pair(let first, let second?) = row { [.pair(first, nil), .pair(second, nil)] } else { [row] }
        }
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

    private func stageHeight(_ perch: Perch) -> CGFloat { max(perch.room, lift + 20) }

    /// How far the bubble's top sits above the first row: 82 points, or more for a bubble of many lines.
    private var lift: CGFloat { max(82, bubbleHeight + 12) }

    private func words(_ now: Date) -> String? {
        guard speaking else { return nil }
        return said ?? Speech.greeting(perch.flatMap { item($0.id) }?.summary.name, Daypart(now))
    }

    /// The room above the first row where Widgie stands, with its bubble beside it.
    @ViewBuilder private func stage(_ now: Date) -> some View {
        if let perch, let point = perchPoint {
            let height = stageHeight(perch)
            let side = perch.bubble
            let sole = Caret.sole(.lean(side))
            // An overlay, so Widgie, who stands taller than the room, never pushes the first row down.
            Color.clear.frame(height: height)
                .overlay(alignment: .topLeading) {
                    Bubble(words: words(now), tail: side == .left ? .right : .left)
                        .frame(
                            maxWidth: perch.bubbleWidth(column: column, x: point.x, large: typeSize.isAccessibilitySize)
                        )
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: { height in
                            if height > 0 { bubbleHeight = max(42, height) }
                        }
                        .frame(width: side == .left ? point.x - 31 : nil, alignment: .trailing)
                        .padding(.leading, side == .left ? 0 : point.x + 31)
                        .padding(.top, height - lift)
                }
                .overlay(alignment: .bottomLeading) {
                    FeedHero(leaning: side, act: act)
                        .offset(x: point.x - sole.x * FeedHero.size, y: 2 - (sole.y - 1) * FeedHero.size)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Widgie hops from where it last stood to `new`, and speaks again once it lands. Returns whether it hopped.
    @discardableResult private func hop(to new: CGPoint?) -> Bool {
        guard let new else { return false }
        let old = perchedAt
        perchedAt = new
        guard let old, old != new, !reduceMotion else { return false }
        act.play(.move(CGSize(width: old.x - new.x, height: old.y - new.y)))
        hops += 1
        let hop = hops
        speaking = false
        Task {
            try? await Task.sleep(for: .milliseconds(560))
            if hops == hop { speaking = true }
        }
        return true
    }

    /// Says `line` for a while, then goes back to the greeting.
    private func say(_ line: String, for seconds: Double) {
        saying?.cancel()
        said = line
        saying = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            said = nil
        }
    }

    /// A tap on a face: the widget's own action, then Widgie hops and says so. Scrolled away from Widgie, the line
    /// is only read out.
    private func perform(_ tap: Tap, input: [String: InputValue] = [:]) {
        touched = .now
        library.perform(tap, input: input)
        guard let name = library.items.first(where: { $0.id.rawValue == tap.widget })?.summary.name else { return }
        let line = Speech.tapped(name)
        if scrolled > 140 {
            AccessibilityNotification.Announcement(line).post()
            return
        }
        act.play(.hop)
        say(line, for: 2.4)
    }

    /// The new card settles in where you can see it, under Widgie, and Widgie points it out as it touches down.
    private func land(_ id: WidgetID, scroller: ScrollViewProxy) async {
        settling = id
        defer { landed = id }
        for _ in 0..<40 where item(id) == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let arrived = item(id) else {
            settling = nil
            return
        }
        if scrolled > 4 {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) { scroller.scrollTo(Self.top, anchor: .top) }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : min(480, 160 + Int(scrolled * 0.5))))
        }
        withAnimation(reduceMotion ? .linear(duration: 0.15) : .timingCurve(0.22, 0.8, 0.26, 1, duration: 0.26)) {
            settling = nil
        }
        let moved = hop(to: perchPoint)
        if !reduceMotion {
            try? await Task.sleep(for: .milliseconds(moved ? 560 : 200))
            if !moved, perch?.id == id { act.play(.smallHop) }
        }
        say(Speech.landed(arrived.summary.name, buttons: arrived.faces.values.contains { $0.hasButtons }), for: 3.2)
    }

    /// Now and then, while you are not busy with something, Widgie blinks twice, glances at your widgets, or
    /// hops a little: every 8 to 11 seconds, only on Widgets, at the top of the feed, after 4 untouched seconds.
    private func idle() async {
        guard active, !reduceMotion else { return }
        var beat = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(8000 + (beat % 3) * 1500))
            guard !Task.isCancelled else { return }
            let quiet = Date.now.timeIntervalSince(touched) > 4 && scrolled < 140 && shown == nil && session == nil
            guard quiet, perch != nil else { continue }
            act.play([HeroAct.Kind.blink, .glance, .smallHop][beat % 3])
            beat += 1
        }
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
                .opacity(risen || reduceMotion ? 1 : 0)
                .offset(y: risen || reduceMotion ? 0 : 18)
                .scaleEffect(risen || reduceMotion ? 1 : 0.98)
                .animation(.spring(duration: 0.42, bounce: 0.2).delay(Double(index) * 0.05), value: risen)
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
                touched = .now
                library.showForm(for: $0)
            } open: {
                touched = .now
                shown = Shown(id: id)
            }
            .scaleEffect(settling == id ? 0.94 : 1)
            .opacity(settling == id ? 0 : 1)
            .contextMenu {
                Button("Change it", systemImage: "pencil") { session = DescribeSession(editing: id) }
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = id }
            }
            .accessibilityAction(named: "Open") { shown = Shown(id: id) }
            .accessibilityAction(named: "Change it") { session = DescribeSession(editing: id) }
        }
    }

    // MARK: Empty

    /// No widgets yet: the big Widgie asks for one.
    private func empty(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            HStack(alignment: .top, spacing: 0) {
                Bubble(words: words(now), tail: .right)
                    .frame(maxWidth: 212, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 18)
                HoppingCaret(pose: .lean(.left), size: 190, cue: act.serial)
                    .padding(.trailing, -24)
            }
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
