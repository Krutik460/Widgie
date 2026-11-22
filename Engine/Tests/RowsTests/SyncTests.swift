import Foundation
import Rows
import Spec
import Testing

/// What a store takes from sync, and what it hands sync: typed cells, row changes bound to their dataset,
/// scopes, bounded input, and designs that draw only once proved here.
@Suite struct Syncing {
    let noon = "2026-11-18T12:00:00-05:00"

    /// A stamp at `iso`, as another replica's clock would issue it.
    func stamp(_ iso: String) throws -> Stamp {
        Stamp(raw: Int64(try instant(iso).timeIntervalSince1970 * 1000) << 16)
    }

    func stamp(_ date: Date) -> Stamp {
        Stamp(raw: Int64(date.timeIntervalSince1970 * 1000) << 16)
    }

    func dataset(_ bench: Bench, _ table: String = "items") throws -> DatasetKey {
        let id = try #require(bench.spec.table(named: table)).id
        return try #require(try bench.store.dataset(of: bench.widget, table: id))
    }

    /// `testDocument`'s items with `done` redeclared as `kind`, read by a list and a sum or a count.
    func redeclared(_ kind: String) throws -> Spec {
        let measure = kind == "number" ? #""doneSum": {"sum": "items.done", "window": "all"},"# : ""
        return try parse(
            #"""
            {"name": "Redeclared", "look": "function render(ctx) { return { type: 'spacer' }; }",
             "tables": {"items": {"fields": {"title": "text", "done": "\#(kind)"}}},
             "queries": {\#(measure) "all": {"list": "items", "sort": "done", "limit": 10, "window": "all"}},
             "actions": {"setDone": {"set": "items.done", "to": \#(kind == "number" ? "1" : #""2026-11-18""#)}}}
            """#)
    }

    // MARK: Typed cells

    @Test func aBoolReadAsAnotherKindIsBlank() throws {
        let bench = try Bench()
        try bench.tap("add", at: noon)
        let row = try #require(bench.rows("newest", at: noon).first).key
        try bench.tap("finish", row: row, at: noon)
        #expect(try bench.rows("newest", at: noon).first?.flag("done") == true)

        let number = try Bench(store: bench.store, spec: redeclared("number"), widget: bench.widget)
        #expect(try number.rows("all", at: noon).first?.fields == ["title": .text("Oat milk")], "not 1")
        #expect(try number.number("doneSum", at: noon) == 0)
        let date = try Bench(store: bench.store, spec: redeclared("date"), widget: bench.widget)
        #expect(try date.rows("all", at: noon).first?.fields == ["title": .text("Oat milk")], "not 1970-01-02")

        try number.tap("setDone", row: row, at: "2026-11-18T12:01:00-05:00")
        #expect(try number.number("doneSum", at: noon) == 1)
        #expect(try bench.number("finished", at: noon) == 0, "a number 1 is not true")
        #expect(try bench.number("open", at: noon) == 1, "and a bool with no value counts as false")
        try bench.tap("flip", row: row, at: "2026-11-18T12:02:00-05:00")
        #expect(try bench.rows("newest", at: noon).first?.flag("done") == true, "toggle reads the number as false")
    }

    @Test func storedKindsComeFromLiveRowsOfEveryBoundDataset() throws {
        let bench = try Bench()
        #expect(try bench.store.storedKinds(of: bench.widget).isEmpty)
        try bench.tap("add", at: noon)
        try bench.tap("drink", at: noon)
        let row = try #require(bench.rows("newest", at: noon).first).key
        try bench.tap("finish", row: row, at: noon)
        #expect(
            try bench.store.storedKinds(of: bench.widget) == [
                "items": ["title": [.text], "size": [.number], "done": [.bool]]
            ])
        try bench.tap("remove", row: row, at: noon)
        #expect(try bench.store.storedKinds(of: bench.widget).isEmpty, "a deleted row's cells are never read")
    }

    // MARK: Datasets

    /// A row of dataset A on one replica, and the same widget on a second replica with nothing yet.
    func pair() throws -> (a: Bench, b: Bench, row: RowKey, dataset: DatasetKey) {
        let a = try Bench()
        try a.tap("add", at: noon)
        let b = try Bench(widget: a.widget)
        return (a, b, try #require(a.rows("newest", at: noon).first).key, try dataset(a))
    }

    @Test(arguments: [true, false]) func aChangeClaimingAnotherDatasetNeverTouchesTheRow(forgedFirst: Bool) throws {
        let (a, b, row, dataset) = try pair()
        let other = DatasetKey.mint()
        let later = try stamp("2026-11-18T13:00:00-05:00")
        let forged = [
            Stamped(change: .setCell(row, dataset: other, field: "title", .text("Forged")), stamp: later, replica: "z"),
            Stamped(change: .deleteRow(row, dataset: other), stamp: later, replica: "z"),
            Stamped(
                change: .insertRow(row, dataset: other, day: try day("2026-11-01"), at: 0), stamp: later, replica: "z"),
        ]
        if forgedFirst {
            try b.store.receive(forged)
            try b.store.receive(a.store.feed())
        } else {
            try b.store.receive(a.store.feed())
            try b.store.receive(forged)
        }
        let rows = try b.rows("oldest", at: noon)
        #expect(rows.map(\.key) == [row], "live, once, in its own dataset")
        #expect(rows.first?.day == (try day("2026-11-18")))
        #expect(rows.first?.text("title") == "Oat milk")
        #expect(try b.tap("rename", row: row, at: "2026-11-18T14:00:00-05:00") == .written)
        #expect(try b.rows("oldest", at: noon).first?.text("title") == "Renamed")
        #expect(try self.dataset(b) == dataset)
    }

    @Test func aDeleteOfTheRowsOwnDatasetStillWinsInEitherOrder() throws {
        let (a, b, row, dataset) = try pair()
        let delete = Stamped(
            change: .deleteRow(row, dataset: dataset), stamp: try stamp("2026-11-18T13:00:00-05:00"), replica: "z")
        try b.store.receive([delete])
        try b.store.receive(a.store.feed())
        try a.store.receive([delete])
        #expect(try a.rows("oldest", at: noon).isEmpty)
        #expect(try b.rows("oldest", at: noon).isEmpty)
    }

    @Test func everyChangeHasItsScope() throws {
        let row = RowKey(parsing: "0193f4c2-0000-7000-8000-000000000000")!
        let dataset = DatasetKey.mint()
        let widget = WidgetKey.mint()
        let digest = Spec.Digest(hex: String(repeating: "a", count: 64))!
        #expect(Change.insertRow(row, dataset: dataset, day: Day(index: 0), at: 0).scope == .dataset(dataset))
        #expect(Change.setCell(row, dataset: dataset, field: "f", .bool(true)).scope == .dataset(dataset))
        #expect(Change.deleteRow(row, dataset: dataset).scope == .dataset(dataset))
        #expect(Change.putRevision(body: Data()).scope == .account)
        #expect(Change.moveHead(widget, to: digest, createdAt: 0).scope == .account)
        #expect(Change.deleteWidget(widget).scope == .account)
        #expect(Change.bind(widget, table: "t", to: dataset).scope == .account)
    }

    @Test func theFeedIsGroupedByScopeAndBindingsStayInTheAccount() throws {
        let bench = try Bench()
        _ = try bench.store.save(bench.widget, spec: bench.spec, assets: [:])
        try bench.tap("add", at: noon)
        try bench.tap("drink", at: noon)
        let feed = try bench.store.changes()
        let glasses = try dataset(bench, "glasses")
        #expect(Set(feed.keys) == [.account, .dataset(try dataset(bench)), .dataset(glasses)])
        for (scope, changes) in feed {
            #expect(changes.allSatisfy { $0.change.scope == scope })
            #expect(changes.map(\.stamp) == changes.map(\.stamp).sorted(), "oldest first")
        }
        let binds = try #require(feed[.account]).filter { if case .bind = $0.change { true } else { false } }
        #expect(binds.count == 2)
        #expect(try #require(feed[.dataset(try dataset(bench))]).count == 3, "the row and its two values")
    }

    // MARK: Bounded input

    @Test func changesFromTooFarAheadAreHeldNotMerged() throws {
        let (a, b, row, dataset) = try pair()
        try b.store.receive(a.store.feed())
        let now = Date()
        let near = Stamped(
            change: .setCell(row, dataset: dataset, field: "title", .text("Near")), stamp: stamp(now + 9 * 60),
            replica: "z")
        let far = Stamped(
            change: .setCell(row, dataset: dataset, field: "size", .number(9)), stamp: stamp(now + 11 * 60),
            replica: "z")
        let received = try b.store.receive([near, far], now: now)
        #expect(received == Received(held: [far]))
        let item = try #require(b.rows("oldest", at: noon).first)
        #expect(item.text("title") == "Near")
        #expect(item.number("size") == 3, "the held value is not merged")

        try b.tap("rename", row: row, at: noon)
        let rename = try #require(
            b.store.feed().first { if case .setCell(_, _, field: "title", _) = $0.change { true } else { false } })
        #expect(rename.stamp > near.stamp, "the clock advanced past the merged stamp")
        #expect(rename.stamp < far.stamp, "but not past the held one")

        #expect(try b.store.receive(received.held, now: now + 2 * 60) == Received())
        #expect(try b.rows("oldest", at: noon).first?.number("size") == 9, "offered again in time, it merges")
    }

    @Test func textOverTheLimitIsRefused() throws {
        let (a, b, row, dataset) = try pair()
        try b.store.receive(a.store.feed())
        let at = try stamp("2026-11-18T13:00:00-05:00")
        let long = Stamped(
            change: .setCell(row, dataset: dataset, field: "title", .text(String(repeating: "a", count: 301))),
            stamp: at, replica: "z")
        let fits = Stamped(
            change: .setCell(row, dataset: dataset, field: "title", .text(String(repeating: "b", count: 300))),
            stamp: at, replica: "y")
        #expect(try b.store.receive([long], now: Date()) == Received(refused: [long]))
        #expect(try b.rows("oldest", at: noon).first?.text("title") == "Oat milk")
        #expect(try b.store.receive([fits], now: Date()) == Received())
        #expect(try b.rows("oldest", at: noon).first?.text("title")?.count == 300)
    }

    @Test func aNumberThatIsNotFiniteIsRefused() throws {
        let (a, b, row, dataset) = try pair()
        try b.store.receive(a.store.feed())
        let before = try b.rows("oldest", at: noon).first?.number("size")
        let at = try stamp("2026-11-18T13:00:00-05:00")
        let nan = Stamped(
            change: .setCell(row, dataset: dataset, field: "size", .number(.nan)), stamp: at, replica: "z")
        let received = try b.store.receive([nan], now: Date())
        // By stamp, because a NaN cell never equals itself.
        #expect(received.held.isEmpty && received.refused.map(\.stamp) == [at])
        #expect(try b.rows("oldest", at: noon).first?.number("size") == before)
    }

    // MARK: Proved revisions

    @Test func aReceivedHeadDrawsOnlyOnceProvedHere() throws {
        let a = try Bench()
        let b = try Bench(widget: a.widget)
        let renamed = { (name: String) in
            try parse(testDocument.replacingOccurrences(of: #""name": "Test""#, with: #""name": "\#(name)""#))
        }
        let first = try a.store.save(a.widget, spec: a.spec, assets: [:])
        #expect(try a.store.unprovedHeads().isEmpty, "a local save is proved")
        try b.store.receive(a.store.feed())
        #expect(try b.store.widgets().isEmpty, "a new widget stays hidden until proved")
        #expect(try b.store.widget(a.widget) == nil)
        #expect(try b.store.unprovedHeads() == [first])

        let before = try b.store.feed()
        try b.store.recordProof(of: first, verdict: nil)
        #expect(try b.store.feed() == before, "verdicts are local and never synced")
        #expect(try b.store.widget(a.widget)?.revision == first)

        let second = try a.store.save(a.widget, spec: renamed("Second"), assets: [:])
        try b.store.receive(a.store.feed())
        #expect(try b.store.widget(a.widget)?.revision == first, "the unproved head waits")
        #expect(try b.store.unprovedHeads() == [second])
        try b.store.recordProof(of: second, verdict: "the look drew nothing")
        #expect(try b.store.unprovedHeads().isEmpty)
        #expect(try b.store.widgets().map(\.revision) == [first], "a rejected revision never draws")

        let third = try a.store.save(a.widget, spec: renamed("Third"), assets: [:])
        try b.store.receive(a.store.feed())
        try b.store.recordProof(of: third, verdict: nil)
        #expect(try b.store.widget(a.widget)?.spec.name == "Third")
        try b.store.restore(a.widget, to: second)
        #expect(
            try b.store.widget(a.widget)?.revision == third, "restoring a rejected revision draws the last good one")
    }
}
