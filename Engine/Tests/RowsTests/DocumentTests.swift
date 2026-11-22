import Foundation
import Rows
import Spec
import Testing

@Suite struct Documents {
    func spec(named name: String, assets: String = "{}") throws -> Spec {
        try parse(
            #"{"name": "\#(name)", "look": "function render(ctx) { return { type: 'spacer' }; }", "assets": \#(assets)}"#
        )
    }

    @Test func savingTheSameDocumentTwiceKeepsOneRevision() throws {
        let store = try RowStore.scratch()
        let key = WidgetKey.mint()
        let first = try store.save(key, spec: spec(named: "One"), assets: [:])
        let second = try store.save(key, spec: spec(named: "One"), assets: [:])
        #expect(first == second)
        #expect(try store.revisions(of: key).map(\.digest) == [first])
        #expect(try store.revision(first).map { try Spec.parse($0) } == (try spec(named: "One")))
    }

    @Test func historyIsNewestFirstAndRestoreMovesTheHead() throws {
        let store = try RowStore.scratch()
        let key = WidgetKey.mint()
        let one = try store.save(key, spec: spec(named: "One"), assets: [:])
        let two = try store.save(key, spec: spec(named: "Two"), assets: [:])
        #expect(try store.revisions(of: key).map(\.digest) == [two, one])
        #expect(try store.widget(key)?.spec.name == "Two")

        try store.restore(key, to: one)
        #expect(try store.widget(key)?.revision == one)
        #expect(try store.widget(key)?.spec.name == "One")
        #expect(try store.revisions(of: key).map(\.digest) == [one, two], "the first entry is the current head")

        let elsewhere = try store.save(.mint(), spec: spec(named: "Three"), assets: [:])
        #expect(throws: StoreError.self) { try store.restore(key, to: elsewhere) }
        #expect(try store.widget(key)?.revision == one)
    }

    @Test func assetFilesAreNamedByTheirSHA256AndWrittenBeforeTheRevision() throws {
        let store = try RowStore.scratch()
        let key = WidgetKey.mint()
        let bytes = Data("abc".utf8)
        let abc = try #require(Spec.Digest(hex: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        let declared = try spec(named: "Logo", assets: #"{"logo": {"about": "the letters abc"}}"#)
        let logo = try #require(declared.asset(named: "logo")?.id)
        let revision = try store.save(key, spec: declared, assets: [logo: bytes])
        #expect(try Data(contentsOf: store.assetURL(abc)) == bytes)
        #expect(try store.widget(key)?.spec.asset(named: "logo")?.digest == abc)
        let stored = try #require(try store.revision(revision))
        #expect(try Spec.parse(stored).asset(named: "logo")?.digest == abc, "the revision names its image")
    }

    func counter(fields: String) throws -> Spec {
        try parse(
            #"{"name": "Counter", "look": "function render(ctx) { return { type: 'spacer' }; }", "tables": {"taps": {"fields": \#(fields)}}}"#
        )
    }

    @Test func aRefinementCheckedBeforeACompetingOneCommittedIsRefusedWhenItSaves() throws {
        let store = try RowStore.scratch()
        let key = WidgetKey.mint()
        let first = try store.save(key, spec: counter(fields: "{}"), assets: [:])
        let blue = try counter(fields: "{}")
        #expect(try store.refusal(of: blue, replacing: key) == nil, "it fits the head it was checked against")
        let competing = try store.replace(key, with: counter(fields: #"{"note": "text"}"#), assets: [:])
        #expect(competing == nil)

        #expect(
            try store.replace(key, with: blue, assets: [:])
                == "field \"taps.note\" is gone; keep every field id so the stored values carry over")
        #expect(try store.widget(key)?.spec == (try counter(fields: #"{"note": "text"}"#)), "the head did not move")
        #expect(try store.revisions(of: key).count == 2)
        #expect(try store.revisions(of: key).last?.digest == first)
    }

    @Test func aRefinementOfAWidgetDeletedSinceItWasCheckedThrowsAndLeavesItDeleted() throws {
        let store = try RowStore.scratch()
        let key = WidgetKey.mint()
        _ = try store.save(key, spec: counter(fields: "{}"), assets: [:])
        let blue = try counter(fields: #"{"note": "text"}"#)
        #expect(try store.refusal(of: blue, replacing: key) == nil)
        try store.delete(key)

        #expect(throws: StoreError.self) { try store.replace(key, with: blue, assets: [:]) }
        #expect(try store.widget(key) == nil)
        #expect(try store.widgets().isEmpty)
    }

    @Test func widgetsListsLiveWidgetsNewestFirst() throws {
        let store = try RowStore.scratch()
        let older = WidgetKey.mint()
        let newer = WidgetKey.mint()
        _ = try store.save(older, spec: spec(named: "Older"), assets: [:])
        Thread.sleep(forTimeInterval: 0.01)
        let shared = try store.save(newer, spec: spec(named: "Newer"), assets: [:])
        _ = try store.save(older, spec: spec(named: "Newer"), assets: [:])
        #expect(try store.widgets().map(\.key) == [newer, older], "a refinement keeps the creation order")
        #expect(try store.widgets().map(\.revision) == [shared, shared], "one revision serves both widgets")

        try store.delete(older)
        #expect(try store.widgets().map(\.key) == [newer])
        #expect(try store.widget(older) == nil)
    }
}
