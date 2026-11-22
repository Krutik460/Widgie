import SwiftUI
import WidgetEngine

struct LibraryView: View {
    let library: Library

    @State private var session: DescribeSession?

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("My widgets").font(.largeTitle.weight(.black))
                    Spacer()
                    #if DEBUG
                        debugMenu
                    #endif
                }
                .padding(.top, 10)
                .padding(.bottom, 16)

                if library.items.isEmpty {
                    empty
                } else {
                    hero
                    Text("Saved")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(Palette.muted)
                        .padding(.top, 26)
                        .padding(.bottom, 8)
                        .padding(.leading, 2)
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(library.items) { item in
                            tile(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(Palette.ground.ignoresSafeArea())
        .fontDesign(.rounded)
        .foregroundStyle(Palette.ink)
        .refreshable { await library.reload() }
        .task { await library.reload() }
        .fullScreenCover(item: $session) { session in
            DescribeView(session: session) { saved in
                self.session = nil
                library.justSaved = saved ?? library.justSaved
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

    private var hero: some View {
        HStack(spacing: 14) {
            Mascot(mood: .idle, size: 92)
            VStack(alignment: .leading, spacing: 12) {
                Text("Got an idea?\nLet's paint it.")
                    .font(.title3.weight(.black))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    session = DescribeSession()
                } label: {
                    Label("New widget", systemImage: "plus")
                }
                .buttonStyle(ChunkyButtonStyle(height: 50, font: .subheadline.weight(.black)))
            }
        }
        .padding(16)
        .card()
    }

    private var empty: some View {
        VStack(spacing: 0) {
            Mascot(mood: .idle, size: 130)
            Text("Your home screen is waiting")
                .font(.title2.weight(.black))
                .padding(.top, 8)
            Text("Tell me an idea in plain words.\nI'll paint you a widget.")
                .font(.body.weight(.bold))
                .foregroundStyle(Palette.muted)
                .padding(.top, 6)
                .padding(.bottom, 20)
            Button("Make my first widget") { session = DescribeSession() }
                .buttonStyle(ChunkyButtonStyle())
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .card()
    }

    /// A small live face: its buttons work as on the home screen, and a tap anywhere else opens it to change.
    private func tile(_ item: Library.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let face = item.face {
                FaceView(face, host: .app(tap: { library.perform($0) }, form: { library.showForm(for: $0) }))
                    .frame(width: Family.small.standardSize.width, height: Family.small.standardSize.height)
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 6) {
                Text(item.summary.name)
                    .font(.subheadline.weight(.black))
                    .lineLimit(1)
                if library.justSaved == item.id {
                    Text("New")
                        .font(.caption.weight(.black))
                        .foregroundStyle(Color(rgb: 0x14204A))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.sun))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .card(corner: 24)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture { session = DescribeSession(editing: item.id) }
        .contextMenu {
            Button("Change it", systemImage: "paintbrush.pointed") { session = DescribeSession(editing: item.id) }
            Button("Delete", systemImage: "trash", role: .destructive) { library.delete(item.id) }
        }
        .accessibilityElement(children: .contain)
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
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Debug")
        }
    #endif
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
