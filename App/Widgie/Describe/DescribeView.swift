import PhotosUI
import SwiftUI
import WidgetBuilder
import WidgetEngine

/// The describe flow, one action per screen: describe, watch it build, try it, saved. A failure drains the
/// screen to grey. `close` gets the saved widget, or nil when nothing was saved.
struct DescribeView: View {
    @Bindable var session: DescribeSession
    let close: (WidgetID?) -> Void

    @State private var confirmDiscard = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Screen {
        case describe, building, tryIt, saved, failure
    }

    private var screen: Screen {
        switch session.phase {
        case .building: .building
        case .saved: .saved
        case .failed: .failure
        case .opening: .tryIt
        case .composing, .saving: session.draft == nil ? .describe : .tryIt
        }
    }

    var body: some View {
        ZStack {
            switch screen {
            case .describe:
                DescribeScreen(session: session, close: attemptClose).transition(.opacity)
            case .building:
                BuildingScreen(session: session).transition(.opacity)
            case .tryIt:
                TryItScreen(session: session, close: attemptClose).transition(.opacity)
            case .saved:
                SavedScreen(session: session) { close(savedID) }.transition(.opacity)
            case .failure:
                if case .failed(let failure) = session.phase {
                    FailureScreen(failure: failure, session: session) { close(nil) }.transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ground(screen == .failure ? Palette.failureGround : Palette.ground)
        .animation(reduceMotion ? .linear(duration: 0.2) : .easeInOut(duration: 0.5), value: screen)
        .foregroundStyle(Palette.text)
        .tint(Palette.caret)
        .sensoryFeedback(trigger: session.phase) { _, new in
            switch new {
            case .saved: .success
            case .failed: .warning
            default: nil
            }
        }
        .sensoryFeedback(.success, trigger: session.turns.last?.result) { _, new in new == .accepted }
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

    /// Closes, asking first once there is something to lose. Not while saving, because the save would still
    /// land after a discard.
    private func attemptClose() {
        guard session.phase != .saving else { return }
        let changed = session.editing == nil ? session.draft != nil : session.turns.contains { $0.result == .accepted }
        if changed { confirmDiscard = true } else { close(nil) }
    }
}

// MARK: Describe

/// One big field with the caret as its cursor, three example chips, a photo button, and Build it.
private struct DescribeScreen: View {
    @Bindable var session: DescribeSession
    let close: () -> Void

    @FocusState private var typing: Bool

    private static let examples: [(label: String, words: String, color: ChipColor)] = [
        ("Water tracker", "a water tracker with a big blue drop", .mint),
        ("Word of the day", "a word of the day on a dark card", .butter),
        ("To-do list", "a to-do list for today", .pink),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CloseButton(action: close)
                .padding(.leading, Column.margin - 13)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: -16) {
                        Caret(
                            pose: typing || !session.words.isEmpty ? .lean(.right) : .idle, size: 74, grounded: false
                        )
                        .padding(.leading, -24)
                        .padding(.top, -12)
                        TextField(
                            "Describe a widget", text: $session.words,
                            prompt: Text("Describe a widget").foregroundStyle(Palette.secondary), axis: .vertical
                        )
                        .font(size: 34, weight: .bold, relativeTo: .largeTitle)
                        .tracking(-1)
                        .foregroundStyle(Palette.text)
                        .focused($typing)
                        .submitLabel(.go)
                        .accessibilityLabel("Describe a widget")
                        .padding(.top, 4)
                    }
                    FlowLayout(spacing: 10) {
                        ForEach(Self.examples, id: \.label) { example in
                            Button(example.label) {
                                session.words = example.words
                                typing = true
                            }
                            .buttonStyle(ChipButtonStyle(color: example.color))
                        }
                    }
                    .padding(.top, 30)
                }
                .padding(.top, 22)
                .frame(width: Column.width, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    PhotoButton(picture: $session.picture)
                    Button("Build it") {
                        typing = false
                        session.send()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!session.canSend)
                }
                .frame(width: Column.width)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { typing = true }
        .onChange(of: session.words) { _, words in
            // The field wraps long descriptions, so return builds instead of starting a new line.
            guard words.contains("\n") else { return }
            session.words = words.replacingOccurrences(of: "\n", with: "")
            guard session.canSend else { return }
            typing = false
            session.send()
        }
    }
}

/// The photo button: the outlined picture icon, or the attached photo with a button to remove it.
struct PhotoButton: View {
    @Binding var picture: Picture?

    @State private var item: PhotosPickerItem?
    @State private var unreadable = false

    var body: some View {
        Group {
            if let picture {
                Thumbnail(picture: picture, size: 60)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            self.picture = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Palette.buttonLabel)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Palette.buttonFill))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .offset(x: 14, y: -14)
                        .accessibilityLabel("Remove picture")
                    }
            } else {
                PhotosPicker(selection: $item, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .frame(width: 60, height: 60)
                        .overlay(Outline())
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Add a picture")
            }
        }
        .onChange(of: item) { _, item in
            guard let item else { return }
            Task {
                picture = await Picture.load(item)
                unreadable = picture == nil
                self.item = nil
            }
        }
        .alert("That photo didn't load.", isPresented: $unreadable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try another one.")
        }
    }
}

/// Lays its children in rows, left to right, wrapping when the next one does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, subview) in zip(place(subviews, width: bounds.width), subviews) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + rowHeight + spacing)
                rowHeight = 0
            }
            frames.append(CGRect(origin: origin, size: CGSize(width: min(size.width, width), height: size.height)))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

// MARK: Building

/// The caret drawing the widget's outline, and one status line that follows the build's steps.
private struct BuildingScreen: View {
    let session: DescribeSession

    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What a build usually takes: a new widget about 40 seconds on Sonnet, a change or a fix about 15.
    private var expected: TimeInterval { session.draft == nil ? 40 : 15 }

    private var status: String {
        if case .building(let step) = session.phase { step.title } else { "" }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                let elapsed = max(0, timeline.date.timeIntervalSince(session.buildStarted))
                Sketch(progress: reduceMotion ? 0.62 : 0.06 + 0.9 * (1 - exp(-elapsed / expected)))
            }
            Text(status)
                .font(size: 21, weight: .bold, relativeTo: .title3)
                .tracking(-0.4)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: status)
                .padding(.top, 46)
                .padding(.horizontal, Column.margin)
                .accessibilityAddTraits(.updatesFrequently)
                .onChange(of: status, initial: true) { _, status in
                    guard !status.isEmpty else { return }
                    AccessibilityNotification.Announcement(status).post()
                }
            Spacer(minLength: 0)
            Spacer(minLength: 0)
            Button("Cancel") { session.cancel() }
                .font(size: 17, weight: .semibold)
                .foregroundStyle(Palette.secondary)
                .frame(minWidth: 120, minHeight: 44)
                .contentShape(Rectangle())
                .padding(.bottom, 14)
                // Cancel sits where Build it was, so the second tap of a double tap would land on it.
                .allowsHitTesting(settled)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            settled = true
        }
    }
}

/// A widget's outline drawn so far, its parts going from dashed to solid, with the caret riding the end of
/// the line.
private struct Sketch: View {
    let progress: Double

    private static let size = Family.medium.standardSize
    private static let headroom: CGFloat = 150
    private static let caret: CGFloat = 170

    var body: some View {
        let size = Self.size
        let outline = Self.outline
        let tip = outline.trimmedPath(from: 0, to: progress).currentPoint ?? .zero
        let side: Caret.Side = tip.x < size.width * 0.7 ? .right : .left
        let foot = Caret.foot(.draw(side))
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                outline.stroke(
                    Palette.caret.opacity(0.18), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 8]))
                outline.trimmedPath(from: 0, to: progress).stroke(
                    Palette.caret, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                parts
            }
            .frame(width: size.width, height: size.height)
            .offset(y: Self.headroom)
            Caret(pose: .draw(side), size: Self.caret, grounded: false)
                .position(
                    x: tip.x + Self.caret * (0.5 - foot.x), y: Self.headroom + tip.y + Self.caret * (0.5 - foot.y))
        }
        .frame(width: size.width, height: size.height + Self.headroom, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// The widget's edge, drawn clockwise from the bottom of the left side, so the caret spends most of a build
    /// on the top edge, above the parts it reveals.
    private static let outline: Path = {
        let (width, height, radius) = (size.width, size.height, 22.0)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: height - radius))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addArc(tangent1End: .zero, tangent2End: CGPoint(x: radius, y: 0), radius: radius)
        path.addLine(to: CGPoint(x: width - radius, y: 0))
        path.addArc(tangent1End: CGPoint(x: width, y: 0), tangent2End: CGPoint(x: width, y: radius), radius: radius)
        path.addLine(to: CGPoint(x: width, y: height - radius))
        path.addArc(
            tangent1End: CGPoint(x: width, y: height), tangent2End: CGPoint(x: width - radius, y: height),
            radius: radius)
        path.addLine(to: CGPoint(x: radius, y: height))
        path.addArc(
            tangent1End: CGPoint(x: 0, y: height), tangent2End: CGPoint(x: 0, y: height - radius), radius: radius)
        return path
    }()

    /// A label, a big number, two buttons, and a week of bars, each solid once the line has passed above it.
    private var parts: some View {
        let bars: [CGFloat] = [30, 54, 40, 66, 48, 72, 22]
        return ZStack(alignment: .topLeading) {
            part(RoundedRectangle(cornerRadius: 4), at: 0.19).frame(width: 58, height: 12).offset(x: 20, y: 22)
            part(RoundedRectangle(cornerRadius: 6), at: 0.23).frame(width: 84, height: 34).offset(x: 20, y: 52)
            part(Circle(), at: 0.16).frame(width: 30, height: 30).offset(x: 23, y: 110)
            part(Circle(), at: 0.7).frame(width: 22, height: 22).offset(x: 69, y: 114)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
                    part(RoundedRectangle(cornerRadius: 4), at: 0.32 + Double(index) * 0.022)
                        .frame(width: 12, height: height)
                }
            }
            .frame(height: 72, alignment: .bottom)
            .offset(x: 186, y: 62)
        }
    }

    @ViewBuilder private func part(_ shape: some Shape, at threshold: Double) -> some View {
        if progress >= threshold {
            shape.fill(Palette.caret)
        } else {
            shape.stroke(Palette.caret.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
        }
    }
}

// MARK: Failure

/// The screen drained to grey, the caret slumped at a broken bridge, what went wrong in one line, the last
/// widget that worked, and one way forward.
private struct FailureScreen: View {
    let failure: DescribeSession.Failure
    let session: DescribeSession
    let close: () -> Void

    /// Back would land on nothing new: there is no build to go back to, or no widget to refine.
    private var hidesBack: Bool { failure == .unavailable || failure == .unopened }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CloseButton(color: Palette.failureText, label: "Back") { session.dismissFailure() }
                    .opacity(hidesBack ? 0 : 1)
                    .disabled(hidesBack)
                    .accessibilityHidden(hidesBack)
                Spacer()
            }
            .padding(.leading, Column.margin - 13)
            ScrollView {
                VStack(spacing: 0) {
                    BrokenBridge().padding(.top, 34)
                    Text(failure.title)
                        .font(size: 30, weight: .heavy, relativeTo: .title)
                        .tracking(-1)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Palette.failureText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 22)
                    #if DEBUG
                        if failure == .unreachable {
                            Text("Check that the bridge is running.")
                                .font(size: 16, weight: .semibold)
                                .foregroundStyle(Palette.failureText.opacity(0.75))
                                .padding(.top, 8)
                        }
                    #endif
                    if let face = session.preview.faces[.medium] {
                        FaceView(face, host: .app(tap: { _ in }, form: { _ in }))
                            .allowsHitTesting(false)
                            .frame(width: Family.medium.standardSize.width, height: Family.medium.standardSize.height)
                            .faceShadow()
                            .padding(.top, 34)
                            .accessibilityLabel("Your last widget, kept as it was")
                    }
                }
                .frame(width: Column.width)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            Button(actionTitle, action: act)
                .buttonStyle(PrimaryButtonStyle(fill: Palette.failureButtonFill, label: Palette.failureButtonLabel))
                .frame(width: Column.width)
                .padding(.bottom, 8)
        }
    }

    private var actionTitle: String {
        switch failure {
        case .gaveUp: "Say it another way"
        case .unsaved, .unavailable: "OK"
        case .unopened: "Close"
        case .unreachable, .refused, .interrupted, .broken: "Try again"
        }
    }

    private func act() {
        switch failure {
        case .gaveUp, .unsaved, .unavailable: session.dismissFailure()
        case .unopened: close()
        case .unreachable, .refused, .interrupted, .broken: session.retry()
        }
    }
}

/// A bridge with a gap in it, and the caret bent over the gap.
private struct BrokenBridge: View {
    var body: some View {
        let width = Column.width
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
