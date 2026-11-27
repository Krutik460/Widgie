import PhotosUI
import SwiftUI

/// The field pinned over the tab bar: a quiet photo button, the words growing to five lines, and the send key,
/// which stops the build while one runs.
struct Composer: View {
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
    func returnSends(_ text: Binding<String>, _ send: @escaping () -> Void) -> some View {
        onChange(of: text.wrappedValue) { _, value in
            guard value.contains("\n") else { return }
            text.wrappedValue = value.replacingOccurrences(of: "\n", with: "")
            send()
        }
    }
}

/// A change suggested above the composer: a small soft key that sends its words.
struct ChangeChipStyle: ButtonStyle {
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
