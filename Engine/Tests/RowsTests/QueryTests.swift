import Foundation
import Rows
import Spec
import Testing

@Suite struct Shapes {
    let noon = "2026-11-18T12:00:00-05:00"

    /// The `busy` sample's items, as the look would receive their values.
    func items() throws -> (
        a: [String: Spec.Cell], b: [String: Spec.Cell], c: [String: Spec.Cell],
        d: [String: Spec.Cell], e: [String: Spec.Cell]
    ) {
        (
            ["title": .text("Oat milk"), "size": .number(3), "done": .bool(false)],
            ["title": .text("bread"), "size": .number(1), "done": .bool(true), "due": .date(try day("2026-11-20"))],
            ["title": .text("Apples"), "done": .bool(false), "due": .date(try day("2026-11-19"))],
            ["title": .text("Oat milk"), "size": .number(5)],
            ["size": .number(3), "done": .bool(true)]
        )
    }

    @Test func countSumAndWhereOnASeededSample() throws {
        let bench = try Bench()
        try bench.seed("busy", at: noon)
        #expect(try bench.number("glassesToday", at: noon) == 2)
        #expect(try bench.number("glassesWeek", at: noon) == 6)
        #expect(try bench.number("glassesAll", at: noon) == 8)
        #expect(try bench.number("open", at: noon) == 3, "a bool with no value counts as false")
        #expect(try bench.number("finished", at: noon) == 2)
        #expect(try bench.number("milk", at: noon) == 2, "a missing text matches nothing")
        #expect(try bench.number("three", at: noon) == 2)
        #expect(try bench.number("size", at: noon) == 12, "a row with no size adds nothing")
        #expect(try bench.number("openSize", at: noon) == 8)
        #expect(try bench.number("todaySize", at: noon) == 8)
    }

    @Test func listsAndLatestOnASeededSample() throws {
        let bench = try Bench()
        try bench.seed("busy", at: noon)
        let (a, b, c, d, e) = try items()
        #expect(try bench.rows("newest", at: noon).map(\.fields) == [e, d, c])
        #expect(try bench.rows("oldest", at: noon).map(\.fields) == [a, b, c, d, e])
        #expect(
            try bench.rows("oldest", at: noon).map(\.day)
                == ["2026-11-14", "2026-11-15", "2026-11-16", "2026-11-18", "2026-11-18"].map(day))
        #expect(try bench.rows("openList", at: noon).map(\.fields) == [a, c, d])
        #expect(
            try bench.rows("bySize", at: noon).map(\.fields) == [b, e, a, d, c], "ties newest first, no value last")
        #expect(try bench.rows("bySizeDown", at: noon).map(\.fields) == [d, e, a, b, c])
        #expect(try bench.rows("byTitle", at: noon).map(\.fields) == [c, b, d, a, e], "text sorts without case")
        #expect(try bench.rows("byDoneDown", at: noon).map(\.fields) == [e, b, d, c, a], "no value sorts as false")
        #expect(try bench.rows("byDue", at: noon).map(\.fields) == [c, b, e, d, a])
        #expect(try bench.rows("latestOpen", at: noon).map(\.fields) == [d])
        #expect(try bench.rows("itemsWeek", at: noon).map(\.fields) == [e, d, c], "Monday-first week is Nov 16 to 22")
        #expect(
            try bench.rows("itemsWeek", at: noon, firstWeekday: 1).map(\.fields) == [e, d, c, b],
            "Sunday-first week is Nov 15 to 21")
        #expect(try bench.rows("lastGlass", at: noon).map(\.day) == [try day("2026-11-18")])
    }

    @Test func streakAndDailyOnASeededSample() throws {
        let bench = try Bench()
        try bench.seed("busy", at: noon)
        #expect(try bench.number("streak", at: noon) == 3)
        let days = try bench.days("glassesDaily", at: noon)
        #expect(try days.map(\.day) == ["2026-11-16", "2026-11-17", "2026-11-18"].map(day), "oldest first, today last")
        #expect(days.map(\.count) == [1, 3, 2])
    }

    @Test func theEmptyStateReadsAsNothing() throws {
        let bench = try Bench()
        try bench.store.seed(Spec.empty, widget: bench.widget, today: bench.today(noon))
        #expect(try bench.number("glassesAll", at: noon) == 0)
        #expect(try bench.number("size", at: noon) == 0)
        #expect(try bench.number("streak", at: noon) == 0)
        #expect(try bench.read("lastGlass", at: noon) == .row(nil))
        #expect(try bench.read("newest", at: noon) == .rows([]))
        #expect(try bench.days("glassesDaily", at: noon).map(\.count) == [0, 0, 0])
    }

    @Test func theSynthesizedFullStateFillsEveryList() throws {
        let todo = try Bench(spec: fixture("todo"))
        try todo.store.seed(todo.spec.full, widget: todo.widget, today: todo.today(noon))
        #expect(try todo.number("left", at: noon) == 100)
        #expect(try todo.number("finished", at: noon) == 100)
        let open = try todo.rows("open", at: noon)
        #expect(open.count == 20)
        #expect(open.allSatisfy { $0.flag("done") == false && ($0.text("title")?.count ?? 0) > 20 })

        let habit = try Bench(spec: fixture("habit"))
        try habit.store.seed(habit.spec.full, widget: habit.widget, today: habit.today(noon))
        #expect(try habit.number("streak", at: noon) == 100)
        let days = try habit.days("days", at: noon)
        #expect(days.count == 35)
        #expect(days.last?.count == 100)
        #expect(days.dropLast().allSatisfy { $0.count == 1 })
    }

    @Test func rowsWrittenAroundMidnightLandOnTheirOwnDay() throws {
        let bench = try Bench()
        try bench.tap("drink", at: "2026-11-17T23:59:30-05:00")
        #expect(try bench.number("glassesToday", at: "2026-11-17T23:59:45-05:00") == 1)
        try bench.tap("drink", at: "2026-11-18T00:00:30-05:00")
        #expect(try bench.number("glassesToday", at: "2026-11-18T00:00:45-05:00") == 1)
        #expect(try bench.number("glassesAll", at: "2026-11-18T00:00:45-05:00") == 2)
        #expect(try bench.days("glassesDaily", at: "2026-11-18T00:00:45-05:00").map(\.count) == [0, 1, 1])
    }

    @Test func aRowKeepsTheDayItsWriterSaw() throws {
        let bench = try Bench(calendar: gregorian("America/Los_Angeles"))
        try bench.tap("drink", at: "2026-11-18T03:00:00Z")
        let reader = try Bench(store: bench.store, widget: bench.widget, calendar: gregorian("America/New_York"))
        #expect(try reader.number("glassesToday", at: "2026-11-18T09:00:00-05:00") == 0)
        #expect(try reader.days("glassesDaily", at: "2026-11-18T09:00:00-05:00").map(\.count) == [0, 1, 0])
    }

    @Test func theWeekStartsOnTheCalendarsFirstWeekday() throws {
        let bench = try Bench()
        try bench.tap("drink", at: "2026-11-14T12:00:00-05:00")
        try bench.tap("drink", at: "2026-11-15T12:00:00-05:00")
        let sundayEvening = "2026-11-15T20:00:00-05:00"
        #expect(try bench.number("glassesWeek", at: sundayEvening, firstWeekday: 2) == 2, "Mon Nov 9 to Sun Nov 15")
        #expect(try bench.number("glassesWeek", at: sundayEvening, firstWeekday: 1) == 1, "Sun Nov 15 to Sat Nov 21")
        try bench.tap("drink", at: "2026-11-16T12:00:00-05:00")
        let mondayEvening = "2026-11-16T20:00:00-05:00"
        #expect(try bench.number("glassesWeek", at: mondayEvening, firstWeekday: 2) == 1, "Mon Nov 16 to Sun Nov 22")
        #expect(try bench.number("glassesWeek", at: mondayEvening, firstWeekday: 1) == 2, "Sun Nov 15 to Sat Nov 21")
    }

    @Test func aDaylightSavingDayHoldsAllItsHours() throws {
        let fall = try Bench()
        for time in [
            "2026-11-01T00:30:00-04:00", "2026-11-01T01:30:00-04:00", "2026-11-01T01:30:00-05:00",
            "2026-11-01T23:30:00-05:00", "2026-11-02T00:30:00-05:00",
        ] {
            try fall.tap("drink", at: time)
        }
        #expect(try fall.number("glassesToday", at: "2026-11-01T23:45:00-05:00") == 4, "the 25-hour day")
        #expect(try fall.days("glassesDaily", at: "2026-11-02T08:00:00-05:00").map(\.count) == [0, 4, 1])

        let spring = try Bench()
        for time in [
            "2026-03-07T23:30:00-05:00", "2026-03-08T01:59:00-05:00", "2026-03-08T03:01:00-04:00",
            "2026-03-08T23:59:00-04:00", "2026-03-09T00:01:00-04:00",
        ] {
            try spring.tap("drink", at: time)
        }
        #expect(try spring.number("glassesToday", at: "2026-03-08T23:59:30-04:00") == 3, "the 23-hour day")
        #expect(try spring.days("glassesDaily", at: "2026-03-09T10:00:00-04:00").map(\.count) == [1, 3, 1])
    }

    @Test func deletedRowsAreInvisibleToEveryShape() throws {
        let bench = try Bench()
        try bench.tap("add", at: noon)
        try bench.tap("drink", at: noon)
        let item = try #require(bench.rows("newest", at: noon).first)
        let glass = try #require(bench.rows("lastGlass", at: noon).first)
        try bench.tap("remove", row: item.key, at: noon)
        try bench.tap("undo", row: glass.key, at: noon)
        #expect(try bench.number("open", at: noon) == 0)
        #expect(try bench.number("size", at: noon) == 0)
        #expect(try bench.number("streak", at: noon) == 0)
        #expect(try bench.rows("newest", at: noon).isEmpty)
        #expect(try bench.days("glassesDaily", at: noon).map(\.count) == [0, 0, 0])
    }
}

@Suite struct Streak {
    /// Taps `drink` at noon on each day, counted back from Wed 2026-11-18, then reads the streak at 18:00.
    func streak(_ daysAgo: [Int]) throws -> Double {
        let bench = try Bench()
        let today = try day("2026-11-18")
        for ago in daysAgo {
            try bench.tap("drink", at: today.adding(-ago).iso + "T12:00:00-05:00")
        }
        return try bench.number("streak", at: "2026-11-18T18:00:00-05:00")
    }

    @Test func endsToday() throws {
        #expect(try streak([0, 1, 2]) == 3)
    }

    @Test func endsYesterdayWhileTodayIsEmpty() throws {
        #expect(try streak([1, 2, 3]) == 3)
    }

    @Test func breaksOnAGap() throws {
        #expect(try streak([0, 1, 3, 4, 5]) == 2)
    }

    @Test func isZeroWhenTodayAndYesterdayAreEmpty() throws {
        #expect(try streak([2, 3, 4]) == 0)
    }

    @Test func countsDaysNotRows() throws {
        #expect(try streak([0, 0, 0, 1]) == 2)
    }
}
