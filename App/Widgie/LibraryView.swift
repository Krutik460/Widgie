import SwiftUI
import WidgetEngine

/// The widgets as they look on the home screen, and New widget. With none yet, the caret asks for one.
struct LibraryView: View {
    let library: Library

    @State private var session: DescribeSession?

    var body: some View {
        ZStack(alignment: .bottom) {
            if library.items.isEmpty {
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 12)
                    Caret(size: 270)
                    Text("Tell me a widget.")
                        .font(size: 40, weight: .heavy, relativeTo: .largeTitle)
                        .tracking(-1.4)
                        .multilineTextAlignment(.center)
                        .padding(.top, 34)
                    Spacer(minLength: 108)
                }
                .padding(.horizontal, Column.margin)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        rows.padding(.top, 14)
                    }
                    .frame(width: Column.width)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 116)
                }
                .refreshable { await library.reload() }
            }
            newWidget
        }
        .ground()
        .foregroundStyle(Palette.text)
        .task { await library.reload() }
        .fullScreenCover(item: $session) { session in
            DescribeView(session: session) { _ in
                self.session = nil
                library.refresh()
            }
        }
        .sheet(isPresented: Binding(get: { library.form != nil }, set: { if !$0 { library.form = nil } })) {
            if let form = library.form {
                FormSheet(form: form) { input in
                    library.perform(form.tap, input: input)
                    library.form = nil
                }
            }
        }
        .alert(
            "Something went wrong", isPresented: .constant(library.message != nil),
            actions: { Button("OK") { library.message = nil } },
            message: { Text(library.message ?? "") }
        )
    }

    /// The wordmark, and the caret leaning in from the corner toward it.
    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            Wordmark().padding(.top, 2)
            Spacer(minLength: 8)
            #if DEBUG
                debugMenu.padding(.top, 2)
            #endif
            Caret(pose: library.items.isEmpty ? .idle : .lean(.left), size: 88)
                .padding(.top, 6)
                .padding(.trailing, -18)
                .opacity(library.items.isEmpty ? 0 : 1)
        }
    }

    /// The faces in home screen sizes: a medium, then a pair of smalls, and again.
    private var rows: some View {
        let items = library.items
        let rows = stride(from: 0, to: items.count, by: 3).map { start in
            (medium: items[start], smalls: Array(items[min(start + 1, items.count)..<min(start + 3, items.count)]))
        }
        return VStack(alignment: .leading, spacing: 22) {
            ForEach(rows, id: \.medium.id) { row in
                tile(row.medium, .medium)
                if !row.smalls.isEmpty {
                    HStack(spacing: Column.width - 2 * Family.small.standardSize.width) {
                        ForEach(row.smalls) { tile($0, .small) }
                    }
                }
            }
        }
    }

    private var newWidget: some View {
        Button("New widget") { session = DescribeSession() }
            .buttonStyle(PrimaryButtonStyle())
            .frame(width: Column.width)
            .padding(.top, 36)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background {
                LinearGradient(
                    stops: [
                        .init(color: Palette.ground.opacity(0), location: 0),
                        .init(color: Palette.ground, location: 0.48),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
    }

    /// A live face: its buttons work as on the home screen, and a tap anywhere else opens it to change.
    @ViewBuilder private func tile(_ item: Library.Item, _ family: Family) -> some View {
        let size = family.standardSize
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        Group {
            if let face = item.faces[family] {
                FaceView(face, host: .app(tap: { library.perform($0) }, form: { library.showForm(for: $0) }))
            } else {
                shape.fill(Palette.disabled.opacity(0.4))
            }
        }
        .frame(width: size.width, height: size.height)
        .faceShadow()
        .contentShape(shape)
        .onTapGesture { session = DescribeSession(editing: item.id) }
        .contextMenu {
            Button("Change it", systemImage: "pencil") { session = DescribeSession(editing: item.id) }
            Button("Delete", systemImage: "trash", role: .destructive) { library.delete(item.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.summary.name)
        .accessibilityAction(named: "Change it") { session = DescribeSession(editing: item.id) }
    }

    #if DEBUG
        private var debugMenu: some View {
            Menu {
                Section("Install reference widget") {
                    ForEach(library.fixtures, id: \.folder) { fixture in
                        Button(fixture.name) { library.install(fixture.folder) }
                    }
                }
            } label: {
                Image(systemName: "ladybug")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Debug")
        }
    #endif
}

/// The describe flow and the library share one column, the medium widget's width, centered on the screen.
enum Column {
    static let width = Family.medium.standardSize.width
    static let margin: CGFloat = 32
}

extension FaceHost {
    /// Taps run in the app, form buttons open its form sheet, and the background is drawn under the content,
    /// clipped like a widget.
    @MainActor static func app(
        tap: @escaping @MainActor @Sendable (Tap) -> Void, form: @escaping @MainActor @Sendable (Tap) -> Void
    ) -> FaceHost {
        FaceHost(
            button: { tapped, label in
                AnyView(
                    Button {
                        tap(tapped)
                    } label: {
                        label
                    }.buttonStyle(.plain))
            },
            form: { tapped, label in
                AnyView(
                    Button {
                        form(tapped)
                    } label: {
                        label
                    }.buttonStyle(.plain))
            },
            root: { content, background in
                AnyView(
                    ZStack {
                        background
                        content
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
            }
        )
    }
}
