import SwiftUI
import WidgetEngine

struct LibraryView: View {
    let library: Library

    #if DEBUG
        @State private var lab: PreviewLab.Opening?
    #endif

    var body: some View {
        NavigationStack {
            // A plain column, not a List: the list's insets leave less than a medium face's 338 points.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if library.items.isEmpty {
                        ContentUnavailableView(
                            "No widgets yet", systemImage: "square.grid.2x2",
                            description: Text("Install a reference widget, then add it from the home screen."))
                    }
                    ForEach(library.items) { item in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(item.summary.name).font(.headline)
                                Spacer()
                                Menu {
                                    #if DEBUG
                                        Button("Preview a copy", systemImage: "eye") {
                                            lab = PreviewLab.Opening(start: .copy(item.id), preview: Preview())
                                        }
                                    #endif
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        library.delete(item.id)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 32, height: 32)
                                }
                                .accessibilityLabel("Options for \(item.summary.name)")
                            }
                            ForEach(Family.allCases, id: \.self) { family in
                                if let face = item.faces[family] {
                                    FaceView(
                                        face,
                                        host: .app(tap: { library.perform($0) }, form: { library.showForm(for: $0) })
                                    )
                                    .frame(width: family.standardSize.width, height: family.standardSize.height)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Widgets")
            .toolbar {
                if !library.fixtures.isEmpty {
                    Menu {
                        Section("Install") {
                            ForEach(library.fixtures, id: \.folder) { fixture in
                                Button(fixture.name) { library.install(fixture.folder) }
                            }
                        }
                        #if DEBUG
                            Section("Preview without saving") {
                                ForEach(library.fixtures, id: \.folder) { fixture in
                                    Button(fixture.name) {
                                        lab = PreviewLab.Opening(start: .fixture(fixture.folder), preview: Preview())
                                    }
                                }
                            }
                        #endif
                    } label: {
                        Label("Install reference widget", systemImage: "plus")
                    }
                }
            }
            .refreshable { await library.reload() }
            .task { await library.reload() }
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
            #if DEBUG
                .sheet(item: $lab) { opening in PreviewLab(opening: opening, library: library) }
            #endif
        }
    }
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
