import Foundation
import OSLog
import Observation
import WidgetBuilder
import WidgetEngine
import WidgetHosting

private let log = Logger(subsystem: "dev.krutikpatel.widgie", category: "describe")

/// A draft's live face, drawn from a scratch engine of its own. The draft never reaches the shared store, so
/// the home screen widget picker cannot list it before Save, and taps write to sample rows, never the
/// person's. Releasing the preview deletes the draft.
@MainActor @Observable
final class Preview {
    /// Where the draft lives. The build loop runs on this engine, so every accepted attempt saves only here.
    let engine = Engine.scratch()

    /// The draft on show, nil before the first one.
    private(set) var widget: WidgetID?
    /// The data the face is drawn from: `.empty`, then each sample.
    private(set) var states: [DataState] = []
    private(set) var state: DataState = .empty
    private(set) var faces: [Family: Face] = [:]
    var form: InputForm?
    var message: String?

    /// Shows a draft the scratch engine holds. A new draft starts on its first sample, so it does not look
    /// empty. Showing the same draft again after a refinement keeps the chosen state when the new revision
    /// still has it, and loads it afresh. Nothing changes on show until the state has loaded.
    func show(_ widget: WidgetID) async {
        do {
            let states = [.empty] + (try engine.samples(of: widget)).map(DataState.sample)
            let kept = self.widget == widget && states.contains(self.state)
            let state = kept ? self.state : states.dropFirst().first ?? .empty
            try engine.load(state, into: widget)
            self.widget = widget
            self.states = states
            self.state = state
        } catch {
            message = error.message
        }
        await redraw()
    }

    func select(_ state: DataState) async {
        guard let widget else { return }
        do {
            try engine.load(state, into: widget)
            self.state = state
        } catch {
            message = error.message
        }
        await redraw()
    }

    /// Copies a library widget into the scratch engine and shows it with its first sample, so refining it
    /// never shows or writes the person's rows. Returns the draft's id in the scratch engine, or nil, with the
    /// reason logged, when the widget is gone or cannot be copied.
    func copy(_ saved: WidgetID) async -> WidgetID? {
        do {
            guard let source = try Hosting.engine.source(of: saved) else {
                log.error("copy: \(saved.rawValue, privacy: .public) is no longer in the library")
                return nil
            }
            switch try await engine.build(source) {
            case .saved(let draft):
                await show(draft)
                return draft
            case .rejected(let line):
                log.error("copy: the preview rejected it: \(line, privacy: .public)")
                return nil
            }
        } catch {
            log.error("copy: \(error.message, privacy: .public)")
            return nil
        }
    }

    /// Proves the draft once more against the shared store and saves it there, replacing `editing` when the
    /// person refines a library widget. A rejection carries the line to repair the draft with. Nil when there
    /// is no draft. Throws when a store failed, which includes the shared store refusing writes in the
    /// background.
    func save(replacing editing: WidgetID?) async throws(EngineError) -> BuildOutcome? {
        guard let widget, let source = try engine.source(of: widget) else { return nil }
        return try await Hosting.engine.build(source, replacing: editing)
    }

    func perform(_ tap: Tap, input: [String: InputValue] = [:]) {
        do {
            try engine.perform(tap, input: input)
        } catch {
            message = error.message
        }
        Task { await redraw() }
    }

    func showForm(for tap: Tap) {
        do {
            form = try engine.form(for: tap)
        } catch {
            message = error.message
        }
    }

    private var redraws = 0

    /// Every write happens on the main actor before the redraw that shows it starts, so the redraw started
    /// last reads the newest rows. An earlier one that finishes after it is stale and is dropped.
    private func redraw() async {
        guard let widget else { return }
        redraws += 1
        let redraw = redraws
        var faces: [Family: Face] = [:]
        for family in Family.allCases {
            faces[family] = await engine.faces(for: widget, family: family, size: family.standardSize, from: .now)
                .current
        }
        if redraw == redraws { self.faces = faces }
    }
}
