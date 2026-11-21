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

    @Test func perDaySumsAndFiltersOnASeededSample() throws {
        let bench = try Bench(spec: parse(dayDocument))
        try bench.seed("busy", at: noon)
        let sizes = try bench.days("sizeDaily", at: noon)
        #expect(
            try sizes.map(\.day) == ["2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17", "2026-11-18"].map(day))
        #expect(sizes.map(\.sum) == [3, 1, 0, 0, 8], "a row with no size adds nothing; a day with no rows sums to 0")
        #expect(sizes.map(\.count) == [1, 1, 1, 0, 2])
        let open = try bench.days("openDaily", at: noon)
        #expect(open.map(\.count) == [1, 0, 1, 0, 1], "a bool with no value counts as false")
        #expect(open.allSatisfy { $0.sum == nil }, "a daily over a table has no sum")
        let done = try bench.days("doneSizeDaily", at: noon)
        #expect(done.map(\.sum) == [0, 1, 0, 0, 3])
        #expect(done.map(\.count) == [0, 1, 0, 0, 1])
    }

    @Test func monthAndRollingWindowsOnASeededSample() throws {
        let bench = try Bench(spec: parse(dayDocument))
        try bench.seed("busy", at: noon)
        #expect(try bench.number("glassesMonth", at: noon) == 8)
        #expect(try bench.number("glassesTwoDays", at: noon) == 5, "Nov 17 and 18")
        #expect(try bench.number("sizeTwoDays", at: noon) == 8)
    }

    @Test func theMonthIsTheCalendarMonthThatHoldsTodayUpToToday() throws {
        let bench = try Bench(spec: parse(dayDocument))
        for time in [
            "2026-10-31T23:30:00-04:00", "2026-11-01T00:30:00-04:00", "2026-11-30T23:00:00-05:00",
            "2026-12-01T09:00:00-05:00",
        ] {
            try bench.tap("drink", at: time)
        }
        #expect(try bench.number("glassesMonth", at: "2026-10-31T23:45:00-04:00") == 1)
        #expect(try bench.number("glassesMonth", at: "2026-11-01T08:00:00-05:00") == 1, "Nov 30 is still ahead")
        #expect(try bench.number("glassesMonth", at: "2026-11-30T23:30:00-05:00") == 2, "Nov 1 to 30")
        #expect(try bench.number("glassesMonth", at: "2026-12-01T10:00:00-05:00") == 1)
        #expect(try bench.number("glassesTwoDays", at: "2026-12-01T10:00:00-05:00") == 2, "Nov 30 and Dec 1")

        let leap = try Bench(spec: parse(dayDocument))
        try leap.tap("drink", at: "2028-02-29T12:00:00-05:00")
        try leap.tap("drink", at: "2028-03-01T12:00:00-05:00")
        #expect(try leap.number("glassesMonth", at: "2028-02-29T13:00:00-05:00") == 1, "February 2028 has 29 days")
    }

    /// A row written ahead for a later day, as the server writes a week of words: every window ends today.
    @Test func aRowOnALaterDayShowsOnlyOnceItsDayIsToday() throws {
        let tomorrow = "2026-11-19T12:00:00-05:00"
        let bench = try Bench()
        try bench.tap("add", at: tomorrow)
        try bench.tap("drink", at: tomorrow)
        for query in ["glassesToday", "glassesWeek", "glassesAll", "open", "milk", "size", "openSize", "todaySize"] {
            #expect(try bench.number(query, at: noon) == 0, "\(query) today")
            #expect(try bench.number(query, at: tomorrow) > 0, "\(query) tomorrow")
        }
        for query in ["lastGlass", "newest", "oldest", "bySize", "latestOpen", "itemsWeek"] {
            #expect(try bench.rows(query, at: noon).isEmpty, "\(query) today")
            #expect(try bench.rows(query, at: tomorrow).count == 1, "\(query) tomorrow")
        }

        let days = try Bench(spec: parse(dayDocument))
        try days.tap("add", at: tomorrow)
        try days.tap("drink", at: tomorrow)
        for query in ["glassesMonth", "glassesTwoDays", "sizeTwoDays", "streak"] {
            #expect(try days.number(query, at: noon) == 0, "\(query) today")
            #expect(try days.number(query, at: tomorrow) > 0, "\(query) tomorrow")
        }
        #expect(try days.days("glassesDaily", at: noon).map(\.count) == [0, 0, 0])
        #expect(try days.days("glassesDaily", at: tomorrow).map(\.count) == [0, 0, 1])
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

        let bench = try Bench(spec: parse(dayDocument))
        try bench.store.seed(bench.spec.full, widget: bench.widget, today: bench.today(noon))
        #expect(try bench.number("twoGlasses", at: noon) == 100, "every day of a goal streak meets the goal")
        #expect(try bench.number("doneSize", at: noon) == 100, "a filtered sum streak fills with matching rows")
        #expect(try bench.days("openDaily", at: noon).map(\.count).allSatisfy { $0 >= 1 })
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

    @Test func countsOnlyDaysThatReachTheGoal() throws {
        #expect(try streak([0, 0, 1, 1, 2], query: "twoGlasses") == 2)
        #expect(try streak([0, 0, 1, 1, 2, 2, 2], query: "twoGlasses") == 3, "more than the goal still counts")
        #expect(try streak([0, 0, 1, 2, 2], query: "twoGlasses") == 1, "a day short of the goal breaks it")
    }

    @Test func endsYesterdayWhileTodayIsShortOfTheGoal() throws {
        #expect(try streak([0, 1, 1, 2, 2], query: "twoGlasses") == 2)
        #expect(try streak([0, 2, 2], query: "twoGlasses") == 0)
    }

    @Test func sumsAFieldOfMatchingRowsAgainstTheGoal() throws {
        let bench = try Bench(spec: parse(dayDocument))
        let today = try day("2026-11-18")
        for ago in [2, 1, 0] {
            let time = today.adding(-ago).iso + "T12:00:00-05:00"
            try bench.tap("add", at: time)
            let added = try #require(bench.rows("newest", at: time).first)
            if ago != 1 { try bench.tap("finish", row: added.key, at: time) }
        }
        try bench.tap("add", at: today.adding(-1).iso + "T13:00:00-05:00")
        #expect(try bench.number("doneSize", at: "2026-11-18T18:00:00-05:00") == 1, "yesterday's rows are not done")
        #expect(
            try bench.number("openStreak", at: "2026-11-18T18:00:00-05:00") == 1,
            "only yesterday has open rows, and today has none yet")
    }

    @Test func decimalAmountsAddUpToTheirGoal() throws {
        let bench = try Bench(
            spec: parse(
                #"""
                {"name": "Pills", "look": "function render(ctx) { return { type: 'spacer' }; }",
                 "tables": {"doses": {"fields": {"mg": "number"}}},
                 "queries": {"kept": {"streak": "doses.mg", "goal": 1}, "week": {"daily": "doses.mg", "days": 2}},
                 "actions": {"tenth": {"insert": "doses", "values": {"mg": 0.1}}}}
                """#))
        for _ in 0..<10 { try bench.tap("tenth", at: "2026-11-17T12:00:00-05:00") }
        for _ in 0..<9 { try bench.tap("tenth", at: "2026-11-18T12:00:00-05:00") }
        #expect(try bench.number("kept", at: "2026-11-18T18:00:00-05:00") == 1, "ten tenths reach 1; nine do not")
        try bench.tap("tenth", at: "2026-11-18T13:00:00-05:00")
        #expect(try bench.number("kept", at: "2026-11-18T18:00:00-05:00") == 2)
    }

    func streak(_ daysAgo: [Int], query: String) throws -> Double {
        let bench = try Bench(spec: parse(dayDocument))
        let today = try day("2026-11-18")
        for ago in daysAgo {
            try bench.tap("drink", at: today.adding(-ago).iso + "T12:00:00-05:00")
        }
        return try bench.number(query, at: "2026-11-18T18:00:00-05:00")
    }
}
