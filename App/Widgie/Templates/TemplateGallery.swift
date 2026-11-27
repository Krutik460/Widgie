import Foundation
import OSLog
import Observation
import WidgetBuilder
import WidgetEngine

private let log = Logger(subsystem: "dev.krutikpatel.widgie", category: "templates")

/// The bundled templates and their faces in the pile. Each face is drawn from the template's first sample in a
/// scratch engine of the gallery's own, at the pile's column size, once: the first time its card appears.
@MainActor @Observable
final class TemplateGallery {
    let catalog: [Template]
    private(set) var faces: [Template.ID: Face] = [:]
    /// The faces' sizes, set from the width of the pile.
    private(set) var sizes = FaceSizes.standard

    private let engine: Engine
    /// Each template's widget in the scratch engine, with its first sample loaded.
    private var built: [Template.ID: WidgetID] = [:]
    private var drawing: Set<Template.ID> = []

    init(catalog: [Template] = Template.catalog(), engine: Engine = .scratch()) {
        self.catalog = catalog
        self.engine = engine
    }

    /// One category's templates, in gallery order.
    func templates(in category: Template.Category) -> [Template] {
        catalog.filter { $0.category == category }
    }

    func fit(column width: CGFloat) {
        let sizes = FaceSizes(column: width)
        guard sizes != self.sizes else { return }
        self.sizes = sizes
        faces = [:]
    }

    /// Draws the template's face unless it is drawn or drawing. A drawing that finishes after the sizes changed
    /// is dropped and drawn again at the new sizes.
    func draw(_ template: Template) async {
        guard faces[template.id] == nil, drawing.insert(template.id).inserted else { return }
        defer { drawing.remove(template.id) }
        while faces[template.id] == nil {
            let sizes = sizes
            guard let widget = await widget(for: template) else { return }
            let face = await engine.faces(
                for: widget, family: template.family, size: sizes[template.family], from: .now
            ).current
            if sizes == self.sizes { faces[template.id] = face }
        }
    }

    private func widget(for template: Template) async -> WidgetID? {
        if let widget = built[template.id] { return widget }
        do {
            switch try await engine.build(try template.source()) {
            case .saved(let widget):
                if let sample = try engine.samples(of: widget).first {
                    try engine.load(.sample(sample), into: widget)
                }
                built[template.id] = widget
                return widget
            case .rejected(let line):
                log.error("\(template.id, privacy: .public) did not build: \(line, privacy: .public)")
                return nil
            }
        } catch {
            log.error("\(template.id, privacy: .public) did not build: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
