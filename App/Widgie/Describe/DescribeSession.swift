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

/// One describe flow: the person's latest turn, the build loop it starts on the preview's scratch engine, and Save.
/// A failed or cancelled turn never replaces the draft, so the person always keeps the last widget that worked.
@MainActor @Observable
final class DescribeSession: Identifiable {
    enum Phase: Equatable {
        /// Putting the widget the session starts from into the preview.
        case opening
        case composing
        case building(BuildStep)
        /// Proving the draft against the shared store.
        case saving
        case failed(Failure)
        case saved(WidgetID)
    }

    /// Why a turn or a save did not finish, in the words the person sees. Never a verdict line.
    enum Failure: Equatable {
        /// The model service gave no answer.
        case unreachable
        /// The model service answered with an error.
        case refused
        case gaveUp
        /// The shared store still rejected the draft after one repair turn.
        case unsaved
        /// iOS ended the background time before the build finished.
        case interrupted
        /// The store failed, which is not something rewording can fix.
        case broken
        /// The widget the session starts from could not be put into the preview, so there is nothing to refine.
        case unopened
        /// This build names no model service.
        case unavailable

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
    struct Turn {
        let words: String
        let image: Picture?
        var result: TurnResult
    }

    enum TurnResult: Equatable {
        case pending, accepted
        case failed(Failure)
        case cancelled
    }

    /// The work the last failure interrupted, for Try again: the latest turn, or Save.
    private enum Job {
        case turn
        case save
    }

    /// What the session starts from.
    private enum Origin {
        case nothing
        /// A library widget to refine, which Save replaces.
        case library(WidgetID)
        /// A widget that is not in the library yet, such as a filled template, which Save adds.
        case unsaved(WidgetSource)
    }

    private let origin: Origin
    let preview: Preview
    private(set) var phase: Phase
    /// The only exchange the screen shows.
    private(set) var latest: Turn?
    /// What the person asked for in the last accepted turn, which the repair on Save asks again. Nil until
    /// a turn is accepted.
    private(set) var acceptedWords: String?
    private(set) var buildStarted = Date.now

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
    private var work: Task<Void, Never>?
    private var failedJob: Job?
    private var background = UIBackgroundTaskIdentifier.invalid
    private var expired = false

    convenience init(
        editing: WidgetID? = nil, model: (any WidgetModel)? = BridgeModel.configured, preview: Preview = Preview(),
        sharedWritesOpen: @escaping @MainActor () async -> Void = SharedWrites.open
    ) {
        self.init(
            origin: editing.map(Origin.library) ?? .nothing, model: model, preview: preview,
            sharedWritesOpen: sharedWritesOpen)
    }

    /// Starts on `draft` as if a turn had just made it, so the person's first message refines it.
    convenience init(
        draft: WidgetSource, model: (any WidgetModel)? = BridgeModel.configured, preview: Preview = Preview(),
        sharedWritesOpen: @escaping @MainActor () async -> Void = SharedWrites.open
    ) {
        self.init(origin: .unsaved(draft), model: model, preview: preview, sharedWritesOpen: sharedWritesOpen)
    }

    private init(
        origin: Origin, model: (any WidgetModel)?, preview: Preview,
        sharedWritesOpen: @escaping @MainActor () async -> Void
    ) {
        self.origin = origin
        self.model = model
        self.preview = preview
        self.sharedWritesOpen = sharedWritesOpen
        if case .nothing = origin { phase = .composing } else { phase = .opening }
    }

    var canSend: Bool {
        phase == .composing && pendingPhoto == nil
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
            fail(.unopened, job: nil)
        } else {
            phase = .composing
        }
    }

    /// Sends the composer, or `suggestion` when the person taps a suggestion.
    func send(_ suggestion: String? = nil) {
        let typed = (suggestion ?? words).trimmingCharacters(in: .whitespacesAndNewlines)
        let image = suggestion == nil ? picture : nil
        guard phase == .composing, suggestion != nil || pendingPhoto == nil, !typed.isEmpty || image != nil else {
            return
        }
        latest = Turn(words: typed.isEmpty ? "Make it look like this picture" : typed, image: image, result: .pending)
        if suggestion == nil {
            words = ""
            picture = nil
        }
        start(.turn)
    }

    func save() {
        guard draft != nil, phase == .composing else { return }
        start(.save)
    }

    /// Stops the build. The draft stays as it was before the turn.
    func cancel() {
        work?.cancel()
    }

    /// Runs again whatever the failure interrupted.
    func retry() {
        guard case .failed = phase, let job = failedJob else { return }
        start(job)
    }

    /// Leaves the failure screen. After a give-up the words go back in the composer to say another way.
    func dismissFailure() {
        guard case .failed(let failure) = phase else { return }
        if failure == .gaveUp, failedJob == .turn, words.isEmpty, let latest {
            words = latest.words
            picture = latest.image
        }
        failedJob = nil
        phase = .composing
    }

    /// Leaves `composing` or `failed` before it returns, so a second tap finds the guards closed.
    private func start(_ job: Job) {
        guard let model else {
            if job == .turn { latest?.result = .failed(.unavailable) }
            fail(.unavailable, job: nil)
            return
        }
        failedJob = nil
        switch job {
        case .turn:
            latest?.result = .pending
            begin(.writing(attempt: 1))
        case .save:
            phase = .saving
        }
        work = Task {
            switch job {
            case .turn: await runTurn(model: model)
            case .save: await runSave(model: model)
            }
        }
    }

    private func runTurn(model: some WidgetModel) async {
        guard let turn = latest else { return }
        let result = await loop(turn.words, image: turn.image?.attachment, replacing: draft, model: model)
        latest?.result = result
        if result == .accepted { acceptedWords = turn.words }
        if case .failed(let failure) = result {
            fail(failure, job: .turn)
        } else {
            phase = .composing
        }
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
            begin(.repairing(attempt: 1, line: line))
            switch await loop(
                acceptedWords ?? "Keep this widget as it is.", replacing: draft, repairing: line, model: model)
            {
            case .accepted:
                phase = .saving
                outcome = await saveToLibrary()
            case .failed(let failure):
                return fail(failure, job: .save)
            case .cancelled, .pending:
                phase = .composing
                return
            }
        }
        switch outcome {
        case .saved(let id)?: phase = .saved(id)
        case .rejected?: fail(.unsaved, job: nil)
        case nil: fail(.broken, job: .save)
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

    /// One run of the build loop on the scratch engine, shown on the draft when it is accepted.
    private func loop(
        _ words: String, image: Attachment? = nil, replacing: WidgetID?, repairing line: String? = nil,
        model: some WidgetModel
    ) async -> TurnResult {
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
                self.phase = .building(step)
            }
            switch outcome {
            case .accepted(let id, let attempts):
                if await preview.show(id) {
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

    private func fail(_ failure: Failure, job: Job?) {
        failedJob = job
        phase = .failed(failure)
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
        work?.cancel()
        endBackground()
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }
}

extension BuildStep {
    /// The line the build screen shows for this step.
    var title: String {
        switch self {
        case .writing: "Writing your widget"
        case .checking: "Checking it fits"
        case .repairing(let attempt, _): "Fixing a problem (\(attempt) of \(Engine.maxBuildAttempts))"
        }
    }
}
