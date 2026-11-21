import SwiftUI
import WidgetEngine

struct LibraryView: View {
    let library: Library

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
                                    FaceView(face, host: .app(library))
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
                        ForEach(library.fixtures, id: \.folder) { fixture in
                            Button(fixture.name) { library.install(fixture.folder) }
                        }
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
                message: { Text(library.message ?? "") })
        }
    }
}

extension FaceHost {
    /// Taps write straight to the store, form buttons open the form sheet, and the background is drawn
    /// under the content, clipped like a widget.
    @MainActor static func app(_ library: Library) -> FaceHost {
        FaceHost(
            button: { tap, label in
                AnyView(
                    Button {
                        library.perform(tap)
                    } label: {
                        label
                    }.buttonStyle(.plain))
            },
            form: { tap, label in
                AnyView(
                    Button {
                        library.showForm(for: tap)
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
