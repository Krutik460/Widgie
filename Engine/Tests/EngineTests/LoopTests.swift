import Foundation
import Synchronization
import Testing
import WidgetBuilder
import WidgetEngine

/// The build loop against a scripted model: what it sends the model, what it saves, and what it reports.
@Suite struct LoopTests {
    let good = document(look: counterLook())
    let withReference = document(
        look: counterLook(
            "{ type: 'image', asset: 'reference', frame: { maxWidth: 'infinity', maxHeight: 'infinity' } }",
            extra: "{ type: 'text', value: String(ctx.data.n), color: '#FFFFFF', lineLimit: 1 },"),
        assets: ["reference": ["about": "the person's picture"]])

    @Test func aGoodFirstReplyIsAcceptedInOneAttemptAndTheWidgetIsSaved() async throws {
        let scratch = Scratch()
        let model = ScriptedModel([.reply(fenced(good))])
        var steps: [BuildStep] = []
        let outcome = try await scratch.engine.build("a tap counter", model: model) { steps.append($0) }
        guard case .accepted(let id, attempts: 1) = outcome else {
            Issue.record("expected acceptance in one attempt, got \(outcome)")
            return
        }
        #expect(try scratch.engine.widgets().map(\.id) == [id])
        #expect(try scratch.engine.widgets().map(\.name) == ["Counter"])
        #expect(scratch.commits == 1)
        #expect(model.requests == [ModelRequest(words: "a tap counter")])
        #expect(steps == [.writing(attempt: 1), .checking(attempt: 1)])
    }

    @Test func twoBadRepliesThenAGoodOneAreAcceptedInThreeAttemptsAndEachRepairCarriesThePreviousDocumentAndItsLine()
        async throws
    {
        let blank = "small, empty: the render is blank; check colors against the background"
        let cut = try await Scratch().line(Broken.cutsText)
        let scratch = Scratch()
        let model = ScriptedModel([.reply(fenced(Broken.blank)), .reply(fenced(Broken.cutsText)), .reply(fenced(good))])
        var steps: [BuildStep] = []
        let outcome = try await scratch.engine.build("a tap counter", model: model) { steps.append($0) }
        guard case .accepted(let id, attempts: 3) = outcome else {
            Issue.record("expected acceptance in three attempts, got \(outcome)")
            return
        }
        #expect(try scratch.engine.widgets().map(\.id) == [id])
        #expect(scratch.commits == 1)
        #expect(
            model.requests == [
                ModelRequest(words: "a tap counter"),
                ModelRequest(words: "a tap counter", repair: Repair(document: text(Broken.blank), line: blank)),
                ModelRequest(words: "a tap counter", repair: Repair(document: text(Broken.cutsText), line: cut)),
            ])
        #expect(
            steps == [
                .writing(attempt: 1), .checking(attempt: 1), .repairing(attempt: 2, line: blank),
                .checking(attempt: 2), .repairing(attempt: 3, line: cut), .checking(attempt: 3),
            ])
    }

    @Test func threeBadRepliesGiveUpWithTheLastLineAndNothingIsSaved() async throws {
        let spills = try await Scratch().line(Broken.spills)
        let scratch = Scratch()
        let model = ScriptedModel([
            .reply(fenced(Broken.blank)), .reply(fenced(Broken.cutsText)), .reply(fenced(Broken.spills)),
        ])
        let outcome = try await scratch.engine.build("a tap counter", model: model)
        #expect(outcome == .gaveUp(lastLine: spills, attempts: 3))
        #expect(model.requests.count == 3)
        #expect(try scratch.engine.widgets().isEmpty)
        #expect(scratch.commits == 0)
    }

    @Test @MainActor func aMainActorCallerSetsItsStateFromEveryStepInOrderBeforeTheOutcomeReturns() async throws {
        let blank = try await Scratch().line(Broken.blank)
        let scratch = Scratch()
        let screen = Screen()
        let model = ScriptedModel([.reply(fenced(Broken.blank)), .reply(fenced(good))])
        let outcome = try await scratch.engine.build("a tap counter", model: model) { screen.steps.append($0) }
        #expect(outcome == .accepted(try #require(try scratch.engine.widgets().first).id, attempts: 2))
        #expect(
            screen.steps == [
                .writing(attempt: 1), .checking(attempt: 1), .repairing(attempt: 2, line: blank), .checking(attempt: 2),
            ])
    }

    @Test @MainActor func aRefineSendsCurrentAndTheAcceptedWidgetKeepsItsRows() async throws {
        let scratch = Scratch()
        let water = try fixture("water")
        let id = try await scratch.build(water)
        for _ in 0..<3 {
            try scratch.engine.perform(try button("drink", on: await scratch.face(id)).tap, at: morning)
        }
        let current = text(try #require(try scratch.engine.source(of: id)))
        let bluer = WidgetSource(json: Data(text(water).replacing("#0B2A3C", with: "#1B3A8C").utf8))
        let model = ScriptedModel([.reply(fenced(bluer))])

        let outcome = try await scratch.engine.build("make it blue", replacing: id, model: model)
        #expect(outcome == .accepted(id, attempts: 1))
        #expect(model.requests == [ModelRequest(words: "make it blue", current: current)])
        #expect(try scratch.engine.history(of: id).count == 2)
        #expect(
            picture(await scratch.face(id))
                .looksLike(try await expected(bluer, rows: #"{"glasses": [{"daysAgo": 0, "repeat": 3}]}"#)))
    }

    @Test func aRepairDuringARefineStillSendsCurrent() async throws {
        let blank = try await Scratch().line(Broken.blank)
        let scratch = Scratch()
        let id = try await scratch.build(good)
        let current = text(try #require(try scratch.engine.source(of: id)))
        let model = ScriptedModel([.reply(fenced(Broken.blank)), .reply(fenced(good))])

        let outcome = try await scratch.engine.build("make it blue", replacing: id, model: model)
        #expect(outcome == .accepted(id, attempts: 2))
        #expect(
            model.requests == [
                ModelRequest(words: "make it blue", current: current),
                ModelRequest(
                    words: "make it blue", current: current, repair: Repair(document: text(Broken.blank), line: blank)),
            ])
    }

    @Test func aReplyWithProseAroundTheFenceOrTwoFencesGivesTheDocumentThePythonHarnessTakes() throws {
        struct Case: Decodable {
            let name: String
            let reply: String
            let document: String
        }
        let file = engineDirectory.appending(path: "Evals/testdata/extract.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: file))
        #expect(cases.contains { $0.name == "a json fence with prose around it" })
        #expect(cases.contains { $0.name == "the json fence wins over a longer fence of another kind" })
        for item in cases {
            let extracted = extractDocument(item.reply)
            #expect(
                Array(extracted.unicodeScalars) == Array(item.document.unicodeScalars),
                "\(item.name): got \(extracted.debugDescription)")
        }
    }

    @Test func aLoopStartedWithRepairingSendsTheStoredDocumentAndThatLineOnItsFirstCall() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(good)
        let stored = text(try #require(try scratch.engine.source(of: id)))
        let line = "table \"taps\" holds number cells; keep the kind"
        let model = ScriptedModel([.reply(fenced(good))])
        var steps: [BuildStep] = []

        let outcome = try await scratch.engine.build(
            "a tap counter", replacing: id, repairing: line, model: model
        ) { steps.append($0) }
        #expect(outcome == .accepted(id, attempts: 1))
        #expect(
            model.requests == [
                ModelRequest(words: "a tap counter", current: stored, repair: Repair(document: stored, line: line))
            ])
        #expect(steps == [.repairing(attempt: 1, line: line), .checking(attempt: 1)])
    }

    @Test func aCancelDuringTheModelCallSavesNothing() async throws {
        let scratch = Scratch()
        let model = StalledModel(then: .success(fenced(good)))
        let task = Task { try await scratch.engine.build("a tap counter", model: model) }
        await model.started()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try scratch.engine.widgets().isEmpty)
        #expect(scratch.commits == 0)
    }

    @Test func aModelErrorThrownAfterCancellationComesOutAsCancellationError() async throws {
        let scratch = Scratch()
        let model = StalledModel(then: .failure(URLError(.cancelled)))
        let task = Task { try await scratch.engine.build("a tap counter", model: model) }
        await model.started()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try scratch.engine.widgets().isEmpty)
    }

    @Test func aTransportErrorIsThrownAndDoesNotUseAnAttempt() async throws {
        let scripts: [[ScriptedModel.Answer]] = [
            [.reply(fenced(Broken.blank)), .down, .reply(fenced(good))],
            [.reply(fenced(Broken.blank)), .reply(fenced(Broken.cutsText)), .down],
        ]
        for script in scripts {
            let scratch = Scratch()
            let model = ScriptedModel(script)
            await #expect(throws: ServiceDown.self) { try await scratch.engine.build("a tap counter", model: model) }
            #expect(model.requests.count == script.firstIndex(of: .down).map { $0 + 1 })
            #expect(try scratch.engine.widgets().isEmpty)
        }
    }

    @Test func anAttachedImageReachesTheSavedWidgetOnlyWhenTheDocumentDeclaresReference() async throws {
        let attachment = Attachment(mime: "image/png", bytes: photo(300, 200))
        let cases: [(WidgetSource, kept: [String: Data])] = [
            (withReference, ["reference": attachment.bytes]), (good, [:]),
        ]
        for (source, kept) in cases {
            let scratch = Scratch()
            let model = ScriptedModel([.reply(fenced(source))])
            let outcome = try await scratch.engine.build("like this picture", image: attachment, model: model)
            guard case .accepted(let id, attempts: 1) = outcome else {
                Issue.record("expected acceptance in one attempt, got \(outcome)")
                continue
            }
            #expect(model.requests.map(\.image) == [attachment])
            #expect(try scratch.engine.source(of: id)?.images == kept)
        }
    }

    @Test func theAttachedPictureGoesWithEveryRepairRequest() async throws {
        let attachment = Attachment(mime: "image/png", bytes: photo(300, 200))
        let scratch = Scratch()
        let model = ScriptedModel([.reply(fenced(Broken.blank)), .reply(fenced(Broken.cutsText)), .reply(fenced(good))])
        let outcome = try await scratch.engine.build("like this picture", image: attachment, model: model)
        guard case .accepted(_, attempts: 3) = outcome else {
            Issue.record("expected acceptance in three attempts, got \(outcome)")
            return
        }
        #expect(model.requests.map { $0.repair != nil } == [false, true, true])
        #expect(model.requests.map(\.image) == [attachment, attachment, attachment])
    }

    @Test func aRefineThatSendsNoPictureKeepsTheStoredReference() async throws {
        let bytes = photo(300, 200)
        let scratch = Scratch()
        let id = try await scratch.build(WidgetSource(json: withReference.json, images: ["reference": bytes]))
        let bluer = WidgetSource(json: Data(text(withReference).replacing("#102030", with: "#1B3A8C").utf8))
        let model = ScriptedModel([.reply(fenced(bluer))])

        let outcome = try await scratch.engine.build("make it blue", replacing: id, model: model)
        #expect(outcome == .accepted(id, attempts: 1))
        #expect(model.requests.map(\.image) == [nil])
        #expect(try scratch.engine.history(of: id).count == 2)
        #expect(try scratch.engine.source(of: id)?.images == ["reference": bytes])
    }

    @Test func aRequestEncodesToTheShapeTheBridgeReads() throws {
        let full = ModelRequest(
            words: "make it blue", image: Attachment(mime: "image/png", bytes: Data([1, 2, 3])), current: "{}",
            repair: Repair(document: "{\"name\": 1}", line: "missing \"look\""))
        let wire: [String: Any] = [
            "words": "make it blue", "image": ["mime": "image/png", "base64": "AQID"], "current": "{}",
            "repair": ["document": "{\"name\": 1}", "line": "missing \"look\""],
        ]
        #expect(try object(full) == wire as NSDictionary)
        #expect(try object(ModelRequest(words: "a water tracker")) == ["words": "a water tracker"] as NSDictionary)
        #expect(try JSONDecoder().decode(ModelRequest.self, from: JSONEncoder().encode(full)) == full)
    }

    private func object(_ request: ModelRequest) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary)
    }
}

/// A reply as a model writes one: a sentence, the document in a `json` fence, and another sentence.
private func fenced(_ source: WidgetSource) -> String {
    "Here is your widget.\n\n```json\n\(text(source))\n```\n\nTap plus to count."
}

private func text(_ source: WidgetSource) -> String { String(decoding: source.json, as: UTF8.self) }

/// Answers from a script, one entry per call, and keeps every request it got.
private final class ScriptedModel: WidgetModel {
    enum Answer: Sendable, Equatable {
        case reply(String)
        case down
    }

    private let state: Mutex<(answers: [Answer], requests: [ModelRequest])>

    init(_ answers: [Answer]) { state = Mutex((answers, [])) }

    var requests: [ModelRequest] { state.withLock { $0.requests } }

    func reply(to request: ModelRequest) async throws -> String {
        let answer = state.withLock { state -> Answer? in
            state.requests.append(request)
            return state.answers.isEmpty ? nil : state.answers.removeFirst()
        }
        switch answer {
        case .reply(let text): return text
        case .down: throw ServiceDown()
        case nil:
            Issue.record("the model was called more often than the script allows")
            throw ServiceDown()
        }
    }
}

private struct ServiceDown: Error {}

/// Waits for its task to be cancelled, then answers anyway: with a reply, as a model that ignores cancellation
/// does, or with an error, as a cancelled URLSession throws `URLError(.cancelled)`.
private final class StalledModel: WidgetModel {
    let answer: Result<String, URLError>
    private let calls = AsyncStream.makeStream(of: Void.self)

    init(then answer: Result<String, URLError>) { self.answer = answer }

    func started() async {
        for await _ in calls.stream { return }
    }

    func reply(to request: ModelRequest) async throws -> String {
        calls.continuation.yield()
        try? await Task.sleep(for: .seconds(60))
        return try answer.get()
    }
}

/// What a describe screen holds: main-actor state that the loop's progress sets.
@MainActor private final class Screen {
    var steps: [BuildStep] = []
}
