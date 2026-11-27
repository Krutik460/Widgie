import SwiftUI
import WidgetEngine

/// Your widgets as live faces, the size each sits on the home screen: wide ones fill a row and smalls sit in
/// pairs. A face's buttons work as on the home screen; a tap anywhere else opens the widget.
struct WidgetsFeed: View {
    let library: Library
    /// Switches to the Make tab.
    let make: () -> Void

    @State private var shown: Shown?
    @State private var session: DescribeSession?
    @State private var deleting: WidgetID?

    struct Shown: Identifiable {
        let id: WidgetID
    }

    static let margin: CGFloat = 16

    var body: some View {
        Group {
            if library.items.isEmpty {
                empty
            } else {
                feed
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ground()
        .foregroundStyle(Palette.text)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            library.fit(column: width - 2 * Self.margin)
        }
        .sheet(item: $shown) { shown in
            WidgetDetail(library: library, id: shown.id)
        }
        .fullScreenCover(item: $session) { session in
            DescribeView(session: session) { _ in
                self.session = nil
                library.refresh()
            }
        }
        // The detail sheet shows the form and the message itself while it is up.
        .sheet(item: Binding(get: { shown == nil ? library.form : nil }, set: { library.form = $0 })) { form in
            FormSheet(form: form.form) { input in
                library.perform(form.form.tap, input: input)
                library.form = nil
            }
        }
        .confirmationDialog(
            "Delete this widget?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { id in
            Button("Delete", role: .destructive) { library.delete(id) }
            Button("Keep it", role: .cancel) {}
        } message: { id in
            Text(WidgetDetail.deleteMessage(placed: library.placed[id] != nil))
        }
        .alert(
            "Something went wrong", isPresented: .constant(shown == nil && library.message != nil),
            actions: { Button("OK") { library.message = nil } },
            message: { Text(library.message ?? "") }
        )
    }

    private var feed: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(rows) { row in
                        switch row {
                        case .wide(let id):
                            card(id, .medium)
                        case .pair(let first, let second):
                            HStack(alignment: .top, spacing: FaceSizes.gap) {
                                card(first, .small)
                                if let second { card(second, .small) }
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, Self.margin)
            .padding(.bottom, 24)
        }
        .refreshable { await library.reload() }
    }

    private var rows: [FeedRow<WidgetID>] {
        FeedRow.rows(
            library.items.enumerated().map { index, item in (item.id, library.family(of: item, at: index)) })
    }

    /// The wordmark, a count of widgets and how many are on the home screen, and the caret leaning in.
    private var header: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                wordmark
                Text(count)
                    .font(size: 15, weight: .medium, relativeTo: .subheadline)
                    .foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 8)
            Caret(pose: .lean(.left), size: 84)
                .padding(.trailing, -14)
                .padding(.bottom, -8)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var count: String {
        let widgets = library.items.count == 1 ? "1 widget" : "\(library.items.count) widgets"
        let placed = library.placedCount
        return placed == 0 ? widgets : "\(widgets), \(placed) on your home screen"
    }

    /// In debug builds, a long press on the wordmark installs a reference widget.
    @ViewBuilder private var wordmark: some View {
        #if DEBUG
            Wordmark().contextMenu {
                Section("Install reference widget") {
                    ForEach(library.fixtures, id: \.folder) { fixture in
                        Button(fixture.name) { library.install(fixture.folder) }
                    }
                }
            }
        #else
            Wordmark()
        #endif
    }

    @ViewBuilder private func card(_ id: WidgetID, _ family: Family) -> some View {
        if let item = library.items.first(where: { $0.id == id }) {
            FeedCard(item: item, family: family, size: library.sizes[family], placed: library.placed[id] != nil) {
                library.perform($0)
            } form: {
                library.showForm(for: $0)
            }
            .onTapGesture { shown = Shown(id: id) }
            .contextMenu {
                Button("Change it", systemImage: "pencil") { session = DescribeSession(editing: id) }
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = id }
            }
            .accessibilityAction(named: "Open") { shown = Shown(id: id) }
            .accessibilityAction(named: "Change it") { session = DescribeSession(editing: id) }
        }
    }

    /// No widgets yet: the caret waits for one.
    private var empty: some View {
        VStack(spacing: 0) {
            HStack {
                wordmark
                Spacer()
            }
            .padding(.top, 8)
            Spacer(minLength: 12)
            Caret(size: 230)
            Text("Tell me a widget.")
                .font(size: 36, weight: .heavy, relativeTo: .largeTitle)
                .tracking(-1.2)
                .multilineTextAlignment(.center)
                .padding(.top, 28)
            Text("Say what you want to see on your home screen, and I’ll make it.")
                .font(size: 17, weight: .medium)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.horizontal, 12)
            Spacer(minLength: 24)
            Button("Make one", action: make)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.bottom, 16)
        }
        .padding(.horizontal, Column.margin - 8)
    }
}

/// A live face and its caption: the name, and a mark when it is on the home screen.
struct FeedCard: View {
    let item: Library.Item
    let family: Family
    let size: CGSize
    let placed: Bool
    let tap: @MainActor @Sendable (Tap) -> Void
    let form: @MainActor @Sendable (Tap) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LiveFace(face: item.faces[family], size: size, tap: tap, form: form)
            HStack(spacing: 6) {
                Text(item.summary.name)
                    .font(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .tracking(-0.2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if placed {
                    Image(systemName: "iphone")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(width: size.width)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(placed ? "\(item.summary.name), on your home screen" : item.summary.name)
    }
}

/// A face drawn at `size`, its buttons live, lifted off the ground like a widget. A grey tile until it draws.
struct LiveFace: View {
    let face: Face?
    let size: CGSize
    let tap: @MainActor @Sendable (Tap) -> Void
    let form: @MainActor @Sendable (Tap) -> Void

    var body: some View {
        Group {
            if let face {
                FaceView(face, host: .app(tap: tap, form: form))
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.disabled.opacity(0.4))
            }
        }
        .frame(width: size.width, height: size.height)
        .faceShadow()
    }
}
