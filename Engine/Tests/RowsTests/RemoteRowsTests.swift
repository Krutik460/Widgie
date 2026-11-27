import Foundation
import Rows
import Spec
import Testing

/// Rows an automation writes ahead, read through every query shape, and whose rows count as the person's.
@Suite struct RemoteRowsTests {
    let automation = "7d9e4c1a-2b3f-4a5d-8e6f-1c2d3e4f5a6b"

    func stamp(_ iso: String) throws -> Stamp {
        Stamp(raw: Int64(try instant(iso).timeIntervalSince1970 * 1000) << 16)
    }

    func dataset(_ bench: Bench, _ table: String) throws -> DatasetKey {
        let id = try #require(bench.spec.table(named: table)).id
        return try #require(try bench.store.dataset(of: bench.widget, table: id))
    }

    /// One glass at 15:00 today, written by the automation at 06:00.
    func glassAhead(_ bench: Bench) throws -> RowKey {
        let key = try #require(RowKey(parsing: "0190a000-0000-7000-8000-000000000001"))
        try bench.store.receive([
            Stamped(
                change: .insertRow(
                    key, dataset: try dataset(bench, "glasses"), day: try day("2026-11-18"),
                    at: Int64(try instant("2026-11-18T15:00:00-05:00").timeIntervalSince1970 * 1000)),
                stamp: try stamp("2026-11-18T06:00:00-05:00"), replica: automation)
        ])
        return key
    }

    @Test func aRowWrittenAheadIsHiddenFromEveryShapeUntilItsAt() throws {
        let bench = try Bench()
        try bench.tap("drink", at: "2026-11-17T09:00:00-05:00")
        let key = try glassAhead(bench)

        let before = "2026-11-18T14:59:59.999-05:00"
        #expect(try bench.number("glassesToday", at: before) == 0)
        #expect(try bench.number("glassesAll", at: before) == 1)
        #expect(try bench.rows("lastGlass", at: before).isEmpty)
        #expect(try bench.number("streak", at: before) == 1, "yesterday's glass alone")
        #expect(try bench.days("glassesDaily", at: before).map(\.count) == [0, 1, 0])

        let at = "2026-11-18T15:00:00-05:00"
        #expect(try bench.number("glassesToday", at: at) == 1)
        #expect(try bench.number("glassesAll", at: at) == 2)
        #expect(try bench.rows("lastGlass", at: at).map(\.key) == [key])
        #expect(try bench.rows("lastGlass", at: at).first?.at == (try instant(at)))
        #expect(try bench.number("streak", at: at) == 2)
        #expect(try bench.days("glassesDaily", at: at).map(\.count) == [0, 1, 1])
    }

    @Test func revealsAreTheNextTwoHiddenInstants() throws {
        let bench = try Bench()
        #expect(try bench.store.reveals(of: bench.widget, after: try instant("2026-11-18T09:00:00-05:00")).isEmpty)
        _ = try glassAhead(bench)
        try bench.store.receive([
            Stamped(
                change: .insertRow(
                    try #require(RowKey(parsing: "0190a000-0000-7000-8000-000000000002")),
                    dataset: try dataset(bench, "items"), day: try day("2026-11-19"),
                    at: Int64(try instant("2026-11-19T06:00:00-05:00").timeIntervalSince1970 * 1000)),
                stamp: try stamp("2026-11-18T06:00:00-05:00"), replica: automation)
        ])
        try bench.tap("drink", at: "2026-11-18T09:00:00-05:00")
        #expect(
            try bench.store.reveals(of: bench.widget, after: try instant("2026-11-18T09:00:00-05:00"))
                == [try instant("2026-11-18T15:00:00-05:00"), try instant("2026-11-19T06:00:00-05:00")])
        #expect(
            try bench.store.reveals(of: bench.widget, after: try instant("2026-11-18T15:00:00-05:00"))
                == [try instant("2026-11-19T06:00:00-05:00")])
        #expect(try bench.store.reveals(of: Bench().widget, after: try instant("2026-11-18T09:00:00-05:00")).isEmpty)
    }

    /// `by me` reads `mine`: an automation's row counts as another's until a page names its replica, then as the
    /// person's own, while this store's own taps count as the person's throughout.
    @Test func byMeCountsAnAutomationRowOnceItsReplicaIsMine() throws {
        let spec = try parse(
            #"""
            {"name": "Hearts", "look": "function render(ctx) { return { type: 'spacer' }; }",
             "tables": {"hearts": {"fields": {}}},
             "queries": {"mine": {"count": "hearts", "where": {"by": "me"}, "window": "all"},
                         "theirs": {"count": "hearts", "where": {"by": "others"}, "window": "all"},
                         "last": {"latest": "hearts", "window": "all"}},
             "actions": {"send": {"insert": "hearts"}}}
            """#)
        let bench = try Bench(spec: spec)
        try bench.tap("send", at: "2026-11-18T08:00:00-05:00")
        try bench.store.receive([
            Stamped(
                change: .insertRow(
                    try #require(RowKey(parsing: "0190a000-0000-7000-8000-000000000003")),
                    dataset: try dataset(bench, "hearts"), day: try day("2026-11-18"),
                    at: Int64(try instant("2026-11-18T09:00:00-05:00").timeIntervalSince1970 * 1000)),
                stamp: try stamp("2026-11-18T06:00:00-05:00"), replica: automation)
        ])
        let noon = "2026-11-18T12:00:00-05:00"
        #expect(try bench.number("mine", at: noon) == 1)
        #expect(try bench.number("theirs", at: noon) == 1)
        #expect(try bench.rows("last", at: noon).first?.by.me == false)

        let named = try Page(
            json: Data(#"{"replica": "\#(automation)", "changes": [], "nextWrite": null}"#.utf8))
        try bench.store.receive(named, now: try instant(noon))
        #expect(try bench.number("mine", at: noon) == 2)
        #expect(try bench.number("theirs", at: noon) == 0)
        #expect(try bench.rows("last", at: noon).first?.by.me == true)
        #expect(try bench.store.watermark() == 0, "a page with no changes passes none")
    }
}
