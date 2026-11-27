import Foundation
import Observation
import PhotosUI
import SwiftUI
import Testing
import WidgetBuilder
import WidgetEngine

@testable import Widgie

/// The describe flow against a scripted model, a temporary shared store, and the preview's scratch engine.
/// Serialized, because suspending writes reaches every shared store in the process; the scheme in project.yml
/// also runs the suites one at a time, so the other suites' stores never open inside a suspension window.
@MainActor @Suite(.serialized) struct DescribeSessionTests {
    let shared = SharedStore()

    @Test func aSaveTheSharedStoreRejectsRunsOneRepairTurnAndThenSaves() async throws {
        let library = try await shared.build(counterDocument())
        let model = ScriptedModel([counter(background: "#1B3A8C", fields: ["note": "text"])])
        let session = DescribeSession(editing: library, model: model, preview: Preview(library: shared.engine))
        await session.open()
        #expect(session.phase == .composing)
        _ = try await shared.build(counterDocument(fields: ["note": "text"]), replacing: library)

        session.save()
        try await until({ session.settled }, "the save never finished")

        #expect(session.phase == .saved(library))
        #expect(
            model.requests.map(\.repair?.line) == [
                "field \"taps.note\" is gone; keep every field id so the stored values carry over"
            ])
        #expect(try shared.engine.history(of: library).count == 3)
        let saved = try #require(try shared.engine.source(of: library))
        #expect(String(decoding: saved.json, as: UTF8.self).contains("#1B3A8C"), "the repaired draft was saved")
    }

    @Test func aSessionStartedOnAnUnsavedDraftRefinesItAndSavesItAsANewWidget() async throws {
        let model = ScriptedModel([counter(background: "#1B3A8C")])
        let session = DescribeSession(
            draft: WidgetSource(json: Data(counterDocument().utf8)), model: model,
            preview: Preview(library: shared.engine))
        #expect(session.phase == .opening)
        await session.open()
        #expect(session.phase == .composing)
        let draft = try #require(session.draft)
        #expect(session.editing == nil)
        #expect(try shared.engine.widgets().isEmpty, "the draft stays out of the library until Save")

        session.send("make it blue")
        try await until({ session.settled }, "the refine never finished")
        #expect(session.latest?.result == .accepted)
        let request = try #require(model.requests.first)
        #expect(request.current?.contains("#102030") == true, "the first message refines the draft")
        #expect(session.draft == draft)

        session.save()
        try await until({ session.settled }, "the save never finished")
        guard case .saved(let id) = session.phase else {
            Issue.record("expected the save to land, got \(session.phase)")
            return
        }
        #expect(try shared.engine.widgets().map(\.id) == [id])
    }

    @Test func aDraftThatDoesNotBuildCannotBeOpened() async throws {
        let session = DescribeSession(
            draft: WidgetSource(json: Data(#"{"name": "Counter"}"#.utf8)), model: ScriptedModel([]),
            preview: Preview(library: shared.engine))
        await session.open()
        #expect(session.phase == .failed(.unopened))
        #expect(session.draft == nil)
    }

    @Test func aCancelAfterTheReplyWasAcceptedRestoresThePreviousDraft() async throws {
        let cancel = CancelAtNextPhase()
        let blue = ScriptedModel.Answer(reply: counter(background: "#1B3A8C").reply) { await cancel.arm() }
        let session = DescribeSession(
            model: ScriptedModel([counter(), blue]), preview: Preview(library: shared.engine))
        cancel.session = session
        session.words = "a tap counter"
        session.send()
        try await until({ session.settled }, "the first turn never finished")
        let draft = try #require(session.draft)
        let first = try #require(try session.preview.engine.source(of: draft))

        session.send("make it blue")
        try await until({ session.settled }, "the second turn never finished")

        #expect(session.phase == .composing)
        #expect(session.latest?.result == .cancelled)
        #expect(session.draft == draft)
        #expect(try session.preview.engine.source(of: draft)?.json == first.json)
        #expect(try session.preview.engine.history(of: draft).count == 2, "the blue revision was saved, then undone")
    }

    @Test func aCancelWhileARefinementIsCheckedKeepsTheRowTappedBefore() async throws {
        let cancel = CancelAtNextPhase()
        let bigger = ScriptedModel.Answer(reply: tally(size: 32).reply) { await cancel.arm() }
        let session = DescribeSession(
            model: ScriptedModel([tally(), bigger]), preview: Preview(library: shared.engine))
        cancel.session = session
        session.words = "a tap counter"
        session.send()
        try await until({ session.settled }, "the first turn never finished")
        let draft = try #require(session.draft)
        let engine = session.preview.engine
        #expect(!paintsRed(session.preview.faces[.small]), "the sample's two rows")
        let revision = try #require(try engine.history(of: draft).first).id
        session.preview.perform(Tap(widget: draft.rawValue, revision: revision, action: "add", row: nil))
        try await until({ paintsRed(session.preview.faces[.small]) }, "the tap never showed")

        session.send("make the number bigger")
        try await until({ session.settled }, "the second turn never finished")

        #expect(session.latest?.result == .cancelled)
        #expect(paintsRed(session.preview.faces[.small]), "the tapped row is still on show")
        let stored = await engine.faces(for: draft, family: .small, size: Family.small.standardSize, from: .now)
        #expect(paintsRed(stored.current), "and still stored")
    }

    /// An engine that is not scratch refuses every sample load, so the accepted draft cannot go on show.
    @Test func aDraftWhoseSampleDoesNotLoadFailsTheTurn() async throws {
        let drafts = SharedStore()
        let session = DescribeSession(
            model: ScriptedModel([counter()]), preview: Preview(library: shared.engine, engine: drafts.engine))
        session.words = "a tap counter"
        session.send()
        try await until({ session.settled }, "the turn never finished")

        #expect(session.phase == .failed(.broken))
        #expect(session.latest?.result == .failed(.broken))
        #expect(session.draft == nil)
    }

    @Test func aGiveUpPutsTheWordsBack() async throws {
        let model = ScriptedModel([unbuildable, unbuildable, unbuildable])
        let session = DescribeSession(model: model, preview: Preview(library: shared.engine))
        session.words = "a tap counter"
        session.send()
        #expect(session.words.isEmpty)
        try await until({ session.settled }, "the turn never finished")
        #expect(session.phase == .failed(.gaveUp))

        session.dismissFailure()
        #expect(session.phase == .composing)
        #expect(session.words == "a tap counter")
        #expect(session.draft == nil)
        #expect(model.requests.count == Engine.maxBuildAttempts)
    }

    @Test func wordsWaitForAPhotoThatIsStillLoading() async throws {
        let session = DescribeSession(model: ScriptedModel([]), preview: Preview(library: shared.engine))
        session.words = "a tap counter"
        session.pendingPhoto = PhotosPickerItem(itemIdentifier: "loading")
        #expect(!session.canSend)

        session.send()
        #expect(session.latest == nil)
        #expect(session.phase == .composing)
        #expect(session.words == "a tap counter")

        session.pendingPhoto = nil
        #expect(session.canSend)
    }

    @Test func aSaveRefusedWhileSuspendedWaitsForTheAppToComeBackAndThenSaves() async throws {
        let gate = SuspendingGate(comesBack: .whenReleased)
        defer { Engine.resume() }
        let session = try await draftedSession(gate: gate)
        session.save()
        try await until({ gate.waiting }, "the save never waited for the app")
        #expect(session.phase == .saving)
        #expect(try shared.engine.widgets().isEmpty)

        gate.release()
        try await until({ session.settled }, "the save never finished")
        guard case .saved(let id) = session.phase else {
            Issue.record("expected the save to land, got \(session.phase)")
            return
        }
        #expect(try shared.engine.widgets().map(\.id) == [id])
    }

    @Test func aSaveRefusedWhileSuspendedSavesOnTheRetryWhenTheAppIsAlreadyBack() async throws {
        let gate = SuspendingGate(comesBack: .asTheRetryStarts)
        defer { Engine.resume() }
        let session = try await draftedSession(gate: gate)
        session.save()
        try await until({ session.settled }, "the save never finished")
        guard case .saved(let id) = session.phase else {
            Issue.record("expected the save to land, got \(session.phase)")
            return
        }
        #expect(try shared.engine.widgets().map(\.id) == [id])
    }

    /// A session with an accepted draft, whose Save meets `gate`.
    private func draftedSession(gate: SuspendingGate) async throws -> DescribeSession {
        _ = try shared.engine.widgets()
        let session = DescribeSession(
            model: ScriptedModel([counter()]), preview: Preview(library: shared.engine),
            sharedWritesOpen: { await gate.open() })
        session.words = "a tap counter"
        session.send()
        try await until({ session.settled }, "the turn never finished")
        try #require(session.draft != nil)
        return session
    }
}

/// Cancels the session at its next phase change once armed, which the model does just before it replies, so
/// the cancel lands while the reply is being proved.
@MainActor private final class CancelAtNextPhase: Sendable {
    var session: DescribeSession?

    nonisolated func arm() async {
        await MainActor.run {
            guard let session else { return }
            withObservationTracking {
                _ = session.phase
            } onChange: {
                MainActor.assumeIsolated { session.cancel() }
            }
        }
    }
}

/// Stands in for `SharedWrites.open`. The first call lets the save through and then the app goes to the
/// background, so the shared store refuses the write as suspended. The app comes back either when the test
/// releases the second call, or as the second call starts, so the retry never waits.
@MainActor private final class SuspendingGate {
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

/// The counter, painted red once it holds more than the two rows of its sample, so a face shows whether a tap
/// on top of the sample is there. `size` is the number's.
private func tally(size: Int = 30) -> ScriptedModel.Answer {
    let document = counterDocument()
        .replacing("widgetBackground: '#102030'", with: "widgetBackground: ctx.data.n > 2 ? '#B02020' : '#2050B0'")
        .replacing("size: 30", with: "size: \(size)")
    return ScriptedModel.Answer(reply: "```json\n\(document)\n```")
}

private func paintsRed(_ face: Face?) -> Bool {
    guard let hue = face?.traits.hue else { return false }
    return hue < 30 || hue > 330
}
