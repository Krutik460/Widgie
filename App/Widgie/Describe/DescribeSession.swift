import Foundation
import OSLog
import Observation
import PhotosUI
import SwiftUI
import UIKit
import WidgetBuilder
import WidgetEngine
import WidgetHosting

/// Each build's steps and timing, for the perf numbers: `log stream --predicate 'category == "describe"'`.
private let log = Logger(subsystem: "dev.krutikpatel.widgie", category: "describe")

/// One Make chat: every turn the person sends, the build loop each one starts on the preview's scratch engine, and
/// Save. A failed or cancelled turn never replaces the draft, so the person always keeps the last widget that worked.
@MainActor @Observable
final class DescribeSession {
    enum Phase: Equatable {
        /// Putting the widget the session starts from into the preview.
        case opening
        case composing
        /// A turn's build loop at this step.
        case building(BuildStep)
        /// Proving the draft against the shared store, and the repair turn that may take.
        case saving
        /// The work it interrupted decides where the chat shows it and what Try again runs.
        case failed(Failure, Work)
        case saved(WidgetID)
    }

    /// What a failure interrupted: putting the starting widget into the preview, the latest turn, or Save.
    enum Work: Equatable {
        case open, turn, save
    }

    /// Why a turn or a save did not finish, in the words the person sees. Never a verdict line.
    enum Failure: Equatable {
        /// The model service gave no answer.
        case unreachable
        /// The model service answered with an error.
        case refused
        case gaveUp
        /// The shared store still rejected the draft after one repair turn, or the repair gave up.
        case unsaved
        /// iOS ended the background time before the build finished.
        case interrupted
        /// The store failed, which is not something rewording can fix.
        case broken
        /// The widget the session starts from could not be put into the preview, so there is nothing to refine.
        case unopened
        /// This build names no model service.
        case unavailable

        /// Whether running the same work again can help. Rewording, a store that refused the draft, or a build without
        /// a model service cannot.
        var retryable: Bool {
            switch self {
            case .unreachable, .refused, .interrupted, .broken: true
            case .gaveUp, .unsaved, .unopened, .unavailable: false
            }
        }

        var title: String {
            switch self {
            case .unreachable: "Couldn’t reach the widget builder."
            case .refused: "The widget builder ran into a problem."
            case .gaveUp: "I couldn’t make that work."
            case .unsaved: "I couldn’t save this widget."
            case .interrupted: "The build stopped in the background."
            case .broken: "Something went wrong on this phone."
            case .unopened: "I couldn’t open that widget."
            case .unavailable: "Building widgets is not available in this build."
            }
        }
    }

    /// What the person asked, and how it went.
    struct Turn: Identifiable {
        let id: Int
        let words: String
        let image: Picture?
        /// The suggested change it sent, nil for the person's own words.
        let change: Changes.Change?
        var result: TurnResult

        var accepted: Bool {
            if case .accepted = result { true } else { false }
        }
    }

    enum TurnResult: Equatable {
        case pending
        /// The draft changed, and Widgie says so in `note`.
        case accepted(note: String)
        case failed(Failure)
        case cancelled
    }

    /// What the session starts from.
    enum Origin {
        case nothing
        /// A library widget to refine, which Save replaces.
        case library(WidgetID)
        /// A widget that is not in the library yet, such as a filled template, which Save adds.
        case unsaved(WidgetSource)
    }

    private let origin: Origin
    let preview: Preview
    private(set) var phase: Phase
    /// Every turn the person sent, oldest first.
    private(set) var turns: [Turn] = []
    /// Widgie's first line about the widget the session opened on, nil when it starts from nothing.
    private(set) var openingLine: String?
    private(set) var buildStarted = Date.now

    var latest: Turn? { turns.last }

    /// What the person asked for in the last accepted turn, which the repair on Save asks again.
    private var acceptedWords: String? {
        turns.last(where: \.accepted)?.words
    }

    var words = ""
    var picture: Picture?
    /// The photo picked for the composer while it loads. Sending waits for it, so the photo is never dropped.
    var pendingPhoto: PhotosPickerItem?

    /// The last accepted widget in the preview's scratch engine.
    var draft: WidgetID? { preview.widget }

    /// The library widget being refined, nil when creating a new one.
    var editing: WidgetID? {
        if case .library(let id) = origin { id } else { nil }
    }

    private let model: (any WidgetModel)?
    /// Returns once the shared store takes writes.
    private let sharedWritesOpen: @MainActor () async -> Void
    private var running: Task<Void, Never>?
    private var background = UIBackgroundTaskIdentifier.invalid
    private var expired = false

    /// A draft starts on its empty data, as the saved widget will, so a new pet tracker says "Not fed".
    init(
        _ origin: Origin = .nothing, model: (any WidgetModel)? = BridgeModel.configured,
        preview: Preview = Preview(startsEmpty: true),
        sharedWritesOpen: @escaping @MainActor () async -> Void = SharedWrites.open
    ) {
        self.origin = origin
        self.model = model
        self.preview = preview
        self.sharedWritesOpen = sharedWritesOpen
        if case .nothing = origin { phase = .composing } else { phase = .opening }
    }

    /// What putting another widget into Make in this session's place would cost.
    enum Replacement: Equatable {
        /// Nothing is lost: the session is empty or its widget is saved.
        case free
        /// A draft, or a build or opening under way, would be thrown away.
        case discards
        /// A save is under way, its repair turn included. It cannot be stopped and would land after a discard, so it
        /// has to finish first.
        case waits
    }

    var replacement: Replacement {
        switch phase {
        case .saved: .free
        case .saving: .waits
        case .opening, .building: .discards
        case .composing, .failed: changed ? .discards : .free
        }
    }

    /// Whether there is work to lose or save: any draft of a new widget, or an accepted change to a library widget.
    /// Save shows only then, so a library widget is never saved unchanged.
    var changed: Bool {
        if case .library = origin { acceptedWords != nil } else { draft != nil }
    }

    /// Nothing sent yet and nothing to start from, which the chat shows as its empty page.
    var blank: Bool {
        if case .nothing = origin { turns.isEmpty } else { false }
    }

    /// Waiting on the person: a new message or Save may go. A failure counts, so the person can say something else
    /// instead of acting on it, except one that left nothing to chat about.
    var ready: Bool {
        switch phase {
        case .composing: true
        case .failed(_, let work): work != .open
        case .opening, .building, .saving, .saved: false
        }
    }

    var canSend: Bool {
        ready && pendingPhoto == nil
            && (!words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || picture != nil)
    }

    func open() async {
        guard phase == .opening else { return }
        let shown: WidgetID?
        switch origin {
        case .nothing: return
        case .library(let id): shown = await preview.copy(id)
        case .unsaved(let source): shown = await preview.adopt(source)
        }
        if shown == nil {
            fail(.unopened, .open)
        } else {
            openingLine = "What should we change about \(preview.name ?? "this widget")?"
            phase = .composing
        }
    }

    /// The suggested changes whose turns landed, which the chips no longer offer.
    var usedChanges: Set<Changes.Change> {
        Set(turns.compactMap { $0.accepted ? $0.change : nil })
    }

    /// Sends the composer, or `suggestion` when the person taps an idea or `change`'s chip. Returns whether it went
    /// ahead, as `save` and `retry` do.
    @discardableResult func send(_ suggestion: String? = nil, change: Changes.Change? = nil) -> Bool {
        let typed = (suggestion ?? words).trimmingCharacters(in: .whitespacesAndNewlines)
        let image = suggestion == nil ? picture : nil
        guard ready, suggestion != nil || pendingPhoto == nil, !typed.isEmpty || image != nil else {
            return false
        }
        turns.append(
            Turn(
                id: turns.count, words: typed.isEmpty ? "Make it look like this picture" : typed, image: image,
                change: change, result: .pending))
        if suggestion == nil {
            words = ""
            picture = nil
        }
        start(.turn)
        return true
    }

    @discardableResult func save() -> Bool {
        guard changed, ready else { return false }
        start(.save)
        return true
    }

    /// Stops the build. The draft stays as it was before the turn.
    func cancel() {
        running?.cancel()
    }

    /// Runs again whatever the failure interrupted.
    @discardableResult func retry() -> Bool {
        guard case .failed(let failure, let work) = phase, failure.retryable, work != .open else { return false }
        start(work)
        return true
    }

    /// Takes the failure as read. After a give-up the words go back in the composer to say another way.
    func dismissFailure() {
        guard case .failed(let failure, let work) = phase, work != .open else { return }
        if failure == .gaveUp, work == .turn, words.isEmpty, let latest {
            words = latest.words
            picture = latest.image
        }
        phase = .composing
    }

    /// Leaves `composing` or `failed` before it returns, so a second tap finds the guards closed.
    private func start(_ job: Work) {
        guard let model else {
            if job == .turn { setLatest(.failed(.unavailable)) }
            fail(.unavailable, job)
            return
        }
        switch job {
        case .open: return
        case .turn:
            setLatest(.pending)
            begin(.writing(attempt: 1))
        case .save:
            phase = .saving
        }
        running = Task {
            switch job {
            case .open: return
            case .turn: await runTurn(model: model)
            case .save: await runSave(model: model)
            }
        }
    }

    private func setLatest(_ result: TurnResult) {
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].result = result
    }

    private func runTurn(model: some WidgetModel) async {
        guard let turn = latest else { return }
        let first = draft == nil
        let result = await loop(turn.words, image: turn.image?.attachment, replacing: draft, model: model)
        switch result {
        case .accepted:
            setLatest(.accepted(note: note(first: first)))
            phase = .composing
        case .failed(let failure):
            setLatest(.failed(failure))
            fail(failure, .turn)
        case .cancelled:
            setLatest(.cancelled)
            phase = .composing
        }
    }

    /// Widgie's words on an accepted turn. The app cannot read meaning from an AI-made widget, so they name it and
    /// say what to do with it, never what it shows.
    private func note(first: Bool) -> String {
        guard first else { return "Done. Anything else?" }
        return Speech.landed(preview.name ?? "your widget", buttons: preview.faces[.medium]?.hasButtons == true)
    }

    /// Proves the draft against the shared store. A line only that store can give (a widget sharing the data,
    /// the kinds of cells already stored) becomes one repair turn on the scratch engine, then Save again.
    private func runSave(model: some WidgetModel) async {
        guard let draft else {
            phase = .composing
            return
        }
        var outcome = await saveToLibrary()
        if case .rejected(let line)? = outcome {
            switch await loop(
                acceptedWords ?? "Keep this widget as it is.", replacing: draft, repairing: line, model: model)
            {
            case .accepted:
                outcome = await saveToLibrary()
            case .failed(let failure):
                return fail(failure == .gaveUp ? .unsaved : failure, .save)
            case .cancelled:
                phase = .composing
                return
            }
        }
        switch outcome {
        case .saved(let id)?: phase = .saved(id)
        case .rejected?: fail(.unsaved, .save)
        case nil: fail(.broken, .save)
        }
    }

    /// Proves the draft against the shared store and saves it there. That store takes no writes in the
    /// background, so a save it refuses as suspended waits for the app to come back, then saves. Nil when the
    /// store failed or there is no draft.
    private func saveToLibrary() async -> BuildOutcome? {
        while true {
            await sharedWritesOpen()
            do {
                return try await preview.save(replacing: editing)
            } catch let error where error.isSuspended {
                log.info("save met the background, waiting for the app to come back")
            } catch {
                log.error("save failed: \(error.message, privacy: .public)")
                return nil
            }
        }
    }

    private enum Run {
        case accepted, cancelled
        case failed(Failure)
    }

    /// One run of the build loop on the scratch engine, shown on the draft when it is accepted. A turn shows each
    /// step; a save's repair stays `saving`.
    private func loop(
        _ words: String, image: Attachment? = nil, replacing: WidgetID?, repairing line: String? = nil,
        model: some WidgetModel
    ) async -> Run {
        beginBackground()
        defer { endBackground() }
        var checkpoint: Checkpoint?
        if let replacing {
            do {
                checkpoint = try preview.engine.checkpoint(of: replacing)
            } catch {
                log.error("the draft could not be checkpointed: \(error.message, privacy: .public)")
                return .failed(.broken)
            }
        }
        let started = ContinuousClock.now
        func seconds() -> String { (ContinuousClock.now - started).formatted(.units(fractionalPart: .show(length: 2))) }
        do {
            let outcome = try await preview.engine.build(
                words, image: image, replacing: replacing, repairing: line, model: model
            ) { step in
                log.info("\(step.title, privacy: .public) at \(seconds(), privacy: .public)")
                if line == nil { self.phase = .building(step) }
            }
            switch outcome {
            case .accepted(let id, let attempts):
                // A library widget's draft reads a copy of its rows, which a change keeps where its tables keep
                // their data, as the saved widget will. A new widget's draft starts empty after every change.
                if await preview.show(id, keepingRows: editing != nil) {
                    log.info("accepted in \(attempts) attempts, preview shown at \(seconds(), privacy: .public)")
                    return .accepted
                }
                // The new draft never went on show: put the draft back as the person last saw it.
                if let checkpoint {
                    do {
                        try await preview.rollBack(to: checkpoint)
                    } catch {
                        log.error("the draft could not be put back: \(error.message, privacy: .public)")
                        return .failed(.broken)
                    }
                }
                guard Task.isCancelled else {
                    log.error("the new draft could not be shown")
                    return .failed(.broken)
                }
                return expired ? .failed(.interrupted) : .cancelled
            case .gaveUp(_, let attempts):
                log.info("gave up after \(attempts) attempts at \(seconds(), privacy: .public)")
                return .failed(.gaveUp)
            }
        } catch is CancellationError {
            return expired ? .failed(.interrupted) : .cancelled
        } catch let error as EngineError {
            log.error("the build failed: \(error.message, privacy: .public)")
            return .failed(.broken)
        } catch let error as URLError {
            log.error("the model service gave no answer: \(error.localizedDescription, privacy: .public)")
            return .failed(.unreachable)
        } catch {
            log.error("the model service failed: \(String(describing: error), privacy: .public)")
            return .failed(.refused)
        }
    }

    private func begin(_ step: BuildStep) {
        buildStarted = .now
        phase = .building(step)
    }

    private func fail(_ failure: Failure, _ work: Work) {
        phase = .failed(failure, work)
    }

    /// The build keeps going in the background for as long as iOS allows. One build runs at a time, so one
    /// slot holds its task.
    private func beginBackground() {
        expired = false
        background = UIApplication.shared.beginBackgroundTask(withName: "Build widget") { [weak self] in
            MainActor.assumeIsolated { self?.expire() }
        }
    }

    private func expire() {
        expired = true
        running?.cancel()
        endBackground()
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }
}

extension BuildStep {
    /// The line Widgie says while the build is at this step.
    var title: String {
        switch self {
        case .writing: "Writing your widget"
        case .checking: "Checking it fits"
        case .repairing(let attempt, _): "Fixing a problem (\(attempt) of \(Engine.maxBuildAttempts))"
        }
    }
}
