#if DEBUG
    import SwiftUI
    import WidgetBuilder
    import WidgetEngine

    /// Debug only: a reference widget, or a copy of a library widget, as an unsaved draft in a preview, so the
    /// preview can be tried before the describe screen exists.
    struct PreviewLab: View {
        struct Opening: Identifiable {
            enum Start {
                case fixture(String)
                case copy(WidgetID)
            }

            let id = UUID()
            let start: Start
            let preview: Preview
        }

        let opening: Opening
        let library: Library

        @Environment(\.dismiss) private var dismiss
        @State private var saved: String?

        private var preview: Preview { opening.preview }

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) {
                        if preview.states.count > 1 {
                            Picker("Data", selection: Binding(get: { preview.state }, set: select)) {
                                ForEach(preview.states, id: \.self) { state in
                                    Text(label(state)).tag(state)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        ForEach(Family.allCases, id: \.self) { family in
                            if let face = preview.faces[family] {
                                FaceView(
                                    face,
                                    host: .app(tap: { preview.perform($0) }, form: { preview.showForm(for: $0) })
                                )
                                .frame(width: family.standardSize.width, height: family.standardSize.height)
                            }
                        }
                        if let saved {
                            Text(saved).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Draft preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }.disabled(preview.widget == nil)
                    }
                }
                .task { await start() }
                .sheet(
                    isPresented: Binding(get: { preview.form != nil }, set: { if !$0 { preview.form = nil } })
                ) {
                    if let form = preview.form {
                        FormSheet(form: form) { input in
                            preview.perform(form.tap, input: input)
                            preview.form = nil
                        }
                    }
                }
                .alert(
                    "Something went wrong", isPresented: .constant(preview.message != nil),
                    actions: { Button("OK") { preview.message = nil } },
                    message: { Text(preview.message ?? "") })
            }
        }

        private func start() async {
            guard preview.widget == nil else { return }
            switch opening.start {
            case .fixture(let folder):
                do {
                    guard let source = try Library.fixture(folder) else { return }
                    switch try await preview.engine.build(source) {
                    case .saved(let draft): await preview.show(draft)
                    case .rejected(let line): preview.message = line
                    }
                } catch let error as EngineError {
                    preview.message = error.message
                } catch let error as Rejected {
                    preview.message = error.line
                } catch {
                    preview.message = "\(error)"
                }
            case .copy(let widget):
                _ = await preview.copy(widget)
            }
        }

        private func select(_ state: DataState) {
            Task { await preview.select(state) }
        }

        private func save() async {
            switch await preview.save(replacing: nil) {
            case .saved:
                saved = "Saved to the library."
                await library.reload()
            case .rejected(let line):
                preview.message = line
            case nil:
                break
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
#endif
