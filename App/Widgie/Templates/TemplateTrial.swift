import Foundation
import Observation
import WidgetBuilder
import WidgetEngine

/// One template opened to try: its live face on scratch data, the words typed into its blanks, and what Widgie
/// says beside it. Nothing here reaches the library; Add widget builds the filled template there.
@MainActor @Observable
final class TemplateTrial {
    let template: Template
    let preview: Preview
    /// What the person typed into each blank, by key. An empty or missing value means the placeholder.
    var values: [String: String] = [:]
    /// Widgie's line, nil until it first speaks.
    private(set) var said: String?
    /// Counts Widgie's reactions, so the view hops it on each one.
    private(set) var reactions = 0

    private var practiced = false
    /// The values the face on show was built with.
    private var shownValues: [String: String] = [:]
    private var building: Task<Void, Never>?

    /// The face is drawn at `sizes`, which are known before the sheet opens so its height never changes under it.
    init(template: Template, sizes: FaceSizes = .standard, preview: Preview = Preview()) {
        self.template = template
        self.preview = preview
        preview.sizes = sizes
    }

    /// Builds the face with what the blanks hold, placeholders until something is typed, and Widgie takes up a
    /// typed name. One build runs at a time, in a task of the trial's own so that a cancelled debounce never stops
    /// it halfway, and values typed while it runs are built as soon as it ends, so the face always ends on what
    /// the fields show.
    func fill() async {
        let work = building ?? Task { await buildLatest() }
        building = work
        await work.value
    }

    /// Widgie's first line: what to try on the face. Skipped once the person has already tried it.
    func greet() {
        guard said == nil, !practiced else { return }
        react(template.hint)
    }

    /// A tap on the live face writes to scratch rows only, and Widgie says so the first time.
    func tap(_ tap: Tap) {
        preview.perform(tap)
        practice()
    }

    func showForm(for tap: Tap) {
        preview.showForm(for: tap)
        practice()
    }

    /// The filled template to add or to change in chat, and the name it will have.
    func choice() throws -> (source: WidgetSource, name: String) {
        let source = try template.source(filling: values)
        let document = try JSONSerialization.jsonObject(with: source.json) as? [String: Any]
        return (source, document?["name"] as? String ?? template.name)
    }

    private func buildLatest() async {
        defer { building = nil }
        while preview.widget == nil || filled(values) != filled(shownValues) {
            let typed = values
            let shown = preview.widget
            guard let source = try? template.source(filling: typed),
                await preview.adopt(source, replacing: shown) != nil
            else { return }
            let (was, now) = (filled(shownValues), filled(typed))
            shownValues = typed
            guard shown != nil else { continue }
            // Widgie takes up the word that changed, not the first one filled in. A cleared field says nothing.
            let edited = template.blanks.lazy.compactMap { now[$0.key] == was[$0.key] ? nil : now[$0.key] }.first
            if let edited { react(edited.count > 16 ? "Name updated." : "\(edited) it is.") }
        }
    }

    private func practice() {
        if practiced {
            reactions += 1
        } else {
            practiced = true
            react("Just practice. Yours starts fresh.")
        }
    }

    private func react(_ line: String) {
        said = line
        reactions += 1
    }

    private func filled(_ values: [String: String]) -> [String: String] {
        values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
    }
}
