import PhotosUI
import SwiftUI
import WidgetBuilder
import WidgetEngine

/// The draft to try: live faces in both sizes, the data picker, what was asked so far, and the composer that
/// asks for the next change. Everything lines up on the medium face's width.
struct TryItScreen: View {
    @Bindable var session: DescribeSession

    @FocusState private var typing: Bool
    @State private var item: PhotosPickerItem?

    private static let column = Family.medium.standardSize.width
    private static let suggestions: [(symbol: String, words: String)] = [
        ("paintpalette.fill", "Make it blue"), ("textformat.size", "Bigger number"),
        ("chart.bar.fill", "Add a weekly chart"), ("sparkles", "Make it nicer"), ("moon.fill", "Darker look"),
    ]

    private var preview: Preview { session.preview }
    private var composing: Bool { session.phase == .composing }
    private var failed: Bool {
        if case .failed = session.phase { true } else { false }
    }

    var body: some View {
        GeometryReader { screen in
            let margin = max(16, (screen.size.width - Self.column) / 2)
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        faces.padding(.top, 12)
                        transcript.padding(.top, 20)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(width: Self.column)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottom(margin: margin)
                }
                // Building replaces this screen, so it comes back fresh after each turn: show the newest turn.
                .onAppear { scroller.scrollTo("end", anchor: .bottom) }
            }
        }
        .onChange(of: item) { _, item in
            guard let item else { return }
            Task {
                session.picture = await Picture.load(item)
                self.item = nil
            }
        }
        .onChange(of: session.words) { _, words in
            // The field grows to four lines, so return sends instead of starting a new line.
            guard words.contains("\n") else { return }
            session.words = words.replacingOccurrences(of: "\n", with: "")
            send()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Try it out!")
                .font(.title.weight(.black))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            if failed {
                Label("Last working version", systemImage: "checkmark.seal.fill")
                    .font(.footnote.weight(.black))
                    .foregroundStyle(Palette.skyText)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .card(corner: 10, lip: 3)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.top, 4)
    }

    private var faces: some View {
        VStack(alignment: .leading, spacing: 14) {
            face(.medium)
                .overlay(alignment: .topTrailing) {
                    if !session.tried, preview.faces[.medium] != nil, composing {
                        Text("Give it a tap")
                            .font(.footnote.weight(.black))
                            .foregroundStyle(Color(rgb: 0x14204A))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.sunLip)
                                        .offset(y: 3)
                                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.sun)
                                }
                            }
                            .offset(x: 6, y: -14)
                            .allowsHitTesting(false)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            HStack(alignment: .top, spacing: 14) {
                face(.small)
                VStack(spacing: 5) {
                    ForEach(preview.states, id: \.self) { state in
                        Button {
                            Task { await preview.select(state) }
                        } label: {
                            Text(label(state))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(
                            ChunkyButtonStyle(
                                chunk: preview.state == state ? .picked : .card, corner: 14, lip: 4, height: 40,
                                font: .subheadline.weight(.heavy))
                        )
                        .accessibilityAddTraits(preview.state == state ? .isSelected : [])
                    }
                }
                .disabled(!composing)
            }
        }
        .animation(.spring(duration: 0.3), value: session.tried)
    }

    @ViewBuilder private func face(_ family: Family) -> some View {
        let size = family.standardSize
        if let face = preview.faces[family] {
            FaceView(face, host: .app(tap: { session.perform($0) }, form: { preview.showForm(for: $0) }))
                .frame(width: size.width, height: size.height)
                .shadow(color: Palette.line, radius: 0, y: 5)
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Palette.dash, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                .frame(width: size.width, height: size.height)
                .overlay { ProgressView().tint(Palette.muted) }
        }
    }

    @ViewBuilder private var transcript: some View {
        if session.turns.isEmpty {
            HStack(spacing: 10) {
                Mascot(mood: .idle, size: 56)
                Bubble(text: "What should I change?")
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(session.turns.enumerated()), id: \.element.id) { index, turn in
                    TurnRow(turn: turn, first: index == 0 && session.editing == nil)
                        .overlay(alignment: .top) {
                            if index > 0 { Palette.divider.frame(height: 2) }
                        }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .card(corner: 18, lip: 4)
        }
    }

    private func bottom(margin: CGFloat) -> some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.words) { suggestion in
                        Button {
                            typing = false
                            session.send(suggestion.words)
                        } label: {
                            Label(suggestion.words, systemImage: suggestion.symbol)
                                .labelStyle(SuggestionLabel())
                                .lineLimit(1)
                        }
                        .buttonStyle(
                            ChunkyButtonStyle(
                                chunk: .card, corner: 13, lip: 3, height: 40, wide: false,
                                font: .subheadline.weight(.heavy)))
                    }
                }
            }
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .scrollClipDisabled()
            .disabled(!composing)

            VStack(spacing: 10) {
                if let picture = session.picture {
                    HStack(spacing: 10) {
                        Thumbnail(attachment: picture, size: 40)
                        Text("I'll match this picture")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(Palette.muted)
                        Spacer(minLength: 0)
                        Button {
                            session.picture = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundStyle(Palette.muted)
                                .frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Remove picture")
                    }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    PhotosPicker(selection: $item, matching: .images) {
                        Image(systemName: "photo").font(.system(size: 19, weight: .bold))
                    }
                    .buttonStyle(
                        ChunkyButtonStyle(
                            chunk: Chunk(
                                face: Palette.surface, lip: Palette.line, text: Palette.sky, border: Palette.line),
                            corner: 15, lip: 4, height: 48, wide: false)
                    )
                    .frame(width: 48)
                    .accessibilityLabel("Add a picture")

                    TextField("Change something", text: $session.words, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.body.weight(.bold))
                        .focused($typing)
                        .submitLabel(.send)
                        .accessibilityLabel("Change something")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(minHeight: 48)
                        .background {
                            RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Palette.surface)
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(typing ? Palette.sky : Palette.line, lineWidth: 2)
                        }
                        .padding(.bottom, 4)

                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 19, weight: .black))
                    }
                    .buttonStyle(ChunkyButtonStyle(chunk: .sky, corner: 15, lip: 4, height: 48, wide: false))
                    .frame(width: 48)
                    .disabled(!session.canSend)
                    .accessibilityLabel("Send")
                }
                .disabled(!composing)

                if !typing {
                    Button(session.editing == nil ? "Save widget" : "Save changes") { session.save() }
                        .buttonStyle(ChunkyButtonStyle())
                        .disabled(session.draft == nil || !composing)
                        .padding(.top, 4)
                }
            }
            .frame(width: Self.column)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Palette.ground)
    }

    private func send() {
        typing = false
        session.send()
    }

    private func label(_ state: DataState) -> String {
        switch state {
        case .empty: "Empty"
        case .sample(let name): name.prefix(1).uppercased() + name.dropFirst()
        case .full: "Full"
        case .file(let url): url.lastPathComponent
        }
    }
}

private struct SuggestionLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(Palette.tangerine)
            configuration.title
        }
    }
}

/// One turn: what the person asked, and what came of it.
private struct TurnRow: View {
    let turn: DescribeSession.Turn
    /// The turn that made the widget, as opposed to one that changed it.
    let first: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            mark
            if let image = turn.image {
                Thumbnail(attachment: image, size: 28)
            }
            Text(turn.words)
                .font(.subheadline.weight(.heavy))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(result)
                .font(.footnote.weight(.bold))
                .foregroundStyle(failed ? Palette.berryText : Palette.muted)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var failed: Bool {
        if case .failed = turn.result { true } else { false }
    }

    private var result: String {
        switch turn.result {
        case .pending: "Working"
        case .accepted: first ? "Built" : "Done"
        case .failed: "Didn't work"
        case .cancelled: "Cancelled"
        }
    }

    private var mark: some View {
        let (symbol, fill): (String, Color) =
            switch turn.result {
            case .pending: ("ellipsis", Palette.tangerine)
            case .accepted: ("checkmark", Palette.sky)
            case .failed: ("exclamationmark", Palette.berry)
            case .cancelled: ("xmark", Palette.off)
            }
        return Image(systemName: symbol)
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
    }
}
