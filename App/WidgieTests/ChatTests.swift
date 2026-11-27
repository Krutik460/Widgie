import Foundation
import Testing
import UIKit
import WidgetBuilder
import WidgetEngine

@testable import Widgie

/// Make's chat against a scripted model, a temporary shared store, and the preview's scratch engine. Serialized for
/// the same reason as `DescribeSessionTests`: a save that meets a suspended store reaches every store in the process.
@MainActor @Suite(.serialized) struct ChatTests {
    let shared = SharedStore()

    /// A chat whose sessions answer from `answers` in turn, one script per session, each drawing its draft from no
    /// rows as Make's sessions do.
    private func chat(
        _ origin: DescribeSession.Origin = .nothing, answers: [[ScriptedModel.Answer]] = [],
        close: (() -> Void)? = nil, gate: SuspendingGate? = nil
    ) -> Chat {
        var scripts = answers
        return Chat(origin, close: close) { [shared] origin in
            let model = ScriptedModel(scripts.isEmpty ? [] : scripts.removeFirst())
            return DescribeSession(
                origin, model: model, preview: Preview(library: shared.engine, startsEmpty: true),
                sharedWritesOpen: { await gate?.open() })
        }
    }

    private func petFed(_ name: String = "Mochi") throws -> WidgetSource {
        let template = try Template.bundled("pet-fed")
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
        let fresh = DescribeSession(.unsaved(try petFed()), model: ScriptedModel([]))
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

    @Test func theChangeChipsFitTheDraftAndEachLeavesOnceItsTurnLands() async throws {
        let chat = chat(answers: [
            [
                counter(background: "#B02020"), unbuildable, unbuildable, unbuildable, counter(background: "#20B0B0"),
                counter(background: "#20B0B0"), counter(background: "#2050B0"),
            ]
        ])
        let session = chat.session
        func chips() throws -> [Changes.Chip] {
            let traits = try #require(session.preview.faces[.medium]?.traits)
            return Changes.suggested(for: traits, used: session.usedChanges)
        }
        func tap(_ words: String) async throws {
            let chip = try #require(try chips().first { $0.words == words })
            chat.send(chip.words, change: chip.change)
            try await until({ session.settled }, "the change never finished")
        }

        try await send("a red tap counter", in: session)
        #expect(try chips().map(\.words) == ["Make it teal", "Bigger number"])

        try await tap("Make it teal")
        #expect(session.phase == .failed(.gaveUp, .turn))
        #expect(try chips().map(\.words) == ["Make it teal", "Bigger number"], "a change that did not land stays")

        try await tap("Make it teal")
        #expect(try chips().map(\.words) == ["Bigger number", "Change the colors"], "not Make it red")

        try await tap("Bigger number")
        #expect(try chips().map(\.words) == ["Change the colors"])

        try await tap("Change the colors")
        #expect(try chips().isEmpty)
    }

    @Test func stoppingTheFirstBuildLeavesNoDraftAndTheNextMessageBuilds() async throws {
        let latch = Latch()
        let held = ScriptedModel.Answer(reply: counter().reply) { await latch.wait() }
        let session = chat(answers: [[held, counter()]]).session
        session.words = "a tap counter"
        session.send()
        try await until({ latch.waiting }, "the build never asked the model")

        session.cancel()
        latch.open()
        try await until({ session.settled }, "the build never stopped")
        #expect(session.phase == .composing)
        #expect(session.latest?.result == .cancelled)
        #expect(session.draft == nil && session.preview.faces.isEmpty)

        try await send("a tap counter", in: session)
        #expect(session.latest?.accepted == true && session.draft != nil)
    }

    // MARK: Try again

    @Test func tryAgainRunsTheFailedTurnAgainInPlace() async throws {
        let chat = chat(answers: [[unreachable, counter()]])
        let session = chat.session
        try await send("a tap counter", in: session)
        #expect(session.phase == .failed(.unreachable, .turn))

        chat.retry()
        try await until({ session.settled }, "the turn never ran again")
        #expect(session.turns.map(\.words) == ["a tap counter"])
        #expect(session.latest?.accepted == true && session.draft != nil)
    }

    @Test func tryAgainRunsAFailedSaveAgain() async throws {
        let library = try await shared.build(counterDocument())
        let chat = chat(
            .library(library),
            answers: [[counter(background: "#1B3A8C"), unreachable, counter(background: "#1B3A8C", fields: noted)]],
            close: {})
        let session = chat.session
        await session.open()
        try await send("make it blue", in: session)
        _ = try await shared.build(counterDocument(fields: noted), replacing: library)

        chat.save()
        try await until({ session.settled }, "the save never finished")
        #expect(session.phase == .failed(.unreachable, .save))

        chat.retry()
        try await until({ session.settled }, "the save never ran again")
        #expect(session.phase == .saved(library))
        let saved = try #require(try shared.engine.source(of: library))
        #expect(String(decoding: saved.json, as: UTF8.self).contains("#1B3A8C"))
    }

    @Test func tryAgainDoesNothingAfterAFailureRunningItAgainCannotFix() async throws {
        let turn = chat(answers: [[unbuildable, unbuildable, unbuildable]]).session
        try await send("a tap counter", in: turn)
        turn.retry()
        #expect(turn.phase == .failed(.gaveUp, .turn), "and the model is asked nothing more")

        let library = try await shared.build(counterDocument())
        let save = chat(
            .library(library),
            answers: [[counter(background: "#1B3A8C"), unbuildable, unbuildable, unbuildable]], close: {}
        ).session
        await save.open()
        try await send("make it blue", in: save)
        _ = try await shared.build(counterDocument(fields: noted), replacing: library)
        save.save()
        try await until({ save.settled }, "the save never finished")
        #expect(save.phase == .failed(.unsaved, .save), "a repair that gives up is a save that did not happen")
        save.retry()
        #expect(save.phase == .failed(.unsaved, .save))
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

    /// The cover closes a moment after a save lands, and Close may come first. The late close must not take down a
    /// cover opened in that moment.
    @Test func aChatClosesItsCoverOnce() async throws {
        let library = try await shared.build(counterDocument())
        var closed = 0
        let chat = chat(.library(library), answers: [[counter(background: "#1B3A8C")]], close: { closed += 1 })
        await chat.session.open()
        try await send("make it blue", in: chat.session)
        chat.save()
        try await until({ chat.session.settled }, "the save never finished")
        #expect(chat.session.phase == .saved(library))

        chat.leave()
        chat.close()
        #expect(closed == 1)
    }

    @Test func saveWhileLeaveIsAskedDropsTheQuestionAndSavesTheChange() async throws {
        let gate = SuspendingGate(comesBack: .whenReleased)
        defer { Engine.resume() }
        let library = try await shared.build(counterDocument())
        var closed = 0
        let chat = chat(
            .library(library), answers: [[counter(background: "#1B3A8C")]], close: { closed += 1 }, gate: gate)
        let session = chat.session
        await session.open()
        try await send("make it blue", in: session)
        chat.leave()
        #expect(chat.question == .leave)

        chat.save()
        #expect(chat.question == nil, "saving answers it")
        try await until({ gate.waiting }, "the save never waited for the app")
        chat.leave()
        #expect(closed == 0 && chat.question == nil, "Close does not discard a save under way")

        gate.release()
        try await until({ session.settled }, "the save never finished")
        #expect(session.phase == .saved(library))
        let saved = try #require(try shared.engine.source(of: library))
        #expect(String(decoding: saved.json, as: UTF8.self).contains("#1B3A8C"))
    }

    @Test func closeDuringASavesRepairWaitsForTheSave() async throws {
        var closed = 0
        let held = try await heldSave(at: .repairing, close: { closed += 1 })
        let session = held.chat.session
        held.chat.save()
        try await until(held.stopped, "the repair never asked the model")
        #expect(session.phase == .saving && session.replacement == .waits)

        held.chat.leave()
        #expect(held.chat.question == nil && closed == 0, "Leave without saving? is not asked mid save")

        held.release()
        try await until({ session.settled }, "the save never finished")
        #expect(session.phase == .saved(try #require(session.editing)))
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

        chat.saved(id)
        #expect(chat.session !== session)
        #expect(chat.session.blank && chat.session.turns.isEmpty && chat.session.draft == nil)
        #expect(try shared.engine.widgets().map(\.id) == [id])
    }

    @Test func saveWhileStartOverIsAskedDropsTheQuestionAndTheSaveLands() async throws {
        let held = try await heldSave(at: .waitingForTheApp)
        defer { Engine.resume() }
        let chat = held.chat
        let session = chat.session
        chat.leave()
        #expect(chat.question == .startOver)

        chat.save()
        #expect(chat.question == nil, "saving answers it")
        try await until(held.stopped, "the save never waited for the app")
        chat.leave()
        #expect(chat.session === session && chat.question == nil, "New does not replace a save under way")

        held.release()
        try await until({ session.settled }, "the save never finished")
        guard case .saved(let id) = session.phase else {
            Issue.record("expected the save to land, got \(session.phase)")
            return
        }
        #expect(try shared.engine.widgets().map(\.id) == [id])
        chat.saved(id)
        #expect(chat.session !== session && chat.session.blank)
    }

    @Test func aMessageSentWhileAQuestionIsUpDropsTheQuestion() async throws {
        let chat = chat(answers: [[counter(), counter(background: "#1B3A8C")]])
        try await send("a tap counter", in: chat.session)
        chat.change(try petFed(), named: "Mochi fed")
        #expect(chat.question == .swap("Mochi fed"))

        chat.send("make it blue")
        #expect(chat.question == nil)
        try await until({ chat.session.settled }, "the change never finished")
        chat.resume()
        #expect(chat.question == nil, "the template is not asked about again")
    }

    /// Without a model service every message fails the same way, so sending leaves the phase as it was.
    @Test func aMessageThatFailsAsTheOneBeforeItStillDropsTheQuestion() async throws {
        let chat = Chat(
            .unsaved(try petFed()),
            start: { [shared] in
                DescribeSession($0, model: nil, preview: Preview(library: shared.engine, startsEmpty: true))
            })
        await chat.session.open()
        chat.send("make it blue")
        #expect(chat.session.phase == .failed(.unavailable, .turn))
        chat.leave()
        #expect(chat.question == .startOver)

        chat.send("make it green")
        #expect(chat.session.phase == .failed(.unavailable, .turn))
        #expect(chat.question == nil)
    }

    @Test(arguments: SaveStop.allCases)
    func aTemplateChosenDuringASaveOpensOnceTheSaveLands(stop: SaveStop) async throws {
        let held = try await heldSave(at: stop)
        defer { Engine.resume() }
        let chat = held.chat
        let session = chat.session
        chat.save()
        try await until(held.stopped, "the save never stopped")
        #expect(session.phase == .saving && session.replacement == .waits)

        chat.change(try petFed(), named: "Mochi fed")
        #expect(chat.question == nil, "a save cannot be stopped, so nothing is asked")
        #expect(chat.session === session)

        held.release()
        try await until({ session.settled }, "the save never finished")
        chat.resume()
        #expect(chat.session === session, "the landed save keeps its session until its flight ends")
        guard case .saved(let id) = session.phase else {
            Issue.record("expected the save to land, got \(session.phase)")
            return
        }

        chat.saved(id)
        await chat.session.open()
        #expect(chat.session.opening == "What should we change about Mochi fed?")
    }

    @Test func aTemplateOpenedDuringTheSavesFlightStaysWhenTheFlightEnds() async throws {
        let chat = chat(answers: [[counter()], []])
        let session = chat.session
        try await send("a tap counter", in: session)
        chat.save()
        try await until({ session.settled }, "the save never finished")
        guard case .saved(let id) = session.phase else {
            Issue.record("expected the save to land, got \(session.phase)")
            return
        }

        chat.change(try petFed(), named: "Mochi fed")
        let template = chat.session
        #expect(template !== session, "a saved draft is replaced at once")
        chat.saved(id)
        #expect(chat.session === template)
    }

    /// Where a save stops until the test releases it.
    enum SaveStop: CaseIterable, Sendable {
        /// The shared store refused the write in the background and waits for the app to come back.
        case waitingForTheApp
        /// The shared store rejected the change and its repair turn waits on the model.
        case repairing
    }

    /// A chat with a draft whose Save stops at `stop`. Waiting for the app, it is a new counter. Repairing, it is a
    /// library counter changed to blue, which gained a field in the library meanwhile, so the store rejects the
    /// change until a repair keeps the field.
    private func heldSave(at stop: SaveStop, close: (() -> Void)? = nil) async throws -> (
        chat: Chat, stopped: () -> Bool, release: () -> Void
    ) {
        switch stop {
        case .waitingForTheApp:
            let gate = SuspendingGate(comesBack: .whenReleased)
            _ = try shared.engine.widgets()
            let chat = chat(answers: [[counter()], []], close: close, gate: gate)
            try await send("a tap counter", in: chat.session)
            return (chat, { gate.waiting }, gate.release)
        case .repairing:
            let latch = Latch()
            let library = try await shared.build(counterDocument())
            let repaired = ScriptedModel.Answer(reply: counter(background: "#1B3A8C", fields: noted).reply) {
                await latch.wait()
            }
            let chat = chat(
                .library(library), answers: [[counter(background: "#1B3A8C"), repaired], []], close: close)
            await chat.session.open()
            try await send("make it blue", in: chat.session)
            _ = try await shared.build(counterDocument(fields: noted), replacing: library)
            return (chat, { latch.waiting }, latch.open)
        }
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

    @Test func everyTemplateOffersAnIdeaOfItsOwnWithASymbolThatExists() throws {
        let root = try #require(Bundle.main.url(forResource: "Templates", withExtension: nil))
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
            .filter { !$0.hasPrefix(".") }
        let catalog = Template.catalog(in: root)
        #expect(catalog.count == folders.count, "a template.json without a suggestion does not read")
        for template in catalog {
            #expect(UIImage(systemName: template.suggestion.icon) != nil, "\(template.id)'s icon")
            #expect(!template.suggestion.title.isEmpty && !template.suggestion.subtitle.isEmpty, "\(template.id)")
        }
        #expect(Set(catalog.map(\.suggestion.title)).count == catalog.count, "no two ideas say the same")
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

/// A field the library counter gains while a change to it is being made, so saving the change needs a repair.
private let noted = ["note": "text"]
