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
    let added: (WidgetID) -> Void
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
        // Added lands in Widgets, so the sheet stays until it does.
        .interactiveDismissDisabled(adding)
        // At the accessibility text sizes the content is taller than the screen, so the sheet opens full height
        // and scrolls.
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(height)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(36)
        .presentationBackground {
            LinearGradient(colors: [Palette.sheetTop, Palette.sheetBottom], startPoint: .top, endPoint: .bottom)
        }
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
        .sheet(item: Bindable(preview).form) { shown in
            FormSheet(form: shown.form) { input in
                preview.perform(shown.form.tap, input: input)
                preview.form = nil
            }
        }
        .alert(
            "Something went wrong", isPresented: .constant(message != nil || preview.message != nil),
            actions: {
                Button("OK") {
                    message = nil
                    preview.message = nil
                }
            },
            message: { Text(message ?? preview.message ?? "") })
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
        let added: (WidgetID) -> Void
        let chat: (WidgetSource, String) -> Void

        @FocusState private var typing: String?
        @Environment(\.dynamicTypeSize) private var typeSize

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
            Group {
                if let face = preview.faces[template.family] {
                    FaceView(face, host: .app(tap: { trial.tap($0) }, form: { trial.showForm(for: $0) }))
                } else {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.disabled.opacity(0.4))
                }
            }
            .frame(width: size.width, height: size.height)
            .faceShadow()
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
            .sensoryFeedback(.success, trigger: adding) { was, now in was && !now && message == nil }
        }

        private func add() {
            guard let choice = attempt({ try trial.choice() }) else { return }
            typing = nil
            adding = true
            Task {
                switch await library.add(choice.source) {
                case .success(let id):
                    added(id)
                case .failure(let unsaved):
                    message = unsaved.line
                }
                adding = false
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

/// Widgie's speech bubble, with its tail pointing down to Widgie below it or left to Widgie beside it. It pops
/// in with each new line and is read out by VoiceOver. Empty until Widgie first speaks.
struct Bubble: View {
    enum Tail {
        case down, left
    }

    let words: String?
    let tail: Tail

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let words {
                Text(words)
                    .font(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .tracking(-0.15)
                    .lineSpacing(2)
                    .multilineTextAlignment(tail == .down ? .center : .leading)
                    .foregroundStyle(Color(red: 0x12 / 255, green: 0x1A / 255, blue: 0x2E / 255))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Palette.bubble)
                            .overlay(alignment: tail == .down ? .bottom : .topLeading) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Palette.bubble)
                                    .frame(width: 13, height: 13)
                                    .rotationEffect(.degrees(45))
                                    .offset(x: tail == .down ? 0 : -5, y: tail == .down ? 5 : 11)
                            }
                            .shadow(color: Palette.restShadow.opacity(0.5), radius: 2, y: 2)
                            .shadow(color: Palette.restShadow, radius: 12, y: 10)
                    }
                    .id(words)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.6, anchor: tail == .down ? .bottom : .leading).combined(with: .opacity)
                    )
                    .onAppear { AccessibilityNotification.Announcement(words).post() }
            }
        }
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(duration: 0.45, bounce: 0.45), value: words)
    }
}
