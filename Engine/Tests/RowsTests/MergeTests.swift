import Foundation
import Rows
import Spec
import Testing

@Suite struct Merging {
    func at(_ minute: Int) -> String {
        String(format: "2026-11-18T10:%02d:00-05:00", minute)
    }

    /// Two replicas of one widget that both hold the same item, inserted by the first.
    func pair() throws -> (a: Bench, b: Bench, row: RowKey) {
        let a = try Bench()
        let b = try Bench(widget: a.widget)
        try a.tap("add", at: at(0))
        try b.store.receive(a.store.feed())
        return (a, b, try #require(b.rows("newest", at: at(59)).first).key)
    }

    func exchange(_ a: Bench, _ b: Bench, firstToB: Bool) throws {
        let fromA = try a.store.feed()
        let fromB = try b.store.feed()
        if firstToB {
            try b.store.receive(fromA)
            try a.store.receive(fromB)
        } else {
            try a.store.receive(fromB)
            try b.store.receive(fromA)
        }
    }

    func title(_ bench: Bench) throws -> String? {
        try #require(bench.rows("newest", at: at(59)).first).text("title")
    }

    func titleStamp(_ feed: [Stamped]) -> Stamp? {
        feed.first { if case .setCell(_, _, field: "title", _) = $0.change { true } else { false } }?.stamp
    }

    @Test(arguments: [true, false]) func aLaterStampWinsACell(firstToB: Bool) throws {
        let (a, b, row) = try pair()
        try a.tap("rename", row: row, at: at(10))
        try b.tap("edit", row: row, input: b.values(of: "typed"), at: at(11))
        try exchange(a, b, firstToB: firstToB)
        #expect(try title(a) == "Typed")
        #expect(try title(b) == "Typed")

        let (c, d, other) = try pair()
        try c.tap("rename", row: other, at: at(12))
        try d.tap("edit", row: other, input: d.values(of: "typed"), at: at(11))
        try exchange(c, d, firstToB: firstToB)
        #expect(try title(c) == "Renamed")
        #expect(try title(d) == "Renamed")
    }

    @Test(arguments: [true, false]) func equalStampsBreakByReplica(firstToB: Bool) throws {
        let (a, b, row) = try pair()
        try a.tap("rename", row: row, at: at(10))
        try b.tap("edit", row: row, input: b.values(of: "typed"), at: at(10))
        let fromA = try a.store.feed()
        let fromB = try b.store.feed()
        #expect(titleStamp(fromA) != nil)
        #expect(titleStamp(fromA) == titleStamp(fromB), "the two writes carry the same stamp")
        let winner = try #require(fromA.first?.replica) > (try #require(fromB.first?.replica)) ? "Renamed" : "Typed"
        try exchange(a, b, firstToB: firstToB)
        #expect(try title(a) == winner)
        #expect(try title(b) == winner)
    }

    @Test(arguments: [true, false]) func aDeleteWinsOverAConcurrentWrite(firstToB: Bool) throws {
        let (a, b, row) = try pair()
        try a.tap("remove", row: row, at: at(10))
        try b.tap("rename", row: row, at: at(20))
        try exchange(a, b, firstToB: firstToB)
        for bench in [a, b] {
            #expect(try bench.rows("newest", at: at(59)).isEmpty)
            #expect(try bench.number("open", at: at(59)) == 0)
        }
    }

    @Test func aTapAfterAWriteFromAFastClockStillTakesEffect() throws {
        let (a, b, row) = try pair()
        try a.tap("finish", row: row, at: "2026-11-18T11:00:00-05:00")
        try b.store.receive(a.store.feed())
        try b.tap("flip", row: row, at: at(30))
        #expect(
            try b.rows("newest", at: at(59)).first?.flag("done") == false,
            "the tap won although its wall clock is behind")
        try a.store.receive(b.store.feed())
        #expect(try a.rows("newest", at: at(59)).first?.flag("done") == false)
    }

    struct State: Equatable {
        let reads: [QueryResult]
        let widgets: [String]
        let history: [[Revision]]
    }

    /// What the store holds once every received head passed its proof here, since what draws depends on that.
    func state(_ bench: Bench, widgets keys: [WidgetKey]) throws -> State {
        try bench.store.proveAll()
        return State(
            reads: try bench.snapshot(at: at(59)),
            widgets: try bench.store.widgets().map { "\($0.key.raw) \($0.revision) \($0.createdAt)" },
            history: try keys.map { try bench.store.revisions(of: $0) })
    }

    @Test func anyDeliveryOrderWithRepeatsConverges() throws {
        let a = try Bench()
        let b = try Bench(widget: a.widget)
        let c = try Bench(widget: a.widget)
        for minute in 0..<3 { try a.tap("add", at: at(minute)) }
        try a.tap("drink", at: at(3))
        try b.store.receive(a.store.feed())
        try c.store.receive(a.store.feed())
        let items = try a.rows("oldest", at: at(59)).map(\.key)
        let glass = try #require(a.rows("lastGlass", at: at(59)).first).key

        try a.tap("flip", row: items[0], at: at(10))
        try b.tap("flip", row: items[0], at: at(10))
        try a.tap("rename", row: items[1], at: at(11))
        try b.tap("edit", row: items[1], input: b.values(of: "typed"), at: at(12))
        try b.tap("remove", row: items[2], at: at(13))
        try c.tap("rename", row: items[2], at: at(14))
        try c.tap("add", at: at(15))
        try c.tap("drink", at: at(16))
        try c.tap("undo", row: glass, at: at(17))
        try a.tap("undo", row: glass, at: at(18))
        let renamed = try parse(testDocument.replacingOccurrences(of: #""name": "Test""#, with: #""name": "Two""#))
        let other = WidgetKey.mint()
        _ = try a.store.save(a.widget, spec: a.spec, assets: [:])
        _ = try b.store.save(a.widget, spec: renamed, assets: [:])
        _ = try c.store.save(a.widget, spec: a.spec, assets: [:])
        _ = try c.store.save(other, spec: renamed, assets: [:])
        try c.store.delete(other)

        let all = try [a, b, c].flatMap { try $0.store.feed() }
        let keys = [a.widget, other]
        try a.store.receive(all)
        let expected = try state(a, widgets: keys)
        #expect(expected.widgets.count == 1)
        #expect(expected.history.map(\.count) == [2, 1])
        for bench in [b, c] {
            try bench.store.receive(all)
            #expect(try state(bench, widgets: keys) == expected)
        }

        var random = Seeded(state: 2026)
        for _ in 0..<40 {
            let fresh = try Bench(widget: a.widget)
            var deliveries = all.shuffled(using: &random)
            deliveries += (0..<all.count / 2).compactMap { _ in all.randomElement(using: &random) }
            deliveries.shuffle(using: &random)
            var rest = deliveries[...]
            while !rest.isEmpty {
                let size = Int.random(in: 1...8, using: &random)
                try fresh.store.receive(Array(rest.prefix(size)))
                rest = rest.dropFirst(size)
            }
            #expect(try state(fresh, widgets: keys) == expected)
        }
    }

    @Test func theFeedHoldsWhatThisReplicaWroteLastAfterTheWatermark() throws {
        let (a, b, row) = try pair()
        let mine = try a.store.feed()
        #expect(Set(mine.map(\.replica)).count == 1)
        try b.tap("rename", row: row, at: at(10))
        try b.tap("drink", at: at(11))
        try a.store.receive(b.store.feed())
        #expect(
            Set(try a.store.feed()) == Set(mine.filter { titleStamp([$0]) == nil }),
            "B now holds the title, and nothing else B wrote is A's")

        let watermark = try #require(mine.map(\.stamp).max())
        try a.tap("add", at: at(12))
        let later = try a.store.feed(after: watermark)
        #expect(later.count == 3, "the new row and its two values")
        #expect(later.allSatisfy { $0.stamp > watermark && $0.replica == mine.first?.replica })
    }
}
