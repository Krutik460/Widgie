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

    /// The face is drawn at `sizes`, which are known before the sheet opens so its height never changes under it.
    init(template: Template, sizes: FaceSizes = .standard, preview: Preview = Preview()) {
        self.template = template
        self.preview = preview
        preview.sizes = sizes
    }

    /// Builds the template with its placeholders into the preview.
    func open() async {
        guard preview.widget == nil, let source = try? template.source() else { return }
        _ = await preview.adopt(source)
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

    /// Builds the face again with the typed values, and Widgie takes up the new name.
    func refill() async {
        guard filled(values) != filled(shownValues), let widget = preview.widget,
            let source = try? template.source(filling: values)
        else { return }
        let typed = values
        guard await preview.adopt(source, replacing: widget) != nil else { return }
        shownValues = typed
        let name = template.blanks.lazy.compactMap { typed[$0.key]?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let name { react(name.count > 16 ? "Name updated." : "\(name) it is.") }
    }

    /// The filled template to add or to change in chat, and the name it will have.
    func choice() throws -> (source: WidgetSource, name: String) {
        let source = try template.source(filling: values)
        let document = try JSONSerialization.jsonObject(with: source.json) as? [String: Any]
        return (source, document?["name"] as? String ?? template.name)
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
