import PhotosUI
import SwiftUI
import WidgetBuilder
import WidgetEngine

/// Make as a chat with Widgie, as the prototype draws it. Empty, it greets you and offers three ideas. Then your
/// words go up as ink bubbles, Widgie answers beside them, and the draft stands below the thread with Widgie on it:
/// traced as a sketch while the first build runs, the live face once it lands, kept as it was while a change builds.
/// Save widget sits under the draft and the change chips ride above the composer. `saved` gets the saved widget and
/// its tile, after the confetti.
struct ChatView: View {
    let chat: Chat
    /// Whether the moon steps aside, as it does while a thread fills the screen or the page scrolls.
    @Binding var pastMoon: Bool
    let saved: (WidgetID, Launch) -> Void

    var body: some View {
        let session = chat.session
        ZStack {
            Group {
                if case .failed(let failure, .open) = session.phase {
                    Unopened(failure: failure, leave: chat.leave)
                } else {
                    Conversation(chat: chat, session: session, pastMoon: $pastMoon, saved: saved)
                }
            }
            .id(ObjectIdentifier(session))
            .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.28), value: ObjectIdentifier(session))
        .task(id: ObjectIdentifier(session)) { await session.open() }
        .onChange(of: session.phase) { chat.resume() }
        .sheet(item: Bindable(session.preview).form) { shown in
            FormSheet(form: shown.form) { input in
                session.preview.perform(shown.form.tap, input: input)
                session.preview.form = nil
            }
        }
        .alert(
            "Something went wrong", isPresented: .constant(session.preview.message != nil),
            actions: { Button("OK") { session.preview.message = nil } },
            message: { Text(session.preview.message ?? "") }
        )
        .foregroundStyle(Palette.text)
        .tint(Palette.caret)
    }
}

/// Make's chat over the app, changing a library widget: it opens on the widget's card, Close asks before it drops a
/// change, and Save replaces the widget, bursts confetti and closes. It hides the app's sky behind its own. The
/// presenter makes `chat` once, as it opens the cover, since a `State` here would build one on every redraw.
struct EditChat: View {
    let library: Library
    let chat: Chat

    var body: some View {
        ChatView(chat: chat, pastMoon: .constant(true)) { _, _ in
            library.refresh()
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                chat.close()
            }
        }
        .background { Sky(moon: false) }
        .coversSky()
    }
}

/// The page of one session: the empty page or the thread, the bar over it, and the composer under it.
private struct Conversation: View {
    let chat: Chat
    @Bindable var session: DescribeSession
    @Binding var pastMoon: Bool
    let saved: (WidgetID, Launch) -> Void

    @FocusState private var typing: Bool
    @State private var scrolled = false
    @State private var viewport: CGFloat = 0
    /// The draft card's frame in the window, where its flight to the Widgets tab starts.
    @State private var tile = CGRect.zero
    @State private var act = HeroAct()
    @State private var leaving = false
    @State private var position = ScrollPosition(edge: .top)
    @State private var track = Track()
    @Environment(Flights.self) private var flights
    @Environment(\.pageHidden) private var pageHidden
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the thread is scrolled, where the draft is in it, and where the end of the thread and the composer are in
    /// the window. Keeping the draft in place and in view reads these, but `body` never does, so scrolling rebuilds
    /// nothing.
    private final class Track {
        /// How far the thread is scrolled from its top, as `ScrollPosition` counts.
        var offset: CGFloat = 0
        /// The bottom of the bar and the top of the composer with its chips, between which the thread shows.
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        /// The top of Widgie's latest answer.
        var reply: CGFloat = 0
        /// The draft's top in the thread's own space, which only the messages above it move, and the line Widgie
        /// opened with when it was measured.
        var draftTop: CGFloat?
        var opening: String?
        var end: CGFloat = 0
        /// Where a scroll this view started is heading, until it gets there or the person takes over.
        var aim: CGFloat?

        var target: CGFloat { aim ?? offset }
    }

    static let margin: CGFloat = 20
    nonisolated private static let thread = "thread"

    var body: some View {
        ScrollView {
            Group {
                if session.blank {
                    Hello(ideas: chat.ideas, leaning: typing) { chat.send($0) }
                        .frame(minHeight: max(0, viewport - 12), alignment: .top)
                } else {
                    thread
                }
            }
            .padding(.horizontal, Self.margin)
            .padding(.bottom, 12)
            .coordinateSpace(.named(Self.thread))
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.contentOffset.y + $0.contentInsets.top
        } action: { [track] _, offset in
            track.offset = offset
            if let aim = track.aim, abs(aim - offset) < 1 { track.aim = nil }
        }
        .onScrollPhaseChange { [track] _, phase in
            if phase == .interacting { track.aim = nil }
        }
        .onScrollGeometryChange(for: Bool.self) {
            !Sky.moonShown(scrolled: $0.contentOffset.y + $0.contentInsets.top)
        } action: { _, past in
            scrolled = past
        }
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.containerSize.height
        } action: { _, height in
            viewport = height
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !session.blank { bar }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !pageHidden { composer }
        }
        .onChange(of: reply) { settle() }
        .onChange(of: chat.question) { settle() }
        .onChange(of: session.opening) { settle() }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            // The faces are drawn at the column's size, which a draft keeps once it is on show.
            if session.draft == nil { session.preview.sizes = FaceSizes(column: width - 2 * Self.margin) }
        }
        .onChange(of: scrolled || !session.blank, initial: true) { _, past in pastMoon = past }
        .onChange(of: session.latest?.result) { was, now in react(was: was, now: now) }
        .onChange(of: session.phase) { _, phase in
            if case .saved(let id) = phase { leave(id) }
        }
        .returnSends($session.words, send)
        .sensoryFeedback(trigger: session.phase) { _, new in
            switch new {
            case .saved: .success
            case .failed: .warning
            default: nil
            }
        }
    }

    private var reply: [DescribeSession.TurnResult] { session.turns.map(\.result) }

    // MARK: The bar

    private var bar: some View {
        HStack {
            Text(chat.editing ? "Change it" : "Make")
                .display(size: 28, relativeTo: .title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if chat.editing {
                SoftCloseButton { chat.leave() }
                    .disabled(session.phase == .saving)
                    .padding(.trailing, -5)
            } else {
                Button {
                    typing = false
                    chat.leave()
                } label: {
                    Label("New", systemImage: "plus")
                        .labelStyle(MiniLabelStyle())
                }
                .buttonStyle(MiniButtonStyle())
                .disabled(!session.ready && session.phase != .opening)
                .accessibilityLabel("New widget")
            }
        }
        .padding(.horizontal, Self.margin)
        // The prototype's bar row starts 60 points down the screen, 2 above the safe area.
        .padding(.top, -2)
        .padding(.bottom, 10)
        .onGeometryChange(for: CGFloat.self) {
            $0.frame(in: .global).maxY
        } action: { [track] bottom in
            track.top = bottom
        }
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Palette.skyTop.opacity(0.8))
            }
            .mask {
                LinearGradient(
                    stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)], startPoint: .top,
                    endPoint: .bottom)
            }
            .padding(.bottom, -28)
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: The thread

    private var thread: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let opening = session.opening {
                WidgieSays(words: opening, voice: .normal)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .global).minY
                    } action: { [track] top in
                        if session.turns.isEmpty { track.reply = top }
                    }
                    .arriving()
            }
            ForEach(session.turns) { turn in
                YouSaid(turn: turn).arriving()
                answer(turn)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .global).minY
                    } action: { [track] top in
                        if turn.id == session.latest?.id { track.reply = top }
                    }
                    .arriving()
            }
            studio
            after
            if let question = chat.question {
                Confirm(question: question, keep: chat.keepEditing, replace: chat.replace)
                    .arriving()
            }
            Color.clear.frame(height: 1)
                .onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .global).maxY
                } action: { [track] end in
                    track.end = end
                }
            // Room to scroll, so a draft can stay where it is while the messages of a change go in above it.
            if session.draft != nil { Color.clear.frame(height: 120) }
        }
        // The prototype's 8 under the bar and the thread's own 20.
        .padding(.top, 28)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.25), value: reply)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.2), value: chat.question)
    }

    @ViewBuilder private func answer(_ turn: DescribeSession.Turn) -> some View {
        switch turn.result {
        case .pending:
            WidgieSays(words: status, working: true, voice: .low)
        case .accepted(let note):
            WidgieSays(words: note, voice: .normal)
        case .cancelled:
            WidgieSays(words: "Stopped. Nothing changed.", voice: .normal)
        case .failed(let failure):
            let current = turn.id == session.latest?.id && session.phase == .failed(failure, .turn)
            WidgieFailed(failure: failure, action: current ? action(for: failure) : nil)
        }
    }

    /// The build's step in Widgie's words. A change to a draft is "Changing it" until it is checked.
    private var status: String {
        guard case .building(let step) = session.phase else { return "Writing your widget" }
        if case .writing = step, session.draft != nil { return "Changing it" }
        return step.title
    }

    private func action(for failure: DescribeSession.Failure) -> (title: String, run: () -> Void) {
        switch failure {
        case .gaveUp: ("Say it another way", { session.dismissFailure() })
        case .unsaved, .unavailable, .unopened: ("OK", { session.dismissFailure() })
        case .unreachable, .refused, .interrupted, .broken: ("Try again", { chat.retry() })
        }
    }

    /// The draft with Widgie standing on it, or the sketch Widgie traces while the first build runs. Widgie's foot
    /// is where the sketch starts and ends, so the drawing becomes the tile with Widgie in place.
    @ViewBuilder private var studio: some View {
        let size = session.preview.sizes.medium
        let perch = CGPoint(x: (size.width * 214 / 362).rounded(), y: 0)
        let tracing = session.draft == nil && session.latest?.result == .pending
        if session.preview.faces[.medium] != nil || tracing {
            ZStack(alignment: .topLeading) {
                if let face = session.preview.faces[.medium] {
                    DraftCard(
                        face: face, name: session.preview.name, size: size, act: act, perch: perch,
                        saved: session.phase.isSaved, flown: leaving && !chat.editing
                    ) {
                        session.preview.perform($0)
                        act.play(.smallHop)
                    } form: {
                        session.preview.showForm(for: $0)
                    }
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        tile = CGRect(origin: CGPoint(x: $0.minX, y: $0.maxY - size.height), size: size)
                    }
                    .transition(.opacity)
                } else {
                    Sketch(size: size, perch: perch, started: session.buildStarted)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.32), value: session.draft)
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named(Self.thread)).minY
            } action: { top in
                hold(draftAt: top)
            }
        }
    }

    /// Save widget under the draft, or what stopped the save.
    @ViewBuilder private var after: some View {
        if case .failed(let failure, .save) = session.phase {
            WidgieFailed(failure: failure, action: action(for: failure)).arriving()
        } else if session.draft != nil {
            Button {
                typing = false
                chat.save()
            } label: {
                Group {
                    if saving {
                        ProgressView().tint(Palette.keyLabel).accessibilityLabel("Saving")
                    } else {
                        Text("Save widget")
                    }
                }
                .frame(minWidth: 172)
            }
            .buttonStyle(KeyButtonStyle())
            .fixedSize()
            .disabled(!session.ready && !saving)
            .opacity(leaving ? 0 : 1)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .transition(reduceMotion ? .opacity : .offset(y: 12).combined(with: .opacity))
        }
    }

    private var saving: Bool { session.phase == .saving }

    // MARK: The composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.draft != nil, !chips.isEmpty, !saving, !leaving {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.self) { chip in
                            let working = session.latest?.result == .pending && session.latest?.change == chip.change
                            Button(working ? "Changing" : chip.words) {
                                typing = false
                                chat.send(chip.words, change: chip.change)
                            }
                            .buttonStyle(ChangeChipStyle())
                        }
                    }
                    .padding(.horizontal, Self.margin)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -Self.margin)
                .disabled(!session.ready)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Suggested changes")
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
            Composer(session: session, typing: $typing, send: send)
        }
        // The composer and its chips stop growing at the first accessibility size, so the words in them still fit
        // a line beside the keys.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .onGeometryChange(for: CGFloat.self) {
            $0.frame(in: .global).minY
        } action: { [track] top in
            track.bottom = top
        }
        .padding(.horizontal, Self.margin)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.2), value: chips)
        .animation(.easeOut(duration: 0.2), value: session.ready)
    }

    /// Scrolls by as much as the messages above the draft moved it, so the draft stays where it was on screen. The
    /// line Widgie opens an edit with is not held: it goes in above the card and stays in view.
    private func hold(draftAt top: CGFloat) {
        defer {
            track.draftTop = top
            track.opening = session.opening
        }
        guard let was = track.draftTop, abs(top - was) > 0.5, track.opening == session.opening else { return }
        scroll(to: track.target + top - was)
    }

    /// Once the thread has laid out what changed, brings it into view.
    private func settle() {
        Task {
            await Task.yield()
            keepInView()
        }
    }

    /// Scrolls only as far as it takes to show Widgie's answer and the end of the thread, Save included, as an
    /// answer lands. The end wins when both do not fit.
    private func keepInView() {
        let ahead = track.target - track.offset
        var by = min(0, track.reply - ahead - track.top - 8)
        by = max(by, track.end - ahead + 12 - track.bottom)
        guard abs(by) > 0.5 else { return }
        scroll(to: max(0, track.target + by))
    }

    /// A scroll past the end stops short of its aim, which then lapses once the scroll is over.
    private func scroll(to y: CGFloat) {
        track.aim = y
        withAnimation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.2)) { position.scrollTo(y: y) }
        Task { [track] in
            try? await Task.sleep(for: .milliseconds(600))
            if track.aim == y { track.aim = nil }
        }
    }

    private var chips: [Changes.Chip] {
        guard let traits = session.preview.faces[.medium]?.traits else { return [] }
        return Changes.suggested(for: traits, used: session.usedChanges)
    }

    private func send() {
        guard session.canSend else { return }
        typing = false
        chat.send()
    }

    /// Widgie on the draft glances while a change builds and hops when one lands.
    private func react(was: DescribeSession.TurnResult?, now: DescribeSession.TurnResult?) {
        switch now {
        case .pending where session.draft != nil: act.play(.glance)
        case .accepted: act.play(.hop)
        default: break
        }
    }

    /// The saved draft leaves: confetti bursts from it and Widgie hops, then 240 ms later its tile flies to the
    /// Widgets tab, which the presenter runs. Saved while you are on another tab, nothing bursts.
    private func leave(_ id: WidgetID) {
        let launch = Launch(
            name: session.preview.name ?? "Your widget", face: session.preview.faces[.medium], from: tile)
        Task {
            act.play(.hop)
            if !reduceMotion && !pageHidden {
                flights.burst(from: tile)
                try? await Task.sleep(for: .milliseconds(240))
            }
            leaving = true
            saved(id, launch)
        }
    }
}

extension DescribeSession.Phase {
    fileprivate var isSaved: Bool {
        if case .saved = self { true } else { false }
    }
}

// MARK: The empty page

/// Make with nothing in it yet: what to do, Widgie asking, and three ideas from the templates to start from.
private struct Hello: View {
    let ideas: [Template.Suggestion]
    /// Widgie leans toward the composer while you type.
    let leaning: Bool
    let send: (String) -> Void

    @State private var risen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.pageHidden) private var pageHidden
    @Environment(\.colorScheme) private var scheme

    private static let greeting = "Hi! What should we make today?"

    private func widgie(size: CGFloat, grounded: Bool = true) -> some View {
        Caret(pose: .lean(.left), size: size, grounded: grounded)
            .rotationEffect(.degrees(leaning && !reduceMotion ? -6 : 0), anchor: Caret.foot(.lean(.left)))
            .animation(.easeOut(duration: 0.22), value: leaning)
            .accessibilityHidden(true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Say it in your own words")
                    .font(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(Palette.secondary)
                Text("Make")
                    .display(size: 40)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.top, 6)
            Spacer(minLength: 8).frame(maxHeight: 40)
            // At the accessibility text sizes the bubble takes the row, so its words have room, and Widgie stands under it.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .trailing, spacing: 0) {
                    Bubble(words: Self.greeting, tail: .down, voice: pageHidden ? .silent : .low)
                    widgie(size: 140).padding(.trailing, 24)
                }
                .padding(.top, 12)
            } else {
                stage
            }
            Spacer(minLength: 12)
            if !ideas.isEmpty {
                Text("Or start from one of these")
                    .font(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 12)
                VStack(spacing: 10) {
                    ForEach(Array(ideas.enumerated()), id: \.element.title) { index, idea in
                        IdeaCard(idea: idea) { send(idea.title) }
                            .opacity(risen || reduceMotion ? 1 : 0)
                            .offset(y: risen || reduceMotion ? 0 : 14)
                            .animation(
                                .spring(duration: 0.42, bounce: 0.2).delay(0.08 + Double(index) * 0.05), value: risen)
                    }
                }
            }
        }
        .onAppear { risen = true }
    }
}

extension Hello {
    /// The prototype's stage, measured from the column's trailing edge: Widgie's foot 72 points in and 206 down on a
    /// soft shadow, and the bubble ending 138 points in, at most 212 wide, so the greeting breaks after "make".
    fileprivate var stage: some View {
        let foot = Caret.sole(.lean(.left))
        let size: CGFloat = 192
        return ZStack(alignment: .topTrailing) {
            Ellipse()
                .fill(
                    EllipticalGradient(
                        colors: [Self.shadow(scheme), .clear], startRadiusFraction: 0, endRadiusFraction: 0.5)
                )
                .frame(width: 100, height: 13)
                .padding(.trailing, 22)
                .padding(.top, 200)
            widgie(size: size, grounded: false)
                .offset(x: (1 - foot.x) * size - 72, y: 206 - foot.y * size)
            // iOS moves a word down rather than leave one alone on the last line, which the prototype's browser does
            // not, so the greeting breaks after "make" by hand while that line fits.
            ViewThatFits(in: .horizontal) {
                Bubble(words: "Hi! What should we make\ntoday?", tail: .right, voice: pageHidden ? .silent : .low)
                    .fixedSize()
                Bubble(words: Self.greeting, tail: .right, voice: pageHidden ? .silent : .low)
            }
            .frame(maxWidth: 212, alignment: .trailing)
            .padding(.trailing, 138)
            .padding(.top, 38)
        }
        .frame(maxWidth: .infinity, minHeight: 224, alignment: .topTrailing)
    }

    private static func shadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0, green: 6 / 255, blue: 20 / 255, opacity: 0.5)
            : Color(red: 18 / 255, green: 26 / 255, blue: 46 / 255, opacity: 0.3)
    }
}

private struct IdeaCard: View {
    let idea: Template.Suggestion
    let send: () -> Void

    var body: some View {
        Button(action: send) {
            HStack(spacing: 12) {
                Image(systemName: idea.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(idea.tint.foreground)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(idea.tint.background))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(idea.title)
                        .font(size: 16, weight: .semibold)
                        .tracking(-0.2)
                    Text(idea.subtitle)
                        .font(size: 13, weight: .medium, relativeTo: .footnote)
                        .foregroundStyle(Palette.secondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.secondary.opacity(0.7))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Palette.text)
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface).restShadow())
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(SquishStyle(scale: 0.97))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Sends it to Widgie")
    }
}

extension Template.Suggestion.Tint {
    var background: Color {
        switch self {
        case .amber: Color(.widgieIdeaAmber)
        case .coral: Color(.widgieIdeaCoral)
        case .pink: Color(.widgieIdeaPink)
        case .mint: Color(.widgieIdeaMint)
        case .sky: Color(.widgieIdeaSky)
        case .lilac: Color(.widgieIdeaLilac)
        }
    }

    var foreground: Color {
        switch self {
        case .amber: Color(.widgieIdeaAmberInk)
        case .coral: Color(.widgieIdeaCoralInk)
        case .pink: Color(.widgieIdeaPinkInk)
        case .mint: Color(.widgieIdeaMintInk)
        case .sky: Color(.widgieIdeaSkyInk)
        case .lilac: Color(.widgieIdeaLilacInk)
        }
    }
}

// MARK: Messages

extension View {
    /// A chat message coming in: it slides up 18 points from 94 percent, or only fades with Reduce Motion.
    fileprivate func arriving() -> some View {
        modifier(Arriving())
    }
}

private struct Arriving: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .offset(y: 18).combined(with: .scale(scale: 0.94, anchor: .bottom)).combined(
                        with: .opacity),
                    removal: .opacity))
    }
}

/// Your words, in ink on the right, with the picture you sent.
private struct YouSaid: View {
    let turn: DescribeSession.Turn

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let picture = turn.image {
                Thumbnail(picture: picture, size: 52)
            }
            Text(turn.words)
                .font(size: 15.5, weight: .semibold, relativeTo: .callout)
                .tracking(-0.15)
                .lineSpacing(2)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20,
                        style: .continuous
                    )
                    .fill(Palette.youFill)
                    .shadow(color: Palette.widgetShadow, radius: 10, y: 10)
                }
        }
        .frame(maxWidth: 262, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(turn.words)")
    }
}

/// Widgie's words in a white bubble on the left. While Widgie works the words end in the blinking bar, and VoiceOver
/// reads each new step politely, but nothing while you are on another tab.
private struct WidgieSays: View {
    let words: String
    var working = false
    let voice: Bubble.Voice

    @Environment(\.pageHidden) private var pageHidden

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            Text(words)
                .contentTransition(.opacity)
            if working {
                CursorBar(color: Palette.ink, height: 17)
                    .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 3 }
            }
        }
        .font(size: 15.5, weight: .semibold, relativeTo: .callout)
        .tracking(-0.15)
        .lineSpacing(2)
        .foregroundStyle(Palette.ink)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 20, bottomLeadingRadius: 6, bottomTrailingRadius: 20, topTrailingRadius: 20,
                style: .continuous
            )
            .fill(Palette.bubble)
            .shadow(color: Palette.restShadow.opacity(0.5), radius: 2, y: 2)
            .shadow(color: Palette.restShadow, radius: 12, y: 10)
        }
        .animation(.easeInOut(duration: 0.25), value: words)
        .frame(maxWidth: 262, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Widgie: \(words)")
        .accessibilityAddTraits(working ? .updatesFrequently : [])
        .onChange(of: words, initial: true) { _, words in
            guard !pageHidden else { return }
            var line = AttributedString(words)
            if voice == .low { line.accessibilitySpeechAnnouncementPriority = .low }
            AccessibilityNotification.Announcement(line).post()
        }
    }
}

/// What went wrong, from a grey Widgie slumped beside it, with the one way forward while it still applies.
private struct WidgieFailed: View {
    let failure: DescribeSession.Failure
    let action: (title: String, run: () -> Void)?

    @Environment(\.pageHidden) private var pageHidden

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Caret(pose: .slump, size: 64, color: Palette.failureCaret, eye: Palette.failureGround, alive: false)
                .frame(width: 44, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.title)
                        .font(size: 15.5, weight: .semibold, relativeTo: .callout)
                        .tracking(-0.15)
                    #if DEBUG
                        if failure == .unreachable {
                            Text("Check that the bridge is running.")
                                .font(size: 13.5, weight: .medium, relativeTo: .footnote)
                                .opacity(0.75)
                        }
                    #endif
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Widgie: \(failure.title)")
                if let action {
                    Button(action.title, action: action.run)
                        .buttonStyle(
                            MiniButtonStyle(fill: Palette.failureButtonFill, label: Palette.failureButtonLabel))
                }
            }
            .foregroundStyle(Palette.failureText)
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 20, bottomLeadingRadius: 6, bottomTrailingRadius: 20, topTrailingRadius: 20,
                    style: .continuous
                )
                .fill(Palette.failureGround)
                .shadow(color: Palette.restShadow, radius: 12, y: 10)
            }
        }
        .frame(maxWidth: 310, alignment: .leading)
        .onAppear {
            if !pageHidden { AccessibilityNotification.Announcement(failure.title).post() }
        }
    }
}

/// The question before a draft goes, asked in the thread with the draft still in view. VoiceOver lands on Keep
/// editing.
private struct Confirm: View {
    let question: Chat.Question
    let keep: () -> Void
    let replace: () -> Void

    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.words)
                .font(size: 14.5, weight: .semibold, relativeTo: .subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Keep editing", action: keep)
                    .buttonStyle(MiniButtonStyle())
                    .accessibilityFocused($focused)
                Button(question.replace, action: replace)
                    .buttonStyle(MiniButtonStyle(fill: Palette.keyFill, label: Palette.keyLabel))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface).restShadow())
        .accessibilityElement(children: .contain)
        .onAppear {
            AccessibilityNotification.Announcement(question.words).post()
            focused = true
        }
    }
}

// MARK: The draft

/// The live draft, Widgie standing on its top edge. Its own buttons work on scratch rows. It keeps its identity as
/// it redraws, so VoiceOver stays on the button it was on.
private struct DraftCard: View {
    let face: Face
    let name: String?
    let size: CGSize
    let act: HeroAct
    /// Where Widgie's foot stands on the face's top edge.
    let perch: CGPoint
    /// Widgie jumps for joy on a saved draft.
    let saved: Bool
    /// The saved tile has flown to the Widgets tab, leaving its outline behind, and Widgie drops away once it lands.
    /// With Reduce Motion the tile only dims and Widgie stays.
    let flown: Bool
    let tap: @MainActor @Sendable (Tap) -> Void
    let form: @MainActor @Sendable (Tap) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let headroom: CGFloat = 112

    var body: some View {
        let sole = Caret.sole(saved ? .jump : .lean(.left))
        let dropped = flown && !reduceMotion
        VStack(spacing: 0) {
            Color.clear.frame(width: size.width, height: Self.headroom)
            FaceView(face, host: .app(tap: tap, form: form))
                .frame(width: size.width, height: size.height)
                .faceShadow()
                .opacity(flown ? (reduceMotion ? 0.4 : 0) : 1)
                .background {
                    if flown && !reduceMotion {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Palette.caret.opacity(0.35), lineWidth: 3)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(name ?? "Your widget"), your draft")
        }
        .overlay(alignment: .topLeading) {
            FeedHero(leaning: .left, act: act, jumping: saved)
                .offset(
                    x: perch.x - sole.x * FeedHero.size,
                    y: Self.headroom + perch.y + 2 - sole.y * FeedHero.size + (dropped ? 44 : 0)
                )
                .opacity(dropped ? 0 : 1)
                .animation(.timingCurve(0.5, 0, 0.75, 0.4, duration: 0.36).delay(Flights.flightTime), value: dropped)
        }
    }
}

/// The widget's outline as Widgie draws it: from where Widgie will stand, clockwise round the edge and back in 2.2
/// seconds, the parts going from dashed to solid as the pen passes them. A build takes about 40 seconds, so the pen
/// then keeps riding the edge, a lap every 7 seconds, until the widget lands. Drawn and still with Reduce Motion.
private struct Sketch: View {
    let size: CGSize
    let perch: CGPoint
    let started: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let headroom: CGFloat = 112
    private static let pen: CGFloat = 116
    private static let trace: TimeInterval = 2.2
    private static let lap: TimeInterval = 7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let elapsed = reduceMotion ? .infinity : max(0, timeline.date.timeIntervalSince(started))
            drawing(elapsed: elapsed)
        }
        .frame(width: size.width, height: size.height + Self.headroom, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func drawing(elapsed: TimeInterval) -> some View {
        let outline = Self.outline(size, from: perch.x)
        let k = min(1, elapsed / Self.trace)
        let drawn = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
        let riding =
            reduceMotion ? 0 : k < 1 ? drawn : ((elapsed - Self.trace) / Self.lap).truncatingRemainder(dividingBy: 1)
        let tip = riding > 0 ? outline.trimmedPath(from: 0, to: riding).currentPoint ?? perch : perch
        // The pen leans inward, so it never leaves the screen.
        let side: Caret.Side = tip.x > size.width / 2 ? .left : .right
        let foot = Caret.foot(.draw(side))
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                outline.trimmedPath(from: 0, to: drawn).stroke(
                    Palette.caret, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                ForEach(Array(Self.parts(size).enumerated()), id: \.offset) { _, part in
                    let solid = drawn >= part.at
                    RoundedRectangle(cornerRadius: part.radius, style: .continuous)
                        .fill(Palette.caret.opacity(solid ? 0.32 : 0))
                        .overlay {
                            RoundedRectangle(cornerRadius: part.radius, style: .continuous)
                                .stroke(
                                    Palette.caret.opacity(solid ? 0 : 0.5),
                                    style: StrokeStyle(lineWidth: 2, dash: [4, 5]))
                        }
                        .scaleEffect(solid ? 1 : 0.94)
                        .opacity(drawn >= part.at - 0.12 ? 1 : 0)
                        .animation(.easeOut(duration: 0.38), value: solid)
                        .frame(width: part.rect.width, height: part.rect.height)
                        .offset(x: part.rect.minX, y: part.rect.minY)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .offset(y: Self.headroom)
            Caret(pose: .draw(side), size: Self.pen, grounded: false)
                .position(
                    x: tip.x + Self.pen * (0.5 - foot.x), y: Self.headroom + tip.y + Self.pen * (0.5 - foot.y))
        }
    }

    /// The edge, from `x` on the top edge clockwise and back to it.
    private static func outline(_ size: CGSize, from x: CGFloat) -> Path {
        let (width, height, radius) = (size.width, size.height, 24.0)
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: width - radius, y: 0))
        path.addArc(tangent1End: CGPoint(x: width, y: 0), tangent2End: CGPoint(x: width, y: radius), radius: radius)
        path.addLine(to: CGPoint(x: width, y: height - radius))
        path.addArc(
            tangent1End: CGPoint(x: width, y: height), tangent2End: CGPoint(x: width - radius, y: height),
            radius: radius)
        path.addLine(to: CGPoint(x: radius, y: height))
        path.addArc(
            tangent1End: CGPoint(x: 0, y: height), tangent2End: CGPoint(x: 0, y: height - radius), radius: radius)
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addArc(tangent1End: .zero, tangent2End: CGPoint(x: radius, y: 0), radius: radius)
        path.closeSubpath()
        return path
    }

    /// A label, a big number and two buttons, each turning solid once the pen has passed it.
    private static func parts(_ size: CGSize) -> [(rect: CGRect, radius: CGFloat, at: Double)] {
        let (width, height) = (size.width, size.height)
        return [
            (CGRect(x: 18, y: 22, width: 64, height: 12), 6, 0.7),
            (CGRect(x: 18, y: 50, width: 118, height: 40), 10, 0.62),
            (CGRect(x: 18, y: height - 52, width: 34, height: 34), 17, 0.48),
            (CGRect(x: width - 60, y: height - 60, width: 42, height: 42), 21, 0.2),
        ]
    }
}

// MARK: The composer

/// The field pinned over the tab bar: a quiet photo button, the words growing to five lines, and the send key,
/// which stops the build while one runs.
private struct Composer: View {
    @Bindable var session: DescribeSession
    var typing: FocusState<Bool>.Binding
    let send: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var prompt: String {
        if case .saved = session.phase { return "Describe a widget" }
        return session.draft == nil ? "Describe a widget" : "Ask for a change"
    }
    private var building: Bool {
        if case .building = session.phase { true } else { false }
    }
    /// The blinking bar asks for the first words, and only those.
    private var idle: Bool { session.blank && session.words.isEmpty && !typing.wrappedValue }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            PhotoButton(picture: $session.picture, item: $session.pendingPhoto)
                .disabled(!session.ready)
            ZStack(alignment: .leading) {
                if idle {
                    CursorBar(color: Palette.text.opacity(0.4), height: 20)
                        .padding(.leading, 2)
                }
                TextField(
                    prompt, text: $session.words, prompt: Text(prompt).foregroundStyle(Palette.secondary),
                    axis: .vertical
                )
                .lineLimit(1...5)
                .font(size: 17, weight: .medium)
                .tracking(-0.2)
                .foregroundStyle(Palette.text)
                .focused(typing)
                .submitLabel(.send)
                .padding(.leading, session.words.isEmpty && !typing.wrappedValue ? 10 : 2)
                .accessibilityLabel(prompt)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            sendKey
        }
        .padding(8)
        .frame(minHeight: 60)
        .background {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            shape.fill(.ultraThinMaterial)
                .overlay { shape.fill(Palette.composer) }
                .overlay { if scheme == .dark { shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5) } }
                .liftShadow()
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { typing.wrappedValue = true }
    }

    @ViewBuilder private var sendKey: some View {
        let ready = building || session.canSend
        Button {
            if building { session.cancel() } else { send() }
        } label: {
            Image(systemName: building ? "stop.fill" : "arrow.up")
                .font(.system(size: building ? 14 : 18, weight: .bold))
                .foregroundStyle(ready ? Palette.keyLabel : Palette.text.opacity(0.35))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ready ? Palette.keyFill : Palette.text.opacity(0.1))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishStyle())
        .disabled(!ready)
        .accessibilityLabel(building ? "Stop" : "Send")
        .animation(.easeOut(duration: 0.2), value: ready)
    }
}

/// The photo button inside the composer: a quiet picture glyph, a spinner while the picked photo loads, or the
/// attached photo with a button to remove it.
private struct PhotoButton: View {
    @Binding var picture: Picture?
    /// The picked photo while it loads. It lives in the session, so a composer drawn again resumes the load.
    @Binding var item: PhotosPickerItem?

    @State private var unreadable = false

    var body: some View {
        Group {
            if let picture {
                Thumbnail(picture: picture, size: 40)
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            self.picture = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Palette.keyLabel)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Palette.keyFill))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .offset(x: 16, y: -16)
                        .accessibilityLabel("Remove picture")
                    }
            } else {
                // The picker's label closure is not main actor isolated, so it reads a copy of the state.
                let loading = item != nil
                PhotosPicker(selection: $item, matching: .images) {
                    Group {
                        if loading {
                            ProgressView()
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Palette.secondary.opacity(0.75))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Add a picture")
            }
        }
        // A newer selection cancels this load, so a slow earlier photo never replaces it or its error.
        .task(id: item) {
            guard let item else { return }
            let loaded = await Picture.load(item)
            guard !Task.isCancelled, item == self.item else { return }
            picture = loaded
            unreadable = loaded == nil
            self.item = nil
        }
        .alert("That photo didn’t load.", isPresented: $unreadable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try another one.")
        }
    }
}

extension View {
    /// The field wraps long text, so return sends instead of starting a new line.
    fileprivate func returnSends(_ text: Binding<String>, _ send: @escaping () -> Void) -> some View {
        onChange(of: text.wrappedValue) { _, value in
            guard value.contains("\n") else { return }
            text.wrappedValue = value.replacingOccurrences(of: "\n", with: "")
            send()
        }
    }
}

/// Changes that fit the draft on show, read off its face without asking the model: a color across the wheel from
/// the one it paints most, and a bigger number when it shows one. As in the prototype, a change whose turn landed
/// leaves, and a used recolor gives way to new colors. None when nothing fits.
enum Changes {
    enum Change: Hashable {
        case recolor, biggerNumber, newColors
    }

    struct Chip: Hashable {
        let change: Change
        let words: String
    }

    static func suggested(for traits: FaceTraits, used: Set<Change>) -> [Chip] {
        var chips: [Chip] = []
        if let hue = traits.hue, !used.contains(.recolor) {
            chips.append(Chip(change: .recolor, words: "Make it \(colorName(at: hue + 180))"))
        }
        if traits.showsNumber, !used.contains(.biggerNumber) {
            chips.append(Chip(change: .biggerNumber, words: "Bigger number"))
        }
        if traits.hue != nil, used.contains(.recolor), !used.contains(.newColors) {
            chips.append(Chip(change: .newColors, words: "Change the colors"))
        }
        return chips
    }

    /// The nearest everyday color name to a hue in degrees.
    static func colorName(at hue: Double) -> String {
        let names: [(hue: Double, name: String)] = [
            (0, "red"), (30, "orange"), (55, "yellow"), (125, "green"), (180, "teal"), (220, "blue"),
            (275, "purple"), (325, "pink"), (360, "red"),
        ]
        let hue = hue.truncatingRemainder(dividingBy: 360)
        return names.min { abs($0.hue - hue) < abs($1.hue - hue) }!.name
    }
}

/// A change suggested above the composer: a small soft key that sends its words.
private struct ChangeChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size: 13.5, weight: .semibold, relativeTo: .subheadline)
            .tracking(-0.15)
            .lineLimit(1)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.surface).restShadow())
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .padding(.vertical, -5)
            .modifier(Squish(pressed: configuration.isPressed, scale: 0.94, dimmed: 0.6))
    }
}

/// A small soft key, such as New or Keep editing: 36 points tall in a 44 point target.
struct MiniButtonStyle: ButtonStyle {
    var fill = Palette.surface
    var label = Palette.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size: 14, weight: .semibold, relativeTo: .subheadline)
            .foregroundStyle(label)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill).restShadow())
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .padding(.vertical, -4)
            .modifier(Squish(pressed: configuration.isPressed, scale: 0.94))
    }
}

private struct MiniLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 13, weight: .bold))
            configuration.title
        }
    }
}

private struct Squish: ViewModifier {
    let pressed: Bool
    let scale: CGFloat
    /// The opacity while disabled.
    var dimmed = 0.5

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduceMotion ? scale : 1)
            .opacity(isEnabled ? 1 : dimmed)
            .animation(.spring(duration: 0.3, bounce: 0.45), value: pressed)
    }
}

// MARK: Nothing to chat about

/// The widget the chat was to open could not be put into the preview, so there is nothing to refine: a grey
/// Widgie at a broken bridge, the one line, and a way out.
private struct Unopened: View {
    let failure: DescribeSession.Failure
    let leave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            BrokenBridge()
            Text(failure.title)
                .font(size: 30, weight: .heavy, relativeTo: .title)
                .tracking(-1)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.failureText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
            Button("Close", action: leave)
                .buttonStyle(KeyButtonStyle())
                .padding(.horizontal, 32)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.failureGround.ignoresSafeArea())
        .onAppear { AccessibilityNotification.Announcement(failure.title).post() }
    }
}

/// A bridge with a gap in it, and the caret bent over the gap.
private struct BrokenBridge: View {
    var body: some View {
        let width: CGFloat = 338
        let deck: CGFloat = 170
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let round = StrokeStyle(lineWidth: 5, lineCap: .round)
                var span = Path()
                span.move(to: CGPoint(x: -8, y: deck))
                span.addLine(to: CGPoint(x: width * 0.46, y: deck))
                span.move(to: CGPoint(x: width * 0.66, y: deck))
                span.addLine(to: CGPoint(x: width + 8, y: deck))
                context.stroke(span, with: .color(Palette.failureCaret), style: round)
                var ends = Path()
                ends.move(to: CGPoint(x: width * 0.46, y: deck))
                ends.addLine(to: CGPoint(x: width * 0.46 + 9, y: deck + 18))
                ends.move(to: CGPoint(x: width * 0.66, y: deck))
                ends.addLine(to: CGPoint(x: width * 0.66 - 8, y: deck + 17))
                context.stroke(
                    ends, with: .color(Palette.failureCaret.opacity(0.5)),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            }
            let size: CGFloat = 190
            let foot = Caret.foot(.slump)
            Caret(pose: .slump, size: size, color: Palette.failureCaret, eye: Palette.failureGround)
                .position(x: width * 0.36 + size * (0.5 - foot.x), y: deck + size * (0.5 - foot.y))
        }
        .frame(width: width, height: deck + 24)
        .accessibilityHidden(true)
    }
}
