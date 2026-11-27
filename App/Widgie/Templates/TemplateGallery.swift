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
///
/// A face shows its sample at the moment it was staged, so drawing it again at another width shows the same
/// sample. The samples are staged again when the day turns, so dates and the day's question stay today's. A
/// template that does not stage or draws a fallback face keeps no face, and is tried again on the next fit, the
/// next day, or when the clock changes.
@MainActor @Observable
final class TemplateGallery {
    /// One template's face in the pile, observed on its own, so a face that lands redraws only its card.
    @MainActor @Observable
    final class Card {
        fileprivate(set) var face: Face?
        /// What `face` was drawn for. The card waits for a new face while this is not the gallery's pass.
        @ObservationIgnored fileprivate var drawn: Pass?
    }

    /// What the faces are drawn for: the pile's sizes and the day the samples show.
    fileprivate struct Pass: Equatable {
        let sizes: FaceSizes
        let day: Date
    }

    /// A template saved in the scratch engine with its first sample's rows as of `at`, the moment its face shows.
    private struct Staged: Sendable {
        let widget: WidgetID
        let at: Date
    }

    let catalog: [Template]
    /// The faces' sizes, set from the width of the pile.
    private(set) var sizes = FaceSizes.standard

    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private let cards: [Template.ID: Card]
    @ObservationIgnored private let redraws: Redraws
    @ObservationIgnored private let calendar = Calendar.autoupdatingCurrent
    /// Nil until the pile's width is known.
    @ObservationIgnored private var pass: Pass?
    @ObservationIgnored private var staged: [Template.ID: Staged] = [:]
    /// The templates that did not stage or draw in this pass.
    @ObservationIgnored private var failed: Set<Template.ID> = []
    @ObservationIgnored private var first = Template.Category.forTwo
    @ObservationIgnored private var drawing: Task<Void, Never>?

    init(
        catalog: [Template] = Template.catalog(), engine: Engine = .scratch(), clock: FaceClock = .system,
        center: NotificationCenter = .default
    ) {
        self.catalog = catalog
        self.engine = engine
        cards = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, Card()) })
        redraws = Redraws(clock: clock, center: center)
        redraws.redraw = { [weak self] in
            guard let self, pass != nil else { return }
            begin()
        }
    }

    /// One category's templates, in gallery order.
    func templates(in category: Template.Category) -> [Template] {
        catalog.filter { $0.category == category }
    }

    func card(_ id: Template.ID) -> Card {
        cards[id] ?? Card()
    }

    /// Sizes the faces for a pile `width` wide and draws the ones not drawn yet at those sizes, all of them when
    /// the sizes change, and tries again the ones that failed.
    func fit(column width: CGFloat) {
        let sizes = FaceSizes(column: width)
        if sizes != self.sizes {
            self.sizes = sizes
            for card in cards.values where card.face != nil { card.face = nil }
        }
        begin()
    }

    /// Draws `category`'s faces before the others still to draw.
    func show(_ category: Template.Category) {
        first = category
    }

    /// Waits until every face is drawn for the current pass, or none is being drawn.
    func drawn() async {
        await drawing?.value
    }

    /// Starts a pass for the current sizes and today, keeping the faces already drawn for it.
    private func begin() {
        let day = calendar.startOfDay(for: redraws.clock.now())
        pass = Pass(sizes: sizes, day: day)
        failed = []
        redraws.schedule(calendar.date(byAdding: .day, value: 1, to: day))
        drawing = drawing ?? Task(priority: .utility) { await drawAll() }
    }

    private func drawAll() async {
        defer { drawing = nil }
        while let pass, let template = next() {
            let kept = staged[template.id].flatMap { calendar.startOfDay(for: $0.at) == pass.day ? $0 : nil }
            let drawn = await Self.draw(
                template, staged: kept, at: redraws.clock.now(), size: pass.sizes[template.family], engine: engine)
            guard let drawn else {
                if let old = staged.removeValue(forKey: template.id) { try? engine.delete(old.widget) }
                if pass == self.pass { failed.insert(template.id) }
                continue
            }
            if let old = staged[template.id], old.widget != drawn.staged.widget { try? engine.delete(old.widget) }
            staged[template.id] = drawn.staged
            guard pass == self.pass, let card = cards[template.id] else { continue }
            card.face = drawn.face
            card.drawn = pass
        }
    }

    /// The next template whose face is not drawn for this pass, from the shown category first, then in gallery
    /// order.
    private func next() -> Template? {
        func waiting(_ template: Template) -> Bool {
            cards[template.id]?.drawn != pass && !failed.contains(template.id)
        }
        return templates(in: first).first(where: waiting) ?? catalog.first(where: waiting)
    }

    /// The template's face off the main actor, staged at `now` first unless `staged` is given. Nil, with the
    /// reason logged, when it does not stage or its face falls back, and then a widget staged for it is deleted,
    /// so the next try stages it afresh.
    @concurrent private nonisolated static func draw(
        _ template: Template, staged: Staged?, at now: Date, size: CGSize, engine: Engine
    ) async -> (staged: Staged, face: Face)? {
        let ready: Staged
        do {
            ready = try staged ?? Staged(widget: engine.stageProved(try template.source(), at: now), at: now)
        } catch {
            log.error("\(template.id, privacy: .public) did not stage: \(String(describing: error), privacy: .public)")
            return nil
        }
        let face = await engine.face(for: ready.widget, family: template.family, size: size, at: ready.at).current
        guard !face.isFallback else {
            log.error("\(template.id, privacy: .public) drew a fallback face")
            try? engine.delete(ready.widget)
            return nil
        }
        return (ready, face)
    }
}
