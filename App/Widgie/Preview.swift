import Foundation
import OSLog
import Observation
import WidgetBuilder
import WidgetEngine
import WidgetHosting

private let log = Logger(subsystem: "dev.krutikpatel.widgie", category: "describe")

/// A draft's live face, drawn from a scratch engine of its own. The draft never reaches the shared store, so
/// the home screen widget picker cannot list it before Save, and taps write to scratch rows (a sample's, or a copy
/// of the rows a library widget reads), never the person's. Releasing the preview deletes the draft. While the app
/// is in the foreground it draws the faces again at the moment they change, such as an undo's window closing.
@MainActor @Observable
final class Preview {
    /// Where the draft lives. The build loop runs on this engine, so every accepted attempt saves only here.
    let engine: Engine
    /// The shared store a Save writes to, and a refinement copies from.
    private let library: Engine

    /// The draft on show, nil before the first one.
    private(set) var widget: WidgetID?
    /// The name the draft on show gives itself.
    private(set) var name: String?
    private(set) var faces: [Family: Face] = [:]
    /// The sizes the faces are drawn at. Set it before the first draft goes on show.
    var sizes = FaceSizes.standard
    var form: ShownForm?
    var message: String?

    /// Whether a draft is drawn from no rows, as a saved widget starts, rather than from its first sample.
    private let startsEmpty: Bool
    @ObservationIgnored private let redraws: Redraws
    @ObservationIgnored private var drawings = 0
    @ObservationIgnored private var shows = 0

    init(
        library: Engine = Hosting.engine, engine: Engine = .scratch(), startsEmpty: Bool = false,
        clock: FaceClock = .system, center: NotificationCenter = .default
    ) {
        self.library = library
        self.engine = engine
        self.startsEmpty = startsEmpty
        redraws = Redraws(clock: clock, center: center)
        redraws.redraw = { [weak self] in
            Task { await self?.redraw() }
        }
    }

    /// Shows a draft the scratch engine holds, loading its data afresh: no rows, or its first sample so it does not
    /// look empty. With `keepingRows` it draws the rows the draft already has, taps included. Nothing on show
    /// changes until its faces are drawn, and then all of it changes at once. Returns true once the draft is on
    /// show. Returns false, with nothing on show changed, when the data did not load (logged), the task was
    /// cancelled, or a later `show` started before then; the draft's rows may already hold the new data. A tap or a
    /// redraw of the face on show meanwhile makes it draw again, so it shows the newest rows.
    func show(_ widget: WidgetID, keepingRows: Bool = false) async -> Bool {
        shows += 1
        let showing = shows
        let name: String?
        do {
            if !keepingRows {
                let sample = startsEmpty ? nil : try engine.samples(of: widget).first
                try engine.load(sample.map(DataState.sample) ?? .empty, into: widget, at: redraws.clock.now())
            }
            name = try engine.widgets().first { $0.id == widget }?.name
        } catch {
            log.error("show: \(error.message, privacy: .public)")
            return false
        }
        while !Task.isCancelled, showing == shows {
            guard let drawn = await draw(widget) else { continue }
            guard !Task.isCancelled, showing == shows else { break }
            self.widget = widget
            self.name = name
            faces = drawn.faces
            redraws.schedule(drawn.changes)
            return true
        }
        return false
    }

    /// Puts the draft back as `checkpoint` recorded it, rows included, and draws it again.
    func rollBack(to checkpoint: Checkpoint) async throws(EngineError) {
        try engine.rollBack(to: checkpoint)
        await redraw()
    }

    /// Copies a library widget into the scratch engine with a copy of its rows and shows it with them, so the draft
    /// starts as the widget looks now, and refining it never writes the person's rows. The copy runs off the main
    /// actor, and nothing goes on show until it is whole, so the draft never shows empty first. Returns the draft's
    /// id in the scratch engine, or nil, with the reason logged, when the widget is gone or cannot be copied.
    func copy(_ saved: WidgetID) async -> WidgetID? {
        do {
            let started = ContinuousClock.now
            guard let draft = try await engine.copy(saved, from: library) else {
                log.error("copy: \(saved.rawValue, privacy: .public) is no longer in the library")
                return nil
            }
            let took = (ContinuousClock.now - started).formatted(.units(fractionalPart: .show(length: 2)))
            log.info("copy: copied in \(took, privacy: .public)")
            return await show(draft, keepingRows: true) ? draft : nil
        } catch {
            log.error("copy: \(error.message, privacy: .public)")
            return nil
        }
    }

    /// Builds a widget that is not in the library, such as a filled template, into the scratch engine and shows
    /// it, as a new draft or as a new revision of `replacing`. A new revision keeps the rows the draft has, so a
    /// name typed into a template keeps the taps tried on it. Returns the draft's id, or nil, with the reason
    /// logged, when it does not build or go on show.
    func adopt(_ source: WidgetSource, replacing: WidgetID? = nil) async -> WidgetID? {
        do {
            switch try await engine.build(source, replacing: replacing) {
            case .saved(let draft):
                return await show(draft, keepingRows: replacing != nil) ? draft : nil
            case .rejected(let line):
                log.error("adopt: the preview rejected it: \(line, privacy: .public)")
                return nil
            }
        } catch {
            log.error("adopt: \(error.message, privacy: .public)")
            return nil
        }
    }

    /// Proves the draft once more against the shared store and saves it there, replacing `editing` when the
    /// person refines a library widget. A rejection carries the line to repair the draft with. Nil when there
    /// is no draft. Throws when a store failed, which includes the shared store refusing writes in the
    /// background.
    func save(replacing editing: WidgetID?) async throws(EngineError) -> BuildOutcome? {
        guard let widget, let source = try engine.source(of: widget) else { return nil }
        return try await library.build(source, replacing: editing)
    }

    func perform(_ tap: Tap, input: [String: InputValue] = [:]) {
        do {
            try engine.perform(tap, input: input, at: redraws.clock.now())
        } catch {
            message = error.message
        }
        Task { await redraw() }
    }

    func showForm(for tap: Tap) {
        do {
            form = try engine.form(for: tap).map(ShownForm.init)
        } catch {
            message = error.message
        }
    }

    private func redraw() async {
        guard let widget, let drawn = await draw(widget) else { return }
        faces = drawn.faces
        redraws.schedule(drawn.changes)
    }

    /// The widget's faces in both families, and when the first of them changes. Every write happens on the main
    /// actor before the drawing that shows it starts, so the drawing started last reads the newest rows. Nil
    /// when a later drawing started, because this one is stale.
    private func draw(_ widget: WidgetID) async -> (faces: [Family: Face], changes: Date)? {
        drawings += 1
        let drawing = drawings
        let drawn = await engine.faces(of: widget, sizes: sizes, at: redraws.clock.now())
        return drawing == drawings ? drawn : nil
    }
}
