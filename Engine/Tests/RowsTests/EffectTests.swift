import Foundation
import Rows
import Spec
import Testing

@Suite struct Effects {
    let noon = "2026-11-18T12:00:00-05:00"

    func item(_ bench: Bench) throws -> RowValue {
        try #require(bench.rows("newest", at: noon).first)
    }

    @Test func insertWritesARowOnTodayWithItsValues() throws {
        let bench = try Bench()
        #expect(try bench.tap("drink", at: noon) == .written)
        #expect(try bench.tap("add", at: noon) == .written)
        #expect(try bench.number("glassesToday", at: noon) == 1)
        let row = try item(bench)
        #expect(row.fields == ["title": .text("Oat milk"), "size": .number(3)])
        #expect(row.day == (try day("2026-11-18")))
    }

    @Test func insertOnWritesARowOnTheTappedDay() throws {
        let bench = try Bench(spec: parse(dayDocument))
        #expect(try bench.tap("lateGlass", day: try day("2026-11-17"), at: noon) == .written)
        #expect(try bench.tap("lateItem", day: try day("2026-11-16"), at: noon) == .written)
        #expect(try bench.number("glassesToday", at: noon) == 0)
        #expect(try bench.days("glassesDaily", at: noon).map(\.count) == [0, 1, 0])
        #expect(try bench.number("streak", at: noon) == 1, "yesterday's row keeps the streak alive")
        let row = try item(bench)
        #expect(row.fields == ["title": .text("Late"), "size": .number(2)])
        #expect(row.day == (try day("2026-11-16")))
        #expect(try bench.tap("lateGlass", day: try day("2026-11-18"), at: noon) == .written, "today is loggable")
    }

    @Test func insertOnReachesBackOneYearAndNeverAhead() throws {
        let bench = try Bench(spec: parse(dayDocument))
        #expect(try bench.tap("lateGlass", day: try day("2025-11-18"), at: noon) == .written)
        #expect(
            try bench.tap("lateGlass", day: try day("2025-11-17"), at: noon)
                == .ignored("day 2025-11-17 is not between 2025-11-18 and today, 2026-11-18"))
        #expect(
            try bench.tap("lateGlass", day: try day("2026-11-19"), at: noon)
                == .ignored("day 2026-11-19 is not between 2025-11-18 and today, 2026-11-18"))
        #expect(try bench.tap("lateGlass", at: noon) == .ignored("action lateGlass needs a day"))
        #expect(try bench.number("glassesAll", at: noon) == 1)
    }

    @Test func insertIgnoresADay() throws {
        let bench = try Bench()
        #expect(try bench.tap("drink", day: try day("2026-11-10"), at: noon) == .written)
        #expect(try bench.number("glassesToday", at: noon) == 1)
    }

    @Test func insertIgnoresATappedRow() throws {
        let bench = try Bench()
        try bench.tap("drink", at: noon)
        let glass = try #require(bench.rows("lastGlass", at: noon).first)
        #expect(try bench.tap("drink", row: glass.key, at: noon) == .written)
        #expect(try bench.number("glassesAll", at: noon) == 2)
    }

    @Test func setWritesOneFieldOfTheTappedRow() throws {
        let bench = try Bench()
        try bench.tap("add", at: noon)
        let row = try item(bench)
        #expect(try bench.tap("finish", row: row.key, at: noon) == .written)
        #expect(try bench.tap("rename", row: row.key, at: noon) == .written)
        #expect(try item(bench).fields == ["title": .text("Renamed"), "size": .number(3), "done": .bool(true)])
    }

    @Test func toggleFlipsAMissingBoolToTrueThenBack() throws {
        let bench = try Bench()
        try bench.tap("add", at: noon)
        let row = try item(bench)
        try bench.tap("flip", row: row.key, at: noon)
        #expect(try item(bench).flag("done") == true)
        try bench.tap("flip", row: row.key, at: noon)
        #expect(try item(bench).flag("done") == false)
        #expect(try bench.number("open", at: noon) == 1)
    }

    @Test func deleteTombstonesTheTappedRow() throws {
        let bench = try Bench()
        try bench.tap("add", at: noon)
        try bench.tap("add", at: noon)
        let row = try item(bench)
        #expect(try bench.tap("remove", row: row.key, at: noon) == .written)
        #expect(try bench.number("open", at: noon) == 1)
        #expect(try bench.rows("newest", at: noon).map(\.key).contains(row.key) == false)
    }

    @Test func aFormWithoutARowInsertsItsInput() throws {
        let bench = try Bench()
        #expect(try bench.tap("edit", input: bench.values(of: "typed"), at: noon) == .written)
        #expect(try item(bench).fields == ["title": .text("Typed"), "size": .number(7)])
    }

    @Test func aFormWithARowSetsOnlyItsInput() throws {
        let bench = try Bench()
        try bench.tap("add", at: noon)
        let row = try item(bench)
        try bench.tap("finish", row: row.key, at: noon)
        #expect(try bench.tap("edit", row: row.key, input: bench.values(of: "typed"), at: noon) == .written)
        #expect(try bench.rows("newest", at: noon).count == 1)
        #expect(try item(bench).fields == ["title": .text("Typed"), "size": .number(7), "done": .bool(true)])
    }

    @Test func aFormWithoutInputWritesNothing() throws {
        let bench = try Bench()
        #expect(try bench.tap("edit", at: noon) != .written)
        #expect(try bench.rows("newest", at: noon).isEmpty)
    }

    @Test func aSecondDeleteOnAStaleFaceDoesNothing() throws {
        let bench = try Bench()
        for _ in 0..<3 { try bench.tap("drink", at: noon) }
        let seen = try #require(bench.rows("lastGlass", at: noon).first)
        #expect(try bench.tap("undo", row: seen.key, at: noon) == .written)
        #expect(try bench.tap("undo", row: seen.key, at: noon) != .written)
        #expect(try bench.number("glassesToday", at: noon) == 2, "the count never drops below what the user saw")
    }

    @Test func staleTapsChangeNothing() throws {
        let bench = try Bench()
        try bench.tap("add", at: "2026-11-18T11:00:00-05:00")
        try bench.tap("add", at: noon)
        try bench.tap("drink", at: noon)
        let live = try item(bench)
        let deleted = try #require(bench.rows("oldest", at: noon).first)
        try bench.tap("remove", row: deleted.key, at: noon)
        let glass = try #require(bench.rows("lastGlass", at: noon).first)
        let unknown = try #require(RowKey(parsing: UUID().uuidString))
        let other = try Bench(store: bench.store)
        try other.tap("add", at: noon)
        let foreign = try item(other)

        let before = try bench.snapshot(at: noon)
        let stale: [(String, RowKey?)] = [
            ("finish", deleted.key), ("flip", deleted.key), ("remove", deleted.key), ("rename", deleted.key),
            ("edit", deleted.key),
            ("finish", glass.key), ("flip", glass.key), ("remove", glass.key), ("undo", live.key),
            ("finish", foreign.key), ("remove", foreign.key),
            ("finish", unknown), ("remove", unknown),
            ("finish", nil), ("flip", nil), ("remove", nil), ("undo", nil),
        ]
        for (action, row) in stale {
            let applied = try bench.tap(action, row: row, input: bench.values(of: "typed"), at: noon)
            #expect(applied != .written, "\(action) on \(row?.raw ?? "no row")")
        }
        #expect(try bench.snapshot(at: noon) == before)
        #expect(try other.rows("newest", at: noon).map(\.fields) == [foreign.fields])
    }

    @Test func valuesPrefillAFormOnlyForALiveRowOfTheTable() throws {
        let bench = try Bench()
        let items = try #require(bench.spec.table(named: "items"))
        let glasses = try #require(bench.spec.table(named: "glasses"))
        try bench.tap("add", at: noon)
        let row = try item(bench)
        #expect(
            try bench.store.values(of: row.key, in: items, widget: bench.widget)
                == ["title": .text("Oat milk"), "size": .number(3)].mapKeys(items))
        #expect(try bench.store.values(of: row.key, in: glasses, widget: bench.widget) == nil)
        #expect(try bench.store.values(of: row.key, in: items, widget: .mint()) == nil)
        try bench.tap("remove", row: row.key, at: noon)
        #expect(try bench.store.values(of: row.key, in: items, widget: bench.widget) == nil)
    }
}

extension [String: Spec.Cell] {
    func mapKeys(_ table: Spec.Table) -> [Spec.FieldID: Spec.Cell] {
        [Spec.FieldID: Spec.Cell](
            uniqueKeysWithValues: compactMap { key, value in table.field(named: key).map { ($0.id, value) } })
    }
}
