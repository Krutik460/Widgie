import Foundation
import Rows
import Spec
import Testing

/// Rows belong to datasets, and each table of a widget is bound to one.
@Suite struct Datasets {
    let noon = "2026-11-18T12:00:00-05:00"

    func table(_ bench: Bench, _ id: String) throws -> Spec.TableID {
        try #require(bench.spec.table(named: id)).id
    }

    @Test func twoWidgetsBoundToOneDatasetReadAndWriteTheSameRows() throws {
        let water = try Bench()
        let dashboard = try Bench(store: water.store)
        let glasses = try table(water, "glasses")
        let shared = try #require(try water.store.dataset(of: water.widget, table: glasses))
        try water.store.bind(dashboard.widget, table: glasses, to: shared)

        try water.tap("drink", at: noon)
        try dashboard.tap("drink", at: noon)
        #expect(try water.number("glassesToday", at: noon) == 2)
        #expect(try dashboard.number("glassesToday", at: noon) == 2)

        let glass = try #require(water.rows("lastGlass", at: noon).first)
        #expect(try dashboard.tap("undo", row: glass.key, at: noon) == .written, "a row of the shared dataset")
        #expect(try water.number("glassesToday", at: noon) == 1)
        #expect(try dashboard.number("open", at: noon) == 0, "items stayed on its own dataset")
    }

    @Test func aTapOnARowOfAnotherDatasetIsIgnored() throws {
        let first = try Bench()
        let second = try Bench(store: first.store)
        try first.tap("drink", at: noon)
        let glass = try #require(first.rows("lastGlass", at: noon).first)
        #expect(
            try second.tap("undo", row: glass.key, at: noon) == .ignored("row \(glass.key.raw) is not a row of glasses")
        )
        #expect(try first.number("glassesToday", at: noon) == 1)
    }

    @Test func aTableWithNoDatasetReadsNothingAndIgnoresInserts() throws {
        let bench = try Bench()
        let stranger = try Bench(store: bench.store, widget: .mint())
        #expect(try stranger.tap("drink", at: noon) == .ignored("table glasses has no dataset"))
        #expect(try stranger.number("glassesAll", at: noon) == 0)
    }

    @Test func aRefinementKeepsDataAndARestoreReconnectsADroppedTable() throws {
        let both = try parse(
            #"""
            {"name": "Log", "look": "function render(ctx) { return { type: 'spacer' }; }",
             "tables": {"glasses": {"fields": {}}, "notes": {"fields": {"text": "text"}}},
             "queries": {"glasses": {"count": "glasses", "window": "all"}, "notes": {"count": "notes", "window": "all"}},
             "actions": {"drink": {"insert": "glasses"}, "note": {"insert": "notes", "values": {"text": "hi"}}}}
            """#)
        let glassesOnly = try parse(
            #"""
            {"name": "Log", "look": "function render(ctx) { return { type: 'spacer' }; }",
             "tables": {"glasses": {"fields": {}}, "moods": {"fields": {}}},
             "queries": {"glasses": {"count": "glasses", "window": "all"}},
             "actions": {"drink": {"insert": "glasses"}}}
            """#)
        let bench = try Bench(spec: both)
        let notes = try table(bench, "notes")
        let glasses = try table(bench, "glasses")
        let datasets = try (
            bench.store.dataset(of: bench.widget, table: glasses), bench.store.dataset(of: bench.widget, table: notes)
        )
        try bench.tap("drink", at: noon)
        try bench.tap("note", at: noon)

        _ = try bench.store.save(bench.widget, spec: glassesOnly, assets: [:])
        let refined = try Bench(store: bench.store, spec: glassesOnly, widget: bench.widget)
        #expect(try refined.number("glasses", at: noon) == 1, "the surviving table keeps its rows")
        #expect(try bench.store.dataset(of: bench.widget, table: glasses) == datasets.0)
        let moods = try table(refined, "moods")
        #expect(try bench.store.dataset(of: bench.widget, table: moods) != nil, "a new table gets a dataset")

        _ = try bench.store.save(bench.widget, spec: both, assets: [:])
        #expect(try bench.store.dataset(of: bench.widget, table: notes) == datasets.1)
        #expect(try bench.number("notes", at: noon) == 1, "the dropped table's rows come back with it")
    }

    @Test func bindingsTravelWithSync() throws {
        let water = try Bench()
        let dashboard = try Bench(store: water.store)
        let glasses = try table(water, "glasses")
        let shared = try #require(try water.store.dataset(of: water.widget, table: glasses))
        try water.store.bind(dashboard.widget, table: glasses, to: shared)
        try water.tap("drink", at: noon)

        let phone = try Bench(widget: dashboard.widget)
        try phone.store.receive(water.store.feed())
        #expect(try phone.store.dataset(of: dashboard.widget, table: glasses) == shared)
        #expect(try phone.number("glassesToday", at: noon) == 1)
    }

    @Test func sharersAreTheOtherLiveWidgetsOnADataset() throws {
        let water = try Bench()
        let dashboard = try Bench(store: water.store)
        let glasses = try table(water, "glasses")
        _ = try water.store.save(water.widget, spec: water.spec, assets: [:])
        _ = try water.store.save(dashboard.widget, spec: dashboard.spec, assets: [:])
        #expect(try water.store.sharers(of: dashboard.widget).isEmpty)

        let shared = try #require(try water.store.dataset(of: water.widget, table: glasses))
        try water.store.bind(dashboard.widget, table: glasses, to: shared)
        let sharers = try water.store.sharers(of: dashboard.widget)
        #expect(sharers.map { [$0.table, $0.widget.key.raw, $0.as] } == [["glasses", water.widget.raw, "glasses"]])

        try water.store.delete(water.widget)
        #expect(try water.store.sharers(of: dashboard.widget).isEmpty, "a deleted widget shares nothing")
    }
}
