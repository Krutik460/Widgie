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
        .previewForms(session.preview)
        .failureAlert(Bindable(session.preview).message)
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
        var openingLine: String?
        var end: CGFloat = 0
        /// Where a scroll this view started is heading, until it gets there or the person takes over.
        var aim: CGFloat?

        var target: CGFloat { aim ?? offset }
    }

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
            .padding(.horizontal, Page.margin)
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
        .onChange(of: results) { settle() }
        .onChange(of: chat.question) { settle() }
        .onChange(of: session.openingLine) { settle() }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            // The faces are drawn at the column's size, which a draft keeps once it is on show.
            if session.draft == nil { session.preview.sizes = FaceSizes(column: width - 2 * Page.margin) }
        }
        .onChange(of: scrolled || !session.blank, initial: true) { _, past in pastMoon = past }
        .onChange(of: session.latest?.result) { _, now in react(to: now) }
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

    private var results: [DescribeSession.TurnResult] { session.turns.map(\.result) }

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
        .padding(.horizontal, Page.margin)
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
            if let line = session.openingLine {
                WidgieSays(words: line, voice: .normal)
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
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.25), value: results)
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
        if failure.retryable { return ("Try again", { chat.retry() }) }
        return (failure == .gaveUp ? "Say it another way" : "OK", { session.dismissFailure() })
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
                    .padding(.horizontal, Page.margin)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -Page.margin)
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
        .padding(.horizontal, Page.margin)
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
            track.openingLine = session.openingLine
        }
        guard let was = track.draftTop, abs(top - was) > 0.5, track.openingLine == session.openingLine else { return }
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
    private func react(to now: DescribeSession.TurnResult?) {
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
