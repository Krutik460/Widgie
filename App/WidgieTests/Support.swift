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

extension DescribeSession {
    /// Whether the session is waiting on the person, after a turn or a save finished.
    var settled: Bool {
        switch phase {
        case .composing, .failed, .saved: true
        case .opening, .building, .saving: false
        }
    }
}
