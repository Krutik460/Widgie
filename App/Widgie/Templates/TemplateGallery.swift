import Foundation
import OSLog
import Observation
import WidgetBuilder
import WidgetEngine

private let log = Logger(subsystem: "dev.krutikpatel.widgie", category: "templates")

/// The bundled templates and their faces in the pile. Once the pile's width is known, every face is drawn in the
/// background, one at a time and the shown category first, from the template's first sample in a scratch engine
/// of the gallery's own. The templates are proved by the app's tests, so a face is staged and drawn without the
/// proof that building runs, and costs one look run.
@MainActor @Observable
final class TemplateGallery {
    /// One template's face in the pile, observed on its own, so a face that lands redraws only its card.
    @MainActor @Observable
    final class Card {
        fileprivate(set) var face: Face?
    }

    let catalog: [Template]
    /// The faces' sizes, set from the width of the pile.
    private(set) var sizes = FaceSizes.standard

    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private let cards: [Template.ID: Card]
    /// Each template's widget in the scratch engine, with its first sample loaded.
    @ObservationIgnored private var staged: [Template.ID: WidgetID] = [:]
    @ObservationIgnored private var unstaged: Set<Template.ID> = []
    @ObservationIgnored private var fitted = false
    @ObservationIgnored private var first = Template.Category.forTwo
    @ObservationIgnored private var drawing: Task<Void, Never>?

    init(catalog: [Template] = Template.catalog(), engine: Engine = .scratch()) {
        self.catalog = catalog
        self.engine = engine
        cards = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, Card()) })
    }

    /// One category's templates, in gallery order.
    func templates(in category: Template.Category) -> [Template] {
        catalog.filter { $0.category == category }
    }

    func card(_ id: Template.ID) -> Card {
        cards[id] ?? Card()
    }

    /// Sizes the faces for a pile `width` wide and draws them all, again when the sizes change.
    func fit(column width: CGFloat) {
        let sizes = FaceSizes(column: width)
        guard !fitted || sizes != self.sizes else { return }
        fitted = true
        self.sizes = sizes
        for card in cards.values where card.face != nil { card.face = nil }
        drawing = drawing ?? Task(priority: .utility) { await drawAll() }
    }

    /// Draws `category`'s faces before the others still to draw.
    func show(_ category: Template.Category) {
        first = category
    }

    /// Waits until every face is drawn at the current sizes, or none is being drawn.
    func drawn() async {
        await drawing?.value
    }

    private func drawAll() async {
        defer { drawing = nil }
        while let template = next() {
            let sizes = sizes
            let drawn = await Self.draw(
                template, staged: staged[template.id], size: sizes[template.family], engine: engine)
            guard let drawn else {
                unstaged.insert(template.id)
                continue
            }
            staged[template.id] = drawn.widget
            if sizes == self.sizes { cards[template.id]?.face = drawn.face }
        }
    }

    /// The next template without a face, from the shown category first, then in gallery order.
    private func next() -> Template? {
        func waiting(_ template: Template) -> Bool {
            cards[template.id]?.face == nil && !unstaged.contains(template.id)
        }
        return templates(in: first).first(where: waiting) ?? catalog.first(where: waiting)
    }

    /// The template's face off the main actor, staging it first unless it is staged. Nil, with the reason logged,
    /// when it does not stage, which only a broken bundle causes.
    private nonisolated static func draw(_ template: Template, staged: WidgetID?, size: CGSize, engine: Engine) async
        -> (widget: WidgetID, face: Face)?
    {
        let widget: WidgetID
        do {
            widget = try staged ?? engine.stage(try template.source())
        } catch {
            log.error("\(template.id, privacy: .public) did not stage: \(String(describing: error), privacy: .public)")
            return nil
        }
        return (widget, await engine.face(for: widget, family: template.family, size: size, at: .now))
    }
}
