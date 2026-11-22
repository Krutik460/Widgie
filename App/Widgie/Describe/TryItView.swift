import SwiftUI
import WidgetBuilder
import WidgetEngine

/// The draft to try: live faces in both sizes, a compact sample menu, the latest exchange, two suggestions,
/// and the composer that asks for the next change. Save sits at the top right.
struct TryItScreen: View {
    @Bindable var session: DescribeSession
    let close: () -> Void

    @FocusState private var typing: Bool

    private static let suggestions: [(words: String, color: ChipColor)] = [
        ("Make it blue", .lilac), ("Bigger number", .peach),
    ]

    private var preview: Preview { session.preview }
    private var composing: Bool { session.phase == .composing }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    faces.padding(.top, 14)
                    exchange
                    FlowLayout(spacing: 8) {
                        ForEach(Self.suggestions, id: \.words) { suggestion in
                            Button(suggestion.words) {
                                typing = false
                                session.send(suggestion.words)
                            }
                            .buttonStyle(ChipButtonStyle(color: suggestion.color))
                        }
                    }
                    .disabled(!composing)
                    .padding(.top, 20)
                }
                .frame(width: Column.width, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
        .onChange(of: session.words) { _, words in
            // The field grows to four lines, so return sends instead of starting a new line.
            guard words.contains("\n") else { return }
            session.words = words.replacingOccurrences(of: "\n", with: "")
            send()
        }
    }

    private var topBar: some View {
        HStack {
            CloseButton(action: close)
                .disabled(session.phase == .saving)
            Spacer()
            Button {
                typing = false
                session.save()
            } label: {
                if session.phase == .saving {
                    ProgressView().tint(Palette.buttonLabel).accessibilityLabel("Saving")
                } else {
                    Text("Save")
                }
            }
            .buttonStyle(CompactButtonStyle())
            .disabled(session.draft == nil || !(composing || session.phase == .saving))
        }
        .padding(.leading, Column.margin - 13)
        .padding(.trailing, Column.margin - 4)
        .frame(minHeight: 48)
    }

    private var faces: some View {
        VStack(alignment: .leading, spacing: 20) {
            face(.medium)
            HStack(alignment: .top, spacing: 0) {
                face(.small)
                VStack(alignment: .leading, spacing: 0) {
                    samples
                    Caret(pose: .lean(.left), size: 118)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                .padding(.leading, 22)
            }
        }
    }

    @ViewBuilder private func face(_ family: Family) -> some View {
        let size = family.standardSize
        if let face = preview.faces[family] {
            FaceView(face, host: .app(tap: { session.perform($0) }, form: { preview.showForm(for: $0) }))
                .frame(width: size.width, height: size.height)
                .faceShadow()
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Palette.caret.opacity(0.18), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 8]))
                .frame(width: size.width, height: size.height)
                .overlay { ProgressView().tint(Palette.secondary) }
        }
    }

    /// The data the faces show: empty, then each sample, in one compact menu.
    private var samples: some View {
        Menu {
            Picker(
                "Try it with",
                selection: Binding(get: { preview.state }, set: { state in Task { await preview.select(state) } })
            ) {
                ForEach(preview.states, id: \.self) { Text(label($0)).tag($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label(preview.state)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
            }
            .font(size: 15, weight: .semibold)
            .foregroundStyle(Palette.text)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(minHeight: 36)
            .overlay(Outline(corner: 10))
            .contentShape(Rectangle())
        }
        .disabled(!composing || preview.states.isEmpty)
        .accessibilityLabel("Try it with")
        .accessibilityValue(label(preview.state))
    }

    /// Only the latest exchange: what the person asked, and the caret's short reply.
    @ViewBuilder private var exchange: some View {
        if let turn = session.turns.last {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let image = turn.image {
                        Thumbnail(picture: image, size: 26)
                    }
                    Text(turn.words)
                        .font(size: 19, weight: .bold, relativeTo: .headline)
                        .tracking(-0.3)
                        .lineLimit(3)
                }
                HStack(alignment: .center, spacing: 4) {
                    Caret(pose: .lean(.right), size: 30, alive: false, grounded: false)
                        .padding(.leading, -9)
                    Text(reply(turn.result))
                        .font(size: 17, weight: .semibold)
                        .foregroundStyle(Palette.secondary)
                }
            }
            .padding(.top, 26)
            .accessibilityElement(children: .combine)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            PhotoButton(picture: $session.picture)
            HStack(alignment: .center, spacing: 8) {
                if session.words.isEmpty {
                    Caret(size: 30, alive: false, grounded: false)
                        .padding(.leading, -6)
                        .padding(.trailing, -10)
                }
                TextField(
                    "Change something", text: $session.words,
                    prompt: Text("Change something").foregroundStyle(Palette.secondary), axis: .vertical
                )
                .lineLimit(1...4)
                .font(size: 18, weight: .semibold)
                .foregroundStyle(Palette.text)
                .focused($typing)
                .submitLabel(.send)
                .accessibilityLabel("Change something")
                if session.canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Palette.buttonLabel)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Palette.buttonFill))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, -6)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .frame(minHeight: 60)
            .overlay(Outline())
        }
        .disabled(!composing)
        .frame(width: Column.width)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        typing = false
        session.send()
    }

    private func reply(_ result: DescribeSession.TurnResult) -> String {
        switch result {
        case .pending: "Working on it."
        case .accepted: "Done."
        case .failed: "That didn't work."
        case .cancelled: "Stopped. Nothing changed."
        }
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
