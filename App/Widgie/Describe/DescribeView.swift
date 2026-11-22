import PhotosUI
import SwiftUI
import WidgetBuilder
import WidgetEngine

/// The describe flow: describe, build, try it, save. One screen per step, with the step bar across the top
/// and a banner from the bottom when a turn fails. `close` gets the saved widget, or nil when nothing was saved.
struct DescribeView: View {
    @Bindable var session: DescribeSession
    let close: (WidgetID?) -> Void

    @State private var confirmDiscard = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Screen {
        case describe, building, tryIt, saved
    }

    private var screen: Screen {
        switch session.phase {
        case .building: .building
        case .saved: .saved
        case .opening: .tryIt
        case .composing, .saving, .failed: session.draft == nil ? .describe : .tryIt
        }
    }

    private var failure: DescribeSession.Failure? {
        if case .failed(let failure) = session.phase { failure } else { nil }
    }

    var body: some View {
        ZStack {
            switch screen {
            case .describe:
                VStack(spacing: 0) {
                    topBar(.describe)
                    DescribeScreen(session: session)
                }
                .transition(.opacity)
            case .building:
                VStack(spacing: 0) {
                    topBar(.build)
                    BuildingScreen(session: session)
                }
                .transition(.opacity)
            case .tryIt:
                VStack(spacing: 0) {
                    topBar(session.phase == .saving ? .save : .tryIt)
                    TryItScreen(session: session)
                }
                .transition(.opacity)
            case .saved:
                SavedScreen(session: session) { close(savedID) }
                    .transition(.opacity)
            }
        }
        .saturation(failure == nil ? 1 : 0.75)
        .brightness(failure == nil ? 0 : -0.04)
        .overlay(alignment: .bottom) {
            if let failure {
                FailureBanner(failure: failure, keptDraft: session.draft != nil, session: session)
                    .transition(.move(edge: .bottom))
            }
        }
        .background((screen == .saved ? Palette.sky : Palette.ground).ignoresSafeArea())
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.25), value: screen)
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.35), value: failure)
        .fontDesign(.rounded)
        .foregroundStyle(Palette.ink)
        .tint(Palette.sky)
        .sensoryFeedback(trigger: session.phase) { old, new in
            switch new {
            case .saved: .success
            case .failed: .warning
            case .composing where old != .opening && session.turns.last?.result == .accepted: .success
            default: nil
            }
        }
        .task { await session.open() }
        .confirmationDialog(
            session.editing == nil ? "Discard this widget?" : "Discard your changes?",
            isPresented: $confirmDiscard, titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { close(nil) }
            Button("Keep going", role: .cancel) {}
        }
        .sheet(isPresented: formShown) {
            if let form = session.preview.form {
                FormSheet(form: form) { input in
                    session.perform(form.tap, input: input)
                    session.preview.form = nil
                }
            }
        }
        .alert(
            "Something went wrong", isPresented: .constant(session.preview.message != nil),
            actions: { Button("OK") { session.preview.message = nil } },
            message: { Text(session.preview.message ?? "") })
    }

    private var savedID: WidgetID? {
        if case .saved(let id) = session.phase { id } else { nil }
    }

    private var formShown: Binding<Bool> {
        Binding(get: { session.preview.form != nil }, set: { if !$0 { session.preview.form = nil } })
    }

    /// The close button and the step bar. Closing asks first once there is something to lose.
    private func topBar(_ step: FlowStep) -> some View {
        HStack(spacing: 12) {
            Button {
                let changed =
                    session.editing == nil ? session.draft != nil : session.turns.contains { $0.result == .accepted }
                if changed { confirmDiscard = true } else { close(nil) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(screen == .building || session.phase == .saving)
            .opacity(screen == .building ? 0.35 : 1)
            .accessibilityLabel("Discard")
            StepBar(step: step)
        }
        .padding(.leading, 8)
        .padding(.trailing, 18)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }
}

// MARK: Describe

private struct DescribeScreen: View {
    @Bindable var session: DescribeSession

    @FocusState private var typing: Bool
    @State private var item: PhotosPickerItem?

    private static let ideas: [(symbol: String, color: Color, label: String, words: String)] = [
        ("drop.fill", Palette.sky, "Water tracker with a big drop", "a water tracker with a big blue drop"),
        ("book.closed.fill", Palette.berry, "Word of the day, dark card", "a word of the day on a dark card"),
        ("figure.mind.and.body", Palette.tangerine, "Meditation streak", "a meditation streak with a calm look"),
        (
            "cup.and.saucer.fill", Color(light: 0x8A5A2B, dark: 0xC98B4E), "Coffee counter, cozy brown",
            "a coffee counter in cozy brown"
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Mascot(mood: .idle, size: 74)
                    Bubble(text: "What should your widget do?")
                }
                .padding(.bottom, 16)

                ZStack(alignment: .topLeading) {
                    if session.words.isEmpty {
                        Text("Like: a water tracker with a big blue drop")
                            .foregroundStyle(Palette.placeholder)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $session.words)
                        .focused($typing)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(Palette.ink)
                        .accessibilityLabel("Describe your widget")
                }
                .font(.title3.weight(.heavy))
                .frame(minHeight: 120)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .card()

                pictureRow.padding(.top, 19)

                Text("Need an idea?")
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 22)
                    .padding(.bottom, 8)
                    .padding(.leading, 2)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    ForEach(Self.ideas, id: \.label) { idea in
                        Button {
                            session.words = idea.words
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: idea.symbol)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(idea.color)
                                    .frame(width: 26)
                                Text(idea.label)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(
                            ChunkyButtonStyle(
                                chunk: .card, corner: 16, lip: 4, height: 64, font: .subheadline.weight(.heavy)))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button("Build it") {
                typing = false
                session.send()
            }
            .buttonStyle(ChunkyButtonStyle())
            .disabled(!session.canSend)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Palette.ground)
        }
        .onChange(of: item) { _, item in
            guard let item else { return }
            Task {
                session.picture = await Picture.load(item)
                self.item = nil
            }
        }
    }

    @ViewBuilder private var pictureRow: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if let picture = session.picture {
            HStack(spacing: 12) {
                Thumbnail(attachment: picture)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Picture added").font(.body.weight(.black))
                    Text("I'll match its look").font(.subheadline.weight(.bold)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                Button {
                    session.picture = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Remove picture")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 12)
            .card(corner: 18, lip: 4)
        } else {
            PhotosPicker(selection: $item, matching: .images) {
                HStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background {
                            ZStack {
                                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.skyLip).offset(y: 4)
                                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.sky)
                            }
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Add a picture").font(.body.weight(.black)).foregroundStyle(Palette.ink)
                        Text("I'll match its look").font(.subheadline.weight(.bold)).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .background(shape.fill(Palette.surface.opacity(0.55)))
                .overlay(shape.strokeBorder(Palette.dash, style: StrokeStyle(lineWidth: 3, dash: [7, 6])))
                .contentShape(shape)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Pip's speech bubble, with its tail pointing left at Pip.
struct Bubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.body.weight(.heavy))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(corner: 18, lip: 4)
            .overlay(alignment: .leading) {
                ZStack {
                    Tail(closed: true).fill(Palette.surface)
                    Tail(closed: false).stroke(Palette.line, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
                .frame(width: 11, height: 18)
                .offset(x: -9)
            }
    }
}

/// The bubble's tail: a wedge pointing left. Open, it is just the two outer edges, for the border.
private struct Tail: Shape {
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        if closed { path.closeSubpath() }
        return path
    }
}

// MARK: Building

private struct BuildingScreen: View {
    let session: DescribeSession

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The first step is a repair only when Save was turned down and the loop is fixing the draft for it.
    private var forSave: Bool {
        if case .repairing = session.steps.first { true } else { false }
    }

    private var title: String {
        forSave ? "Getting it ready to save" : session.draft == nil ? "Painting your widget" : "Painting your change"
    }

    /// What a build usually takes: a new widget about 40 seconds on Sonnet, a change or a fix about 15.
    private var expected: TimeInterval { session.draft == nil ? 40 : 15 }

    var body: some View {
        VStack(spacing: 0) {
            Painting()
                .frame(height: 220)
                .padding(.top, 6)
            VStack(spacing: 4) {
                Text(title).font(.title.weight(.black))
                Text("This takes about \(Int(expected)) seconds")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Palette.muted)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 0) {
                let shown = Array(session.steps.suffix(3).enumerated())
                ForEach(shown, id: \.offset) { index, step in
                    StepRow(title: step.title, done: index < shown.count - 1)
                }
                Meter(started: session.buildStarted, expected: expected)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
            .card()
            .padding(.horizontal, 18)
            .animation(reduceMotion ? nil : .spring(duration: 0.35), value: session.steps)

            Spacer(minLength: 16)
            Button("Cancel") { session.cancel() }
                .buttonStyle(ChunkyButtonStyle(chunk: .plain))
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
        }
    }

    private struct StepRow: View {
        let title: String
        let done: Bool

        var body: some View {
            HStack(spacing: 12) {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background {
                            ZStack {
                                Circle().fill(Palette.skyLip).offset(y: 3)
                                Circle().fill(Palette.sky)
                            }
                        }
                } else {
                    Spinner().frame(width: 30, height: 30)
                }
                Text(title)
                    .font(.body.weight(.heavy))
                    .foregroundStyle(done ? Palette.muted : Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityValue(done ? "Done" : "In progress")
        }
    }

    private struct Spinner: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let turns = timeline.date.timeIntervalSinceReferenceDate / 0.8
                ZStack {
                    Circle().stroke(Palette.tangerine.opacity(0.25), lineWidth: 4)
                    Circle().trim(from: 0, to: 0.72).stroke(
                        Palette.tangerine, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }
                .padding(2)
                .rotationEffect(.degrees(reduceMotion ? 0 : turns.truncatingRemainder(dividingBy: 1) * 360))
            }
        }
    }

    /// Fills toward 95% on the usual build time and never claims done; the screen leaves when the build does.
    private struct Meter: View {
        let started: Date
        let expected: TimeInterval

        var body: some View {
            TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
                let elapsed = max(0, timeline.date.timeIntervalSince(started))
                let fraction = 0.05 + 0.9 * (1 - exp(-elapsed / expected))
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.track)
                        ZStack(alignment: .top) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.skyLip)
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.sky).padding(.bottom, 5)
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.55)).frame(height: 4)
                                .padding(.horizontal, 8).padding(.top, 4)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .frame(width: max(18, box.size.width * fraction))
                        .animation(.linear(duration: 0.2), value: fraction)
                    }
                }
                .frame(height: 18)
                .accessibilityElement()
                .accessibilityLabel("Progress")
                .accessibilityValue("\(Int(fraction * 100)) percent")
            }
        }
    }
}

/// A widget outline that Pip paints in, stroke by stroke.
private struct Painting: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let sweep = 0.3 + 0.48 * (0.5 - 0.5 * cos(time * .pi / 2.4))
            ZStack(alignment: .topLeading) {
                outline(sweep: reduceMotion ? 0.6 : sweep)
                    .frame(width: 268, height: 126)
                    .offset(x: 0, y: 30)
                Mascot(mood: .working, size: 128)
                    .offset(x: 196, y: 54)
                Circle().fill(Palette.tangerine).frame(width: 10, height: 10).offset(x: 8, y: 176)
                Circle().fill(Palette.sky).frame(width: 7, height: 7).offset(x: 38, y: 190)
            }
            .frame(width: 324, height: 220, alignment: .topLeading)
        }
        .accessibilityHidden(true)
    }

    private func outline(sweep: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return ZStack(alignment: .leading) {
            shape.fill(Palette.surface.opacity(0.4))
            blocks(Palette.dash.opacity(0.6))
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [Color(rgb: 0x0D2C4A), Color(rgb: 0x16466E)], startPoint: .leading, endPoint: .trailing)
                blocks(nil)
            }
            .frame(width: 268, height: 126, alignment: .leading)
            .mask(alignment: .leading) {
                UnevenRoundedRectangle(bottomTrailingRadius: 30, topTrailingRadius: 30)
                    .frame(width: 268 * sweep)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.dash, style: StrokeStyle(lineWidth: 4, dash: [9, 7])))
    }

    /// The placeholder content: a label, a big number, a dot, and a bar chart. Painted, it takes real colors.
    private func blocks(_ flat: Color?) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(flat ?? Color(rgb: 0x7FD0FF)).frame(width: 60, height: 12)
                .offset(x: 18, y: 16)
            RoundedRectangle(cornerRadius: 8).fill(flat ?? .white).frame(width: 90, height: 26).offset(x: 18, y: 38)
            Circle().fill(flat ?? Color(rgb: 0x4FC3FF)).frame(width: 30, height: 30).offset(x: 18, y: 80)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach([0.5, 0.8, 0.6, 1.0, 0.7, 0.9], id: \.self) { height in
                    RoundedRectangle(cornerRadius: 3).fill(flat ?? Color(rgb: 0x4FC3FF)).frame(
                        width: 9, height: 60 * height)
                }
            }
            .frame(width: 96, height: 60, alignment: .bottom)
            .offset(x: 154, y: 50)
        }
        .frame(width: 268, height: 126, alignment: .topLeading)
    }
}

// MARK: Failure

private struct FailureBanner: View {
    let failure: DescribeSession.Failure
    let keptDraft: Bool
    let session: DescribeSession

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Mascot(mood: .worried, size: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title)
                        .font(.title3.weight(.black))
                        .foregroundStyle(Palette.berryText)
                    if let detail {
                        Text(detail).font(.body.weight(.bold))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Button(action: act) { Text(actionTitle) }
                .buttonStyle(ChunkyButtonStyle(chunk: .danger))
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                .fill(Palette.berryTint)
                .overlay(alignment: .top) {
                    UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                        .stroke(Palette.berry.opacity(0.35), lineWidth: 4)
                }
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .topTrailing) {
            if failure != .unavailable {
                Button(action: session.dismissFailure) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Palette.berryText.opacity(0.8))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close")
                .padding(.top, 4)
                .padding(.trailing, 6)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var detail: String? {
        let safe = keptDraft ? "Your last widget is safe." : nil
        return [failure.detail, safe].compactMap(\.self).joined(separator: " ").nilIfEmpty
    }

    private var actionTitle: String {
        switch failure {
        case .gaveUp: "Say it another way"
        case .unavailable: "OK"
        case .unreachable, .interrupted, .broken: "Try again"
        }
    }

    private func act() {
        switch failure {
        case .gaveUp, .unavailable: session.dismissFailure()
        case .unreachable, .interrupted, .broken: session.retry()
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
