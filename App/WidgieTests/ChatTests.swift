import Foundation
import Testing
import WidgetBuilder
import WidgetEngine

@testable import Widgie

/// Make's chat against a scripted model, a temporary shared store, and the preview's scratch engine. Serialized for
/// the same reason as `DescribeSessionTests`: a save that meets a suspended store reaches every store in the process.
@MainActor @Suite(.serialized) struct ChatTests {
    let shared = SharedStore()

    /// A chat whose sessions answer from `answers` in turn, one script per session.
    private func chat(
        _ origin: DescribeSession.Origin = .nothing, answers: [[ScriptedModel.Answer]] = [],
        close: (() -> Void)? = nil, gate: SuspendingGate? = nil
    ) -> Chat {
        var scripts = answers
        return Chat(origin, close: close) { [shared] origin in
            let model = ScriptedModel(scripts.isEmpty ? [] : scripts.removeFirst())
            return DescribeSession(
                origin, model: model, preview: Preview(library: shared.engine),
                sharedWritesOpen: { await gate?.open() })
        }
    }

    private func petFed(_ name: String = "Mochi") throws -> WidgetSource {
        let template = try #require(Template.catalog().first { $0.id == "pet-fed" })
        return try template.source(filling: ["pet": name])
    }

    private func send(_ words: String, in session: DescribeSession) async throws {
        session.words = words
        session.send()
        try await until({ session.settled }, "the turn never finished")
    }

    // MARK: Turns

    @Test func everyTurnStaysInTheThreadInOrderWithWidgiesNote() async throws {
        let session = chat(answers: [[counter(), counter(background: "#1B3A8C")]]).session
        try await send("a tap counter", in: session)
        try await send("make it blue", in: session)

        #expect(session.turns.map(\.words) == ["a tap counter", "make it blue"])
        #expect(
            session.turns.map(\.result) == [
                .accepted(note: "Here’s Counter. Give it a tap."), .accepted(note: "Done. Anything else?"),
            ])
    }

    @Test func aChangeThatGivesUpKeepsTheDraftAndTheTurnsBeforeIt() async throws {
        let session = chat(answers: [[counter(), unbuildable, unbuildable, unbuildable]]).session
        try await send("a tap counter", in: session)
        let draft = try #require(session.draft)
        let before = try #require(try session.preview.engine.source(of: draft))
        let face = session.preview.faces[.medium]

        try await send("make it blue", in: session)

        #expect(session.phase == .failed(.gaveUp, .turn))
        #expect(session.turns.first?.accepted == true)
        #expect(session.latest?.result == .failed(.gaveUp))
        #expect(session.draft == draft)
        #expect(try session.preview.engine.source(of: draft)?.json == before.json)
        #expect(session.preview.faces[.medium]?.traits == face?.traits, "the draft on show is the one before")
    }

    @Test func aMessageSentAfterAFailureIsANewTurn() async throws {
        let session = chat(answers: [[unbuildable, unbuildable, unbuildable, counter()]]).session
        try await send("a tap counter", in: session)
        #expect(session.phase == .failed(.gaveUp, .turn))

        try await send("a counter with a plus button", in: session)
        #expect(session.turns.map(\.result).first == .failed(.gaveUp))
        #expect(session.latest?.accepted == true)
        #expect(session.draft != nil)
    }

    @Test func aNewDraftStartsEmptyAsTheSavedWidgetWill() async throws {
        let fresh = DescribeSession(
            .unsaved(try petFed()), model: ScriptedModel([]),
            preview: Preview(library: shared.engine, startsEmpty: true))
        await fresh.open()
        // Pet fed paints red until the first feed, which its sample has.
        let hue = try #require(fresh.preview.faces[.small]?.traits.hue)
        #expect(hue < 30 || hue > 330, "not fed")

        let sampled = DescribeSession(
            .unsaved(try petFed()), model: ScriptedModel([]), preview: Preview(library: shared.engine))
        await sampled.open()
        let fed = try #require(sampled.preview.faces[.small]?.traits.hue)
        #expect(abs(fed - hue) > 20)
    }

    @Test func theChangeChipsFitTheDraftOnShow() async throws {
        let session = chat(answers: [[counter(background: "#B02020")]]).session
        try await send("a red tap counter", in: session)
        let traits = try #require(session.preview.faces[.medium]?.traits)
        #expect(Changes.suggested(for: traits) == ["Make it teal", "Bigger number"])
    }

    // MARK: Asking before a draft goes

    @Test func newStartsOverAtOnceWithNothingToLose() {
        let chat = chat()
        let first = chat.session
        chat.leave()
        #expect(chat.question == nil)
        #expect(chat.session !== first)
        #expect(chat.session.blank)
    }

    @Test func newWithADraftAsksAndKeepEditingKeepsIt() async throws {
        let chat = chat(answers: [[counter()]])
        let session = chat.session
        try await send("a tap counter", in: session)
        let draft = try #require(session.draft)

        chat.leave()
        #expect(chat.question == .startOver)
        #expect(chat.question?.words == "Start over? This widget isn’t saved yet.")
        #expect(chat.session === session)

        chat.keepEditing()
        #expect(chat.question == nil)
        #expect(chat.session === session && session.draft == draft)

        chat.leave()
        chat.replace()
        #expect(chat.question == nil)
        #expect(chat.session.blank && chat.session.draft == nil)
    }

    @Test func aTemplateOpensAtOnceInAnEmptyChatAndAsksBeforeReplacingADraft() async throws {
        let chat = chat(answers: [[], [], [counter()], []])
        chat.change(try petFed("Bo"), named: "Bo fed")
        #expect(chat.question == nil)
        await chat.session.open()
        #expect(chat.session.opening == "What should we change about Bo fed?")

        chat.leave()
        chat.replace()
        try await send("a tap counter", in: chat.session)
        let session = chat.session

        chat.change(try petFed(), named: "Mochi fed")
        #expect(chat.question == .swap("Mochi fed"))
        #expect(chat.question?.words == "Swap your draft for Mochi fed?")
        #expect(chat.session === session)

        chat.replace()
        #expect(chat.session !== session)
        await chat.session.open()
        #expect(chat.session.editing == nil)
        #expect(chat.session.opening == "What should we change about Mochi fed?")
        #expect(try shared.engine.widgets().isEmpty, "the template stays out of the library until Save")
    }

    // MARK: Editing a library widget

    @Test func editingOpensOnTheWidgetAndClosesAtOnceUntilAChangeLands() async throws {
        let library = try await shared.build(counterDocument())
        var closed = 0
        let untouched = chat(.library(library), close: { closed += 1 })
        await untouched.session.open()
        #expect(untouched.session.opening == "What should we change about Counter?")
        #expect(untouched.session.draft != nil)
        untouched.leave()
        #expect(closed == 1)

        let changed = chat(.library(library), answers: [[counter(background: "#1B3A8C")]], close: { closed += 1 })
        await changed.session.open()
        try await send("make it blue", in: changed.session)
        changed.leave()
        #expect(changed.question == .leave)
        #expect(closed == 1)

        changed.replace()
        #expect(closed == 2)
        let source = try #require(try shared.engine.source(of: library))
        #expect(!String(decoding: source.json, as: UTF8.self).contains("#1B3A8C"), "nothing was saved")
    }

    // MARK: Save

    @Test func aSaveThatLandedStartsAFreshChat() async throws {
        let chat = chat(answers: [[counter()], []])
        let session = chat.session
        try await send("a tap counter", in: session)
        session.save()
        try await until({ session.settled }, "the save never finished")
        guard case .saved(let id) = session.phase else {
            Issue.record("expected the save to land, got \(session.phase)")
            return
        }

        chat.saved()
        #expect(chat.session !== session)
        #expect(chat.session.blank && chat.session.turns.isEmpty && chat.session.draft == nil)
        #expect(try shared.engine.widgets().map(\.id) == [id])
    }

    @Test func aTemplateChosenDuringASaveOpensOnceTheSaveLands() async throws {
        let gate = SuspendingGate(comesBack: .whenReleased)
        defer { Engine.resume() }
        _ = try shared.engine.widgets()
        let chat = chat(answers: [[counter()], []], gate: gate)
        let session = chat.session
        try await send("a tap counter", in: session)
        session.save()
        try await until({ gate.waiting }, "the save never waited for the app")

        chat.change(try petFed(), named: "Mochi fed")
        #expect(chat.question == nil, "a save cannot be stopped, so nothing is asked")
        #expect(chat.session === session)

        gate.release()
        try await until({ session.settled }, "the save never finished")
        chat.resume()
        #expect(chat.session === session, "the landed save keeps its session until its flight ends")

        chat.saved()
        await chat.session.open()
        #expect(chat.session.opening == "What should we change about Mochi fed?")
    }

    // MARK: Ideas

    @Test func theIdeasAreThreeSuggestionsFromTheCatalogEachFromAnotherCategory() throws {
        let catalog = Template.catalog()
        var seen: Set<[String]> = []
        for seed: UInt64 in 1...20 {
            var generator = Seeded(seed)
            let ideas = Template.ideas(from: catalog, using: &generator)
            let templates = try ideas.map { idea in try #require(catalog.first { $0.suggestion == idea }) }
            #expect(ideas.count == 3)
            #expect(Set(templates.map(\.category)).count == 3)
            seen.insert(ideas.map(\.title))
        }
        #expect(seen.count > 1, "the ideas change from one chat to the next")
    }

    @Test func aTemplateWithoutASuggestionIsNeverOffered() throws {
        let catalog = Template.catalog()
        let offered = try #require(catalog.first { $0.suggestion != nil })
        var generator = Seeded(7)
        let ideas = Template.ideas(
            from: [offered] + catalog.filter { $0.id != offered.id }.map(\.withoutSuggestion), using: &generator)
        #expect(ideas == [offered.suggestion])
    }
}

/// SplitMix64, so a test can repeat a shuffle.
private struct Seeded: RandomNumberGenerator {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension Template {
    fileprivate var withoutSuggestion: Template {
        Template(
            id: id, name: name, line: line, category: category, order: order, family: family, hint: hint,
            suggestion: nil, blanks: blanks, folder: folder)
    }
}
