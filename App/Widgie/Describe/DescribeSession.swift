import Foundation
import OSLog
import Observation
import UIKit
import WidgetBuilder
import WidgetEngine
import WidgetHosting

/// Each build's steps and timing, for the perf numbers: `log stream --predicate 'category == "describe"'`.
private let log = Logger(subsystem: "dev.krutikpatel.widgie", category: "describe")

/// One describe flow: the person's turns, the build loop they start on the preview's scratch engine, and Save.
/// A failed or cancelled turn never replaces the draft, so the person always keeps the last widget that worked.
@MainActor @Observable
final class DescribeSession: Identifiable {
    enum Phase: Equatable {
        /// Copying the library widget being refined into the preview.
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
        case unreachable
        case gaveUp
        /// iOS ended the background time before the build finished.
        case interrupted
        /// The store failed, which is not something rewording can fix.
        case broken
        /// This build names no model service.
        case unavailable

        var title: String {
            switch self {
            case .unreachable: "Couldn't reach the widget builder."
            case .gaveUp: "I couldn't make that work."
            case .interrupted: "The build stopped in the background."
            case .broken: "Something went wrong on this phone."
            case .unavailable: "Building widgets is not available in this build"
            }
        }

        var detail: String? {
            switch self {
            case .unreachable: "Check that the bridge is running."
            case .gaveUp: "Try saying it another way."
            case .interrupted: "Keep Widgie open while it paints, then try again."
            case .broken: "Try again in a moment."
            case .unavailable: nil
            }
        }
    }

    struct Turn: Identifiable {
        let id = UUID()
        let words: String
        let image: Attachment?
        var result: TurnResult
    }

    enum TurnResult: Equatable {
        case pending, accepted
        case failed(Failure)
        case cancelled
    }

    /// The work the last failure interrupted, for Try again.
    private enum Job {
        case turn(Int)
        case save
    }

    /// The library widget being refined, nil when creating a new one.
    let editing: WidgetID?
    let preview: Preview
    private(set) var phase: Phase
    private(set) var turns: [Turn] = []
    /// The steps of the build on show, oldest first.
    private(set) var steps: [BuildStep] = []
    private(set) var buildStarted = Date.now
    /// Whether the person has tapped the draft yet, which retires the hint to try it.
    private(set) var tried = false

    var words = ""
    var picture: Attachment?

    /// The last accepted widget in the preview's scratch engine.
    var draft: WidgetID? { preview.widget }

    private let model: (any WidgetModel)?
    private var work: Task<Void, Never>?
    private var failedJob: Job?
    private var background = UIBackgroundTaskIdentifier.invalid
    private var expired = false

    init(editing: WidgetID? = nil, model: (any WidgetModel)? = BridgeModel.configured) {
        self.editing = editing
        self.model = model
        preview = Preview()
        phase = editing == nil ? .composing : .opening
    }

    var canSend: Bool {
        phase == .composing && (!words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || picture != nil)
    }

    func open() async {
        guard let editing, phase == .opening else { return }
        _ = await preview.copy(editing)
        phase = .composing
    }

    /// Sends the composer, or `suggestion` when the person taps a suggestion.
    func send(_ suggestion: String? = nil) {
        let typed = (suggestion ?? words).trimmingCharacters(in: .whitespacesAndNewlines)
        let image = suggestion == nil ? picture : nil
        guard phase == .composing, !typed.isEmpty || image != nil else { return }
        turns.append(
            Turn(words: typed.isEmpty ? "Make it look like this picture" : typed, image: image, result: .pending))
        if suggestion == nil {
            words = ""
            picture = nil
        }
        start(.turn(turns.count - 1))
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

    /// Closes the failure banner. After a give-up the words go back in the composer to say another way.
    func dismissFailure() {
        guard case .failed(let failure) = phase else { return }
        if failure == .gaveUp, case .turn(let index) = failedJob, words.isEmpty {
            words = turns[index].words
            picture = turns[index].image
        }
        failedJob = nil
        phase = .composing
    }

    func perform(_ tap: Tap, input: [String: InputValue] = [:]) {
        tried = true
        preview.perform(tap, input: input)
    }

    private func start(_ job: Job) {
        guard let model else {
            if case .turn(let index) = job { turns[index].result = .failed(.unavailable) }
            fail(.unavailable, job: nil)
            return
        }
        failedJob = nil
        expired = false
        background = UIApplication.shared.beginBackgroundTask(withName: "Build widget") { [weak self] in
            MainActor.assumeIsolated { self?.expire() }
        }
        work = Task {
            switch job {
            case .turn(let index): await runTurn(index, model: model)
            case .save: await runSave(model: model)
            }
            endBackground()
        }
    }

    private func runTurn(_ index: Int, model: some WidgetModel) async {
        let turn = turns[index]
        turns[index].result = .pending
        begin(.writing(attempt: 1))
        let result = await loop(turn.words, image: turn.image, replacing: draft, model: model)
        turns[index].result = result
        if case .failed(let failure) = result {
            fail(failure, job: .turn(index))
        } else {
            phase = .composing
        }
    }

    /// Proves the draft against the shared store. A line only that store can give (a widget sharing the data,
    /// the kinds of cells already stored) becomes one repair turn on the scratch engine, then Save again.
    private func runSave(model: some WidgetModel) async {
        guard let draft else { return }
        phase = .saving
        var outcome = await preview.save(replacing: editing)
        if case .rejected(let line) = outcome {
            begin(.repairing(attempt: 1, line: line))
            let words = turns.last { $0.result == .accepted }?.words ?? "Keep this widget as it is."
            switch await loop(words, replacing: draft, repairing: line, model: model) {
            case .accepted:
                phase = .saving
                outcome = await preview.save(replacing: editing)
            case .failed(let failure):
                return fail(failure, job: .save)
            case .cancelled, .pending:
                phase = .composing
                return
            }
        }
        switch outcome {
        case .saved(let id): phase = .saved(id)
        case .rejected: fail(.gaveUp, job: .save)
        case nil: phase = .composing
        }
    }

    /// One run of the build loop on the scratch engine, shown on the draft when it is accepted.
    private func loop(
        _ words: String, image: Attachment? = nil, replacing: WidgetID?, repairing line: String? = nil,
        model: some WidgetModel
    ) async -> TurnResult {
        let before = replacing.flatMap { try? preview.engine.history(of: $0).first }
        let started = ContinuousClock.now
        func seconds() -> String { (ContinuousClock.now - started).formatted(.units(fractionalPart: .show(length: 2))) }
        do {
            let outcome = try await preview.engine.build(
                words, image: image, replacing: replacing, repairing: line, model: model
            ) { step in
                log.info("\(step.title, privacy: .public) at \(seconds(), privacy: .public)")
                if self.steps.last != step { self.steps.append(step) }
                self.phase = .building(step)
            }
            switch outcome {
            case .accepted(let id, let attempts) where !Task.isCancelled:
                await preview.show(id)
                log.info("accepted in \(attempts) attempts, preview shown at \(seconds(), privacy: .public)")
                return .accepted
            case .accepted:
                // Cancelled while the reply was being proved: put the draft back as the person last saw it.
                if let replacing, let before { try? preview.engine.restore(replacing, to: before) }
                return expired ? .failed(.interrupted) : .cancelled
            case .gaveUp:
                return .failed(.gaveUp)
            }
        } catch is CancellationError {
            return expired ? .failed(.interrupted) : .cancelled
        } catch is EngineError {
            return .failed(.broken)
        } catch {
            return .failed(.unreachable)
        }
    }

    private func begin(_ step: BuildStep) {
        steps = [step]
        buildStarted = .now
        phase = .building(step)
    }

    private func fail(_ failure: Failure, job: Job?) {
        failedJob = job
        phase = .failed(failure)
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
        case .repairing(let attempt, _): "Fixing a layout problem (\(attempt) of 3)"
        }
    }
}
