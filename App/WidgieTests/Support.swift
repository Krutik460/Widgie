import Foundation
import Synchronization
import Testing
import WidgetBuilder
import WidgetEngine

@testable import Widgie

/// A model that answers from a script, recording each request. A reply can run `before` first, on the
/// model's own task, to act at a known point in the build.
final class ScriptedModel: WidgetModel {
    struct Answer: Sendable {
        let reply: String
        var before: (@Sendable () async -> Void)?
    }

    private let state: Mutex<(answers: [Answer], requests: [ModelRequest])>

    init(_ answers: [Answer]) { state = Mutex((answers, [])) }

    var requests: [ModelRequest] { state.withLock { $0.requests } }

    func reply(to request: ModelRequest) async throws -> String {
        let answer = state.withLock { state -> Answer? in
            state.requests.append(request)
            return state.answers.isEmpty ? nil : state.answers.removeFirst()
        }
        guard let answer else {
            Issue.record("the model was called more often than the script allows")
            throw URLError(.badServerResponse)
        }
        await answer.before?()
        return answer.reply
    }
}

/// A counter widget that passes every check, as a fenced model reply.
func counter(background: String = "#102030", fields: [String: String] = [:]) -> ScriptedModel.Answer {
    ScriptedModel.Answer(reply: "```json\n\(counterDocument(background: background, fields: fields))\n```")
}

/// The counter's document. `background` paints it and `fields` are its one table's fields.
func counterDocument(background: String = "#102030", fields: [String: String] = [:]) -> String {
    let look = """
        function render(ctx) {
          return { type: 'vstack', spacing: 8, padding: 14, frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
            widgetBackground: '\(background)',
            children: [
              { type: 'text', value: String(ctx.data.n), size: 30, weight: 'bold', color: '#FFFFFF', lineLimit: 1, minScale: 0.5 },
              { type: 'button', action: 'add', children: [{ type: 'symbol', name: 'plus', size: 20, color: '#FFFFFF' }] },
            ] };
        }
        """
    let document: [String: Any] = [
        "name": "Counter", "tables": ["taps": ["fields": fields]],
        "queries": ["n": ["count": "taps", "window": "all"]], "actions": ["add": ["insert": "taps"]],
        "samples": ["some": ["taps": [["daysAgo": 0, "repeat": 2]]]], "look": look,
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: document), as: UTF8.self)
}

/// A reply `build` always rejects: it has no look.
let unbuildable = ScriptedModel.Answer(reply: #"{"name": "Counter"}"#)

/// An engine standing in for the shared store, on a folder of its own that goes when this does.
final class SharedStore: Sendable {
    let directory = FileManager.default.temporaryDirectory.appending(path: "app-tests-\(UUID().uuidString)")
    let engine: Engine

    init() { engine = Engine(directory: directory) }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func build(_ document: String, replacing: WidgetID? = nil) async throws -> WidgetID {
        let outcome = try await engine.build(WidgetSource(json: Data(document.utf8)), replacing: replacing)
        guard case .saved(let id) = outcome else {
            Issue.record("expected the widget to save, got \(outcome)")
            throw Unexpected()
        }
        return id
    }
}

struct Unexpected: Error {}

/// Waits, a few seconds at most, until `condition` holds.
@MainActor func until(_ condition: () -> Bool, _ comment: Comment) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record(comment)
    throw Unexpected()
}

extension DescribeSession.Turn {
    var accepted: Bool {
        if case .accepted = result { true } else { false }
    }
}

extension DescribeSession {
    /// Whether the session is waiting on the person, after a turn or a save finished.
    var settled: Bool {
        switch phase {
        case .composing, .failed, .saved: true
        case .opening, .building, .saving: false
        }
    }
}

/// A wall clock that moves only when a test moves it, for the waits of `Redraws`.
final class TestClock: Sendable {
    private struct Sleeper {
        let id: UUID
        let until: Date
        let wake: CheckedContinuation<Void, any Error>
    }

    private let state: Mutex<(now: Date, sleepers: [Sleeper])>

    init(_ now: Date) { state = Mutex((now, [])) }

    var now: Date { state.withLock { $0.now } }

    /// The soonest moment something waits for, nil when nothing waits.
    var soonest: Date? { state.withLock { $0.sleepers.map(\.until).min() } }

    var clock: FaceClock {
        FaceClock(now: { self.now }, sleep: { try await self.sleep(until: $0) })
    }

    /// Moves the clock to `date` and wakes every wait for a moment up to it.
    func move(to date: Date) {
        let woken = state.withLock { state in
            state.now = date
            let woken = state.sleepers.filter { $0.until <= date }
            state.sleepers.removeAll { $0.until <= date }
            return woken
        }
        for sleeper in woken { sleeper.wake.resume() }
    }

    private func sleep(until date: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, any Error>) in
                let early: (any Error)?? = state.withLock { state in
                    if Task.isCancelled { return .some(CancellationError()) }
                    if date <= state.now { return .some(nil) }
                    state.sleepers.append(Sleeper(id: id, until: date, wake: wake))
                    return nil
                }
                switch early {
                case .some(let error?): wake.resume(throwing: error)
                case .some(nil): wake.resume()
                case nil: break
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.wake.resume(throwing: CancellationError())
        }
    }
}

/// Stands in for `SharedWrites.open`. The first call lets the save through and then the app goes to the
/// background, so the shared store refuses the write as suspended. The app comes back either when the test
/// releases the second call, or as the second call starts, so the retry never waits.
@MainActor final class SuspendingGate {
    enum ComesBack {
        case whenReleased
        case asTheRetryStarts
    }

    let comesBack: ComesBack
    private(set) var waiting = false
    private var calls = 0
    private var resume: CheckedContinuation<Void, Never>?

    init(comesBack: ComesBack) { self.comesBack = comesBack }

    func open() async {
        calls += 1
        guard calls > 1 else {
            Engine.suspend()
            return
        }
        if comesBack == .whenReleased {
            waiting = true
            await withCheckedContinuation { resume = $0 }
        }
        Engine.resume()
    }

    func release() {
        resume?.resume()
        resume = nil
    }
}
