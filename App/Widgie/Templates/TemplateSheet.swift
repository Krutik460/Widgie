import SwiftUI
import WidgetBuilder
import WidgetEngine

/// A template up close: its name and line, its face live on scratch data with Widgie beside it, a field for
/// each blank, Change in chat, and Add widget. It opens at `height`, which the presenter measures from `Content`
/// before opening it, because a sheet keeps the detent it opened with.
struct TemplateSheet: View {
    let trial: TemplateTrial
    let library: Library
    let height: CGFloat
    /// Added to the library: the new widget, and its tile leaving the sheet for the Widgets tab.
    let added: (WidgetID, Launch) -> Void
    let chat: (WidgetSource, String) -> Void

    @State private var message: String?
    @State private var adding = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var preview: Preview { trial.preview }

    var body: some View {
        ScrollView {
            Content(trial: trial, library: library, message: $message, adding: $adding, added: added, chat: chat)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .topTrailing) {
            SoftCloseButton { dismiss() }
                .disabled(adding)
                .padding(.top, 24)
                .padding(.trailing, 14)
        }
        .foregroundStyle(Palette.text)
        // The sheet stays until the new widget is in the library and its tile flies.
        .interactiveDismissDisabled(adding)
        // At the accessibility text sizes the content is taller than the screen, so the sheet opens full height
        // and scrolls.
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(height)])
        .sheetStyle()
        .task {
            await trial.fill()
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(440)) }
            trial.greet()
        }
        .task(id: trial.values) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await trial.fill()
        }
        .previewForms(preview)
        .failureAlert(
            Binding(
                get: { message ?? preview.message },
                set: {
                    message = $0
                    preview.message = $0
                }))
    }

    /// The face's sizes in the sheet: a small face a little bigger than in the pile, and a wide one the width of
    /// the sheet's column.
    static func sizes(width: CGFloat) -> FaceSizes {
        let side = min(184, ((width - 44) * 0.52).rounded(.down))
        return FaceSizes(
            small: CGSize(width: side, height: side), medium: FaceSizes(column: width - 44).medium)
    }

    /// What the sheet holds. Its bottom padding and the home indicator's inset under it make the prototype's
    /// 40 points below the keys.
    struct Content: View {
        let trial: TemplateTrial
        let library: Library
        @Binding var message: String?
        @Binding var adding: Bool
        let added: (WidgetID, Launch) -> Void
        let chat: (WidgetSource, String) -> Void

        @FocusState private var typing: String?
        /// The face's frame in the window, where its flight to the Widgets tab starts.
        @State private var tile = CGRect.zero
        @State private var leaving: Leaving?
        @Environment(Flights.self) private var flights
        @Environment(\.dynamicTypeSize) private var typeSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        /// An added widget on its way out: confetti bursts from the tile and Widgie hops, then the tile flies.
        private enum Leaving {
            case cheering, flying
        }

        private var template: Template { trial.template }
        private var preview: Preview { trial.preview }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                heading
                spot.padding(.top, 12)
                ForEach(template.blanks) { blank in
                    field(blank).padding(.top, 10)
                }
                keys.padding(.top, 16)
            }
            .padding(.horizontal, 22)
            .padding(.top, 30)
            .padding(.bottom, 6)
        }

        private var heading: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(template.name)
                    .display(size: 34)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(template.line + ".")
                    .font(size: 15, weight: .medium, relativeTo: .subheadline)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 48)
        }

        /// The face on a soft spotlight with Widgie: beside a small face, talking from above it, or perched on a wide
        /// one's top edge, talking to its right.
        @ViewBuilder private var spot: some View {
            let size = preview.sizes[template.family]
            Group {
                // At the accessibility text sizes the bubble needs a row's width, so Widgie perches on top of a small
                // face too.
                if template.family == .small && !typeSize.isAccessibilitySize {
                    HStack(alignment: .bottom, spacing: -6) {
                        face(size)
                        VStack(spacing: 0) {
                            // Widgie leans on the face, but its words stay clear of it.
                            bubble(.down)
                                .padding(.leading, 6)
                                .padding(.bottom, -6)
                                .zIndex(1)
                            widgie(.left, size: 124)
                        }
                        .frame(width: 140)
                    }
                    .padding(.trailing, 4)
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: -10) {
                            widgie(.right, size: 118)
                                .padding(.leading, 16)
                            // Widgie perches on the face, but its words end above it however many lines they take.
                            bubble(.left)
                                .padding(.top, 4)
                                .padding(.bottom, 10)
                                .zIndex(1)
                        }
                        .padding(.bottom, -10)
                        .zIndex(1)
                        face(size)
                    }
                }
            }
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, minHeight: template.family == .small ? 218 : 272, alignment: .bottom)
            .background(alignment: .bottom) {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [Palette.spotGlow, .clear], center: .center, startRadius: 0, endRadius: 150)
                    )
                    .frame(width: 300, height: 210)
                    .offset(y: 105)
                    .allowsHitTesting(false)
            }
        }

        /// The live face: taps write to scratch rows, which Widgie calls practice.
        @ViewBuilder private func face(_ size: CGSize) -> some View {
            FaceTile(
                face: preview.faces[template.family], size: size,
                host: .app(tap: { trial.tap($0) }, form: { trial.showForm(for: $0) })
            )
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                tile = $0
            }
            // The flight draws the tile from here on, and with Reduce Motion it only dims as the sheet closes.
            .opacity(leaving == .flying ? (reduceMotion ? 0.4 : 0) : 1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(template.name), to try")
        }

        private func widgie(_ side: Caret.Side, size: CGFloat) -> some View {
            HoppingCaret(pose: .lean(side), size: size, cue: trial.reactions)
        }

        private func bubble(_ tail: Bubble.Tail) -> some View {
            Bubble(words: trial.said, tail: tail)
                .frame(maxWidth: tail == .down ? nil : 210, alignment: tail == .down ? .center : .leading)
        }

        private func field(_ blank: Template.Blank) -> some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(blank.label)
                        .font(size: 12.5, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(Palette.secondary)
                        .accessibilityHidden(true)
                    TextField(
                        blank.label,
                        text: Binding(get: { trial.values[blank.key] ?? "" }, set: { trial.values[blank.key] = $0 }),
                        prompt: Text(blank.placeholder).foregroundStyle(Palette.secondary)
                    )
                    .font(size: 17, weight: .semibold)
                    .accessibilityLabel(blank.label)
                    // Cut after the keystroke lands rather than in the binding, because a field whose binding
                    // refuses a character keeps showing it.
                    .onChange(of: trial.values[blank.key]) { _, typed in
                        guard let typed, typed.utf16.count > blank.maxLength else { return }
                        trial.values[blank.key] = blank.clamped(typed)
                    }
                    .focused($typing, equals: blank.key)
                    .submitLabel(.done)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                }
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 60)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.fieldFill).restShadow())
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture { typing = blank.key }
        }

        private var keys: some View {
            ViewThatFits(in: .horizontal) {
                // Side by side, both keys take the height of the taller one when a label wraps.
                HStack(spacing: 10) {
                    chatKey
                    addKey
                }
                .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    addKey
                    chatKey
                }
            }
        }

        private var chatKey: some View {
            Button {
                guard let choice = attempt({ try trial.choice() }) else { return }
                chat(choice.source, choice.name)
            } label: {
                Text("Change in chat").frame(maxHeight: .infinity)
            }
            .buttonStyle(KeyButtonStyle(prominent: false))
            .disabled(adding)
        }

        private var addKey: some View {
            Button {
                add()
            } label: {
                Group {
                    if adding {
                        ProgressView().tint(Palette.keyLabel).accessibilityLabel("Adding")
                    } else {
                        Text("Add widget")
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(KeyButtonStyle())
            .disabled(adding)
            .sensoryFeedback(.success, trigger: leaving) { was, now in was == nil && now != nil }
        }

        /// Builds the filled template into the library. Then confetti bursts from the tile and Widgie hops, and
        /// 200 ms later the tile flies to the Widgets tab as the sheet closes.
        private func add() {
            guard let choice = attempt({ try trial.choice() }) else { return }
            typing = nil
            adding = true
            Task {
                switch await library.add(choice.source) {
                case .success(let id):
                    leaving = .cheering
                    if !reduceMotion {
                        flights.burst(from: tile)
                        trial.cheer()
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    leaving = .flying
                    added(id, Launch(name: choice.name, face: preview.faces[template.family], from: tile))
                case .failure(let unsaved):
                    message = unsaved.line
                    adding = false
                }
            }
        }

        private func attempt<T>(_ work: () throws -> T) -> T? {
            do {
                return try work()
            } catch {
                message = "This template could not be filled in."
                return nil
            }
        }
    }
}

/// Widgie's speech bubble, with its tail pointing down to Widgie below it or to Widgie beside it. It pops in with
/// each new line, which VoiceOver reads out as `voice` says. Empty until Widgie first speaks.
struct Bubble: View {
    enum Tail {
        case down, left, right
    }

    /// How VoiceOver reads a new line: not at all, as on a page that is not showing, after what it is saying, as
    /// for a greeting, or as a reply to what the person just did.
    enum Voice {
        case silent, low, normal
    }

    let words: String?
    let tail: Tail
    var voice = Voice.normal

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let words {
                Text(words)
                    .font(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .tracking(-0.15)
                    .lineSpacing(2)
                    .multilineTextAlignment(tail == .down ? .center : .leading)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Palette.bubble)
                            .overlay(alignment: tailCorner) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Palette.bubble)
                                    .frame(width: 13, height: 13)
                                    .rotationEffect(.degrees(45))
                                    .offset(x: tailOffset.width, y: tailOffset.height)
                            }
                            .bubbleShadow()
                    }
                    .id(words)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.6, anchor: growsFrom).combined(with: .opacity)
                    )
            }
        }
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(duration: 0.45, bounce: 0.45), value: words)
        .announces(words, voice: voice)
    }

    private var tailCorner: Alignment {
        switch tail {
        case .down: .bottom
        case .left: .topLeading
        case .right: .topTrailing
        }
    }

    private var tailOffset: CGSize {
        switch tail {
        case .down: CGSize(width: 0, height: 5)
        case .left: CGSize(width: -5, height: 11)
        case .right: CGSize(width: 5, height: 11)
        }
    }

    private var growsFrom: UnitPoint {
        switch tail {
        case .down: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}
