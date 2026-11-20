import Foundation
import Rows
import Spec
import Testing
import WidgetBuilder
import WidgetEngine

/// Two widgets that read one dataset, as a dashboard will read another widget's log.
@Suite struct SharedDataTests {
    let scores = document(
        name: "Scores", look: counterLook(), tables: ["taps": ["fields": ["score": "number"]]],
        actions: ["add": ["insert": "taps", "values": ["score": 1]]])

    func scored(_ kind: String) -> WidgetSource {
        document(look: counterLook(), tables: ["taps": ["fields": ["score": kind]]])
    }

    /// Builds both widgets and binds the counter's `taps` to the dataset of the scores widget's `taps`.
    func sharing(_ scratch: Scratch) async throws -> (scores: WidgetID, counter: WidgetID) {
        let scoresID = try await scratch.build(scores)
        let counterID = try await scratch.build(document(look: counterLook()))
        let store = try scratch.engine.store()
        let owner = try #require(WidgetKey(parsing: scoresID.rawValue))
        let reader = try #require(WidgetKey(parsing: counterID.rawValue))
        let taps = try #require(try store.widget(owner)?.spec.table(named: "taps")).id
        try store.bind(reader, table: taps, to: try #require(try store.dataset(of: owner, table: taps)))
        return (scoresID, counterID)
    }

    @Test func aRefinementMustAgreeWithEveryWidgetSharingItsData() async throws {
        let scratch = Scratch()
        let (_, counter) = try await sharing(scratch)
        let line = try await scratch.line(scored("text"), replacing: counter)
        #expect(
            line
                == "field \"taps.score\" is number in widget \"Scores\", which shares this data, and is text here; keep the kind or use a new field id"
        )
        _ = try await scratch.build(scored("number"), replacing: counter)
    }

    @Test @MainActor func aTapOnOneWidgetShowsOnTheOther() async throws {
        let scratch = Scratch()
        let (scores, counter) = try await sharing(scratch)
        let before = picture(await scratch.face(counter))
        try scratch.engine.perform(try button("add", on: await scratch.face(scores)).tap, at: morning)
        let after = picture(await scratch.face(counter))
        #expect(!after.looksLike(before), "the counter shows the tap made on the scores widget")
        #expect(after.looksLike(picture(await scratch.face(scores))), "both draw the same count")
    }
}
