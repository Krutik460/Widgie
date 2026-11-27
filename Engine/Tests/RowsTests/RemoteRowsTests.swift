import CryptoKit
import Foundation
import Rows
import SQLite3
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

    /// `sum` and a list of several rows leave a row written ahead out until its `at`, as the other shapes do.
    @Test func aSumAndAListOfSeveralRowsLeaveOutARowWrittenAhead() throws {
        let bench = try Bench()
        try bench.tap("add", at: "2026-11-18T08:00:00-05:00")
        try bench.tap("typed", at: "2026-11-18T09:00:00-05:00")
        let ahead = try #require(RowKey(parsing: "0190a000-0000-7000-8000-000000000004"))
        let items = try dataset(bench, "items")
        let written = try stamp("2026-11-18T06:00:00-05:00")
        try bench.store.receive([
            Stamped(
                change: .insertRow(
                    ahead, dataset: items, day: try day("2026-11-18"),
                    at: Int64(try instant("2026-11-18T15:00:00-05:00").timeIntervalSince1970 * 1000)),
                stamp: written, replica: automation),
            Stamped(
                change: .setCell(ahead, dataset: items, field: "size", .number(5)), stamp: written, replica: automation),
        ])

        let before = "2026-11-18T14:59:59.999-05:00"
        #expect(try bench.number("size", at: before) == 10, "3 and 7 from the taps")
        #expect(try bench.rows("oldest", at: before).count == 2)
        #expect(try !bench.rows("oldest", at: before).contains { $0.key == ahead })

        let at = "2026-11-18T15:00:00-05:00"
        #expect(try bench.number("size", at: at) == 15)
        #expect(try bench.rows("oldest", at: at).count == 3)
        #expect(try bench.rows("oldest", at: at).last?.key == ahead)
    }

    /// The day bound that lets the index serve `reveals` still finds a row on the earliest day any writer can
    /// log on at its `at`, with that `at` ahead: a peer whose clock runs a few minutes fast, logging a year back
    /// in a time zone where it is still the day before.
    @Test func revealsFindARowLoggedAYearBackWithAnAtAhead() throws {
        let bench = try Bench()
        let now = try instant("2026-11-18T09:00:00-05:00")
        let soon = now.addingTimeInterval(5 * 60)
        let earliest = Spec.Effect.loggableDays(from: try day("2026-11-17")).lowerBound
        try bench.store.receive([
            Stamped(
                change: .insertRow(
                    try #require(RowKey(parsing: "0190a000-0000-7000-8000-000000000005")),
                    dataset: try dataset(bench, "glasses"), day: earliest,
                    at: Int64(soon.timeIntervalSince1970 * 1000)),
                stamp: Stamp(raw: Int64(soon.timeIntervalSince1970 * 1000) << 16), replica: automation)
        ])
        #expect(try bench.store.reveals(of: bench.widget, after: now) == [soon])
    }

    /// A document whose queries count `by me` and `by others`, and read who wrote the latest row.
    func hearts() throws -> Spec {
        try parse(
            #"""
            {"name": "Hearts", "look": "function render(ctx) { return { type: 'spacer' }; }",
             "tables": {"hearts": {"fields": {}}},
             "queries": {"mine": {"count": "hearts", "where": {"by": "me"}, "window": "all"},
                         "theirs": {"count": "hearts", "where": {"by": "others"}, "window": "all"},
                         "last": {"latest": "hearts", "window": "all"}},
             "actions": {"send": {"insert": "hearts"}}}
            """#)
    }

    /// `by me` reads `mine`: an automation's row counts as another's until a page names its replica, then as the
    /// person's own, while this store's own taps count as the person's throughout.
    @Test func byMeCountsAnAutomationRowOnceItsReplicaIsMine() throws {
        let bench = try Bench(spec: hearts())
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

    /// A store from before `mine` and the watermark, at schema 2 with this install's taps in it. The migration
    /// seeds `mine` with the install's replica, so the taps stay the person's with no pull, and no change has
    /// been pulled yet.
    @Test func theMigrationKeepsAnOlderStoresTapsThePersons() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let widget: WidgetKey
        do {
            let bench = try Bench(store: RowStore.open(directory: directory), spec: hearts())
            widget = bench.widget
            try bench.tap("send", at: "2026-11-18T08:00:00-05:00")
            try bench.tap("send", at: "2026-11-18T09:00:00-05:00")
        }
        try toSchemaTwo(directory.appending(path: "store.sqlite"))

        let bench = try Bench(store: RowStore.open(directory: directory), spec: hearts(), widget: widget)
        let noon = "2026-11-18T12:00:00-05:00"
        #expect(try bench.number("mine", at: noon) == 2)
        #expect(try bench.number("theirs", at: noon) == 0)
        #expect(try bench.rows("last", at: noon).first?.by.me == true)
        #expect(try bench.store.watermark() == 0)
    }

    /// Takes a store file back to schema 2 by undoing exactly what the step to schema 3 adds.
    func toSchemaTwo(_ file: URL) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        try #require(sqlite3_open(file.path(percentEncoded: false), &db) == SQLITE_OK)
        let undo = """
            DROP TABLE mine;
            ALTER TABLE replica DROP COLUMN watermark;
            PRAGMA user_version = 2;
            """
        try #require(sqlite3_exec(db, undo, nil, nil, nil) == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
    }

    /// The upload replaces every automation the server holds, so a live widget this build cannot read stops the
    /// payload instead of being left out, which would make the server delete its future rows.
    @Test func aLiveWidgetThatCannotBeReadStopsThePayload() throws {
        let store = try RowStore.scratch()
        _ = try store.save(.mint(), spec: fixture("wotd"), assets: [:])
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let readable = try store.automationPayload(timeZone: zone)

        let unreadable = WidgetKey.mint()
        let body = Data(#"{"format": 2, "name": "From a newer build"}"#.utf8)
        let revision = try #require(
            Spec.Digest(hex: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()))
        let written = try stamp("2026-11-18T06:00:00-05:00")
        let device = "2b8f6a3c-9d4e-4f1a-8b7c-5e6d7f8a9b0c"
        try store.receive([
            Stamped(change: .putRevision(body: body), stamp: written, replica: device),
            Stamped(change: .moveHead(unreadable, to: revision, createdAt: 0), stamp: written, replica: device),
        ])
        try store.recordProof(of: revision, verdict: nil)
        #expect(try store.widgets().count == 1, "the list leaves it out")
        do {
            let payload = try store.automationPayload(timeZone: zone)
            Issue.record("a payload of \(payload.json.count) bytes left a widget out")
        } catch {
            #expect(error.message.hasPrefix("widget \(unreadable.raw): "), "\(error.message)")
        }

        try store.delete(unreadable)
        #expect(try store.automationPayload(timeZone: zone) == readable, "once it is deleted, nothing is left out")
    }
}
