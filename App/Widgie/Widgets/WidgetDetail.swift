import SwiftUI
import WidgetEngine

/// One widget up close: its live faces in both sizes, whether it is on the home screen and how to put it there,
/// Change it, and Delete.
struct WidgetDetail: View {
    let library: Library
    let id: WidgetID

    @State private var session: DescribeSession?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    private var item: Library.Item? { library.items.first { $0.id == id } }
    private var placed: Set<Family> { library.placed[id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.summary.name)
                            .font(size: 30, weight: .heavy, relativeTo: .title)
                            .tracking(-1)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(status)
                            .font(size: 15, weight: .medium, relativeTo: .subheadline)
                            .foregroundStyle(Palette.secondary)
                            .padding(.top, 4)
                        faces(item).padding(.top, 22)
                        if placed.isEmpty {
                            howToAdd.padding(.top, 28)
                        }
                    }
                    .padding(.horizontal, WidgetsFeed.margin)
                    .padding(.bottom, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Button("Change it") { session = DescribeSession(editing: id) }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.horizontal, WidgetsFeed.margin)
                        .padding(.top, 28)
                        .padding(.bottom, 8)
                        .background {
                            // What scrolls under the button fades into the ground instead of being cut off.
                            LinearGradient(
                                stops: [
                                    .init(color: Palette.ground.opacity(0), location: 0),
                                    .init(color: Palette.ground, location: 0.4),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                            .ignoresSafeArea(edges: .bottom)
                            .allowsHitTesting(false)
                        }
                }
            } else {
                // Deleted elsewhere, for example from the context menu behind this sheet.
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Palette.text)
        .presentationBackground { Palette.ground.overlay(DotGrid()) }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
        .confirmationDialog("Delete this widget?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.delete(id)
                dismiss()
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(Self.deleteMessage(placed: !placed.isEmpty))
        }
        .fullScreenCover(item: $session) { session in
            DescribeView(session: session) { _ in
                self.session = nil
                library.refresh()
            }
        }
        .sheet(item: Bindable(library).form) { form in
            FormSheet(form: form.form) { input in
                library.perform(form.form.tap, input: input)
                library.form = nil
            }
        }
        .alert(
            "Something went wrong", isPresented: .constant(library.message != nil),
            actions: { Button("OK") { library.message = nil } },
            message: { Text(library.message ?? "") }
        )
    }

    private var status: String {
        switch (placed.contains(.small), placed.contains(.medium)) {
        case (true, true): "On your home screen, small and wide"
        case (true, false): "On your home screen, small"
        case (false, true): "On your home screen, wide"
        case (false, false): "Not on your home screen yet"
        }
    }

    private var topBar: some View {
        HStack {
            CloseButton { dismiss() }
            Spacer()
            Button {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Delete")
            .disabled(item == nil)
        }
        .padding(.horizontal, WidgetsFeed.margin - 10)
        .padding(.top, 14)
    }

    /// The wide face, then the small one with the caret leaning toward it.
    private func faces(_ item: Library.Item) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            LiveFace(face: item.faces[.medium], size: library.sizes.medium, tap: perform, form: showForm)
            HStack(alignment: .bottom, spacing: 0) {
                LiveFace(face: item.faces[.small], size: library.sizes.small, tap: perform, form: showForm)
                Spacer(minLength: 0)
                Caret(pose: .lean(.left), size: 120)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Three short steps, each with the symbol for the thing to touch.
    private var howToAdd: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add it to your home screen")
                .font(size: 19, weight: .bold, relativeTo: .headline)
                .tracking(-0.4)
                .accessibilityAddTraits(.isHeader)
            step("hand.tap", "Touch and hold an empty spot on your home screen.")
            step("plus.square", "Tap Edit, then Add Widget.")
            step("magnifyingglass", "Find Widgie, pick a size, and tap Add Widget.")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.buttonFill.opacity(0.06)))
    }

    private func step(_ symbol: String, _ words: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(words)
                .font(size: 16, weight: .medium)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What deleting takes with it. A home screen widget showing this one moves on to another or goes blank.
    static func deleteMessage(placed: Bool) -> String {
        placed ? "Its data goes with it, and your home screen stops showing it." : "Its data goes with it."
    }

    private func perform(_ tap: Tap) {
        library.perform(tap)
    }

    private func showForm(_ tap: Tap) {
        library.showForm(for: tap)
    }
}
