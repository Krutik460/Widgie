import Foundation
import Rows
import Spec
import Testing

/// Items written over five days and glasses over four, shared by the test documents.
let busySample = #"""
    {
        "busy": {
          "items": [
            {"daysAgo": 4, "title": "Oat milk", "size": 3, "done": false},
            {"daysAgo": 3, "title": "bread", "size": 1, "done": true, "due": "2026-11-20"},
            {"daysAgo": 2, "title": "Apples", "done": false, "due": "2026-11-19"},
            {"daysAgo": 0, "title": "Oat milk", "size": 5},
            {"daysAgo": 0, "size": 3, "done": true}
          ],
          "glasses": [
            {"daysAgo": 0, "repeat": 2}, {"daysAgo": 1, "repeat": 3}, {"daysAgo": 2}, {"daysAgo": 4, "repeat": 2}
          ]
        }
    }
    """#

/// `items` has a field of every kind and `glasses` has none. Every query and action the tests use is here,
/// except the day-tracking ones in `dayDocument`, since a document holds at most 24 queries.
let testDocument = #"""
    {
      "name": "Test",
      "look": "function render(ctx) { return { type: 'spacer' }; }",
      "tables": {
        "glasses": {"fields": {}},
        "items": {"fields": {"title": "text", "done": "bool", "size": "number", "due": "date"}}
      },
      "queries": {
        "glassesToday": {"count": "glasses", "window": "today"},
        "glassesWeek": {"count": "glasses", "window": "week"},
        "glassesAll": {"count": "glasses", "window": "all"},
        "glassesDaily": {"daily": "glasses", "days": 3},
        "streak": {"streak": "glasses"},
        "lastGlass": {"latest": "glasses", "window": "today"},
        "open": {"count": "items", "where": {"done": false}, "window": "all"},
        "finished": {"count": "items", "where": {"done": true}, "window": "all"},
        "milk": {"count": "items", "where": {"title": "Oat milk"}, "window": "all"},
        "three": {"count": "items", "where": {"size": 3}, "window": "all"},
        "size": {"sum": "items.size", "window": "all"},
        "openSize": {"sum": "items.size", "where": {"done": false}, "window": "all"},
        "todaySize": {"sum": "items.size", "window": "today"},
        "newest": {"list": "items", "limit": 3, "window": "all"},
        "oldest": {"list": "items", "sort": "oldest", "limit": 10, "window": "all"},
        "openList": {"list": "items", "where": {"done": false}, "sort": "oldest", "limit": 10, "window": "all"},
        "bySize": {"list": "items", "sort": "size", "limit": 10, "window": "all"},
        "bySizeDown": {"list": "items", "sort": "-size", "limit": 10, "window": "all"},
        "byTitle": {"list": "items", "sort": "title", "limit": 10, "window": "all"},
        "byDoneDown": {"list": "items", "sort": "-done", "limit": 10, "window": "all"},
        "byDue": {"list": "items", "sort": "due", "limit": 10, "window": "all"},
        "latestOpen": {"latest": "items", "where": {"done": false}, "window": "all"},
        "itemsWeek": {"list": "items", "limit": 10, "window": "week"}
      },
      "actions": {
        "drink": {"insert": "glasses"},
        "undo": {"delete": "glasses"},
        "add": {"insert": "items", "values": {"title": "Oat milk", "size": 3}},
        "typed": {"insert": "items", "values": {"title": "Typed", "size": 7}},
        "finish": {"set": "items.done", "to": true},
        "rename": {"set": "items.title", "to": "Renamed"},
        "flip": {"toggle": "items.done"},
        "remove": {"delete": "items"},
        "edit": {"form": "items", "fields": ["title", "size"]}
      },
      "samples": \#(busySample)
    }
    """#

/// The tables of `testDocument` with per-day sums and filters, goal streaks, month and rolling windows, and
/// logging for a past day.
let dayDocument = #"""
    {
      "name": "Days",
      "look": "function render(ctx) { return { type: 'spacer' }; }",
      "tables": {
        "glasses": {"fields": {}},
        "items": {"fields": {"title": "text", "done": "bool", "size": "number", "due": "date"}}
      },
      "queries": {
        "glassesToday": {"count": "glasses", "window": "today"},
        "glassesAll": {"count": "glasses", "window": "all"},
        "glassesDaily": {"daily": "glasses", "days": 3},
        "streak": {"streak": "glasses"},
        "newest": {"list": "items", "limit": 3, "window": "all"},
        "glassesMonth": {"count": "glasses", "window": "month"},
        "glassesTwoDays": {"count": "glasses", "window": {"days": 2}},
        "sizeTwoDays": {"sum": "items.size", "window": {"days": 2}},
        "sizeDaily": {"daily": "items.size", "days": 5},
        "openDaily": {"daily": "items", "where": {"done": false}, "days": 5},
        "doneSizeDaily": {"daily": "items.size", "where": {"done": true}, "days": 5},
        "twoGlasses": {"streak": "glasses", "goal": 2},
        "threeGlasses": {"streak": "glasses", "goal": 3},
        "doneSize": {"streak": "items.size", "where": {"done": true}, "goal": 3},
        "openStreak": {"streak": "items", "where": {"done": false}}
      },
      "actions": {
        "drink": {"insert": "glasses"},
        "add": {"insert": "items", "values": {"title": "Oat milk", "size": 3}},
        "finish": {"set": "items.done", "to": true},
        "lateGlass": {"insertOn": "glasses"},
        "lateItem": {"insertOn": "items", "values": {"title": "Late", "size": 2}}
      },
      "samples": \#(busySample)
    }
    """#

func parse(_ json: String) throws -> Spec {
    try Spec.parse(Data(json.utf8))
}

let engineDirectory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

func fixture(_ name: String) throws -> Spec {
    try Spec.parse(Data(contentsOf: engineDirectory.appending(path: "Fixtures/\(name)/widget.json")))
}

func gregorian(_ zone: String = "America/New_York", firstWeekday: Int = 2) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: zone))
    calendar.firstWeekday = firstWeekday
    return calendar
}

func instant(_ iso: String) throws -> Date {
    try Date(iso, strategy: .iso8601)
}

func day(_ iso: String) throws -> Day {
    try #require(Day(iso: iso))
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "rows-tests-\(UUID().uuidString)")
}

/// One widget in one store, tapped and read the way the engine does: `Today` from an instant and a calendar.
/// A new widget gets a dataset for each table, as a save does. Passing an existing `widget` binds nothing, so
/// a second replica of it reads only what sync brings, bindings included.
struct Bench {
    let store: RowStore
    let spec: Spec
    let widget: WidgetKey
    let calendar: Calendar

    init(
        store: RowStore? = nil, spec: Spec? = nil, widget: WidgetKey? = nil, calendar: Calendar? = nil
    ) throws {
        self.store = try store ?? RowStore.scratch()
        self.spec = try spec ?? parse(testDocument)
        self.widget = widget ?? .mint()
        self.calendar = try calendar ?? gregorian()
        // Bound before every instant the tests write at, so the bind's stamp never outranks a tap's.
        if widget == nil {
            try self.store.bind(tablesOf: self.spec, to: self.widget, at: instant("2026-01-01T00:00:00Z"))
        }
    }

    func today(_ iso: String, firstWeekday: Int? = nil) throws -> Today {
        var calendar = calendar
        if let firstWeekday { calendar.firstWeekday = firstWeekday }
        return Today(at: try instant(iso), calendar: calendar)
    }

    @discardableResult
    func tap(
        _ action: String, row: RowKey? = nil, day: Day? = nil, input: [Spec.FieldValue] = [], at iso: String
    ) throws -> Applied {
        let date = try instant(iso)
        return try store.apply(
            try #require(spec.action(named: action)), widget: widget, row: row, day: day, input: input,
            today: Today(at: date, calendar: calendar), at: date)
    }

    func read(_ query: String, at iso: String, firstWeekday: Int? = nil) throws -> QueryResult {
        let found = try #require(spec.queries.first { $0.id.raw == query })
        let results = try store.results(of: [found], widget: widget, today: today(iso, firstWeekday: firstWeekday))
        return try #require(results[found.id])
    }

    func number(_ query: String, at iso: String, firstWeekday: Int? = nil) throws -> Double {
        guard case .number(let value) = try read(query, at: iso, firstWeekday: firstWeekday) else {
            Issue.record("\(query) is not a number")
            return .nan
        }
        return value
    }

    func rows(_ query: String, at iso: String, firstWeekday: Int? = nil) throws -> [RowValue] {
        switch try read(query, at: iso, firstWeekday: firstWeekday) {
        case .rows(let rows): return rows
        case .row(let row): return row.map { [$0] } ?? []
        default:
            Issue.record("\(query) is not rows")
            return []
        }
    }

    func days(_ query: String, at iso: String) throws -> [DayCount] {
        guard case .days(let days) = try read(query, at: iso) else {
            Issue.record("\(query) is not days")
            return []
        }
        return days
    }

    /// The values an insert action writes, which is how a test holds typed form input.
    func values(of action: String) throws -> [Spec.FieldValue] {
        guard case .insert(_, let values) = try #require(spec.action(named: action)).effect else {
            Issue.record("\(action) is not an insert")
            return []
        }
        return values
    }

    func seed(_ sample: String, at iso: String) throws {
        try store.seed(try #require(spec.sample(named: sample)), widget: widget, today: today(iso))
    }

    /// Everything a widget's reads can see, for comparing two stores.
    func snapshot(at iso: String) throws -> [QueryResult] {
        let today = try today(iso)
        let results = try store.results(of: spec.queries, widget: widget, today: today)
        return spec.queries.compactMap { results[$0.id] }
    }
}

extension RowValue {
    func text(_ field: String) -> String? {
        values.first { $0.key.raw == field }.flatMap { if case .text(let text) = $0.value { text } else { nil } }
    }

    func number(_ field: String) -> Double? {
        values.first { $0.key.raw == field }.flatMap { if case .number(let number) = $0.value { number } else { nil } }
    }

    func flag(_ field: String) -> Bool? {
        values.first { $0.key.raw == field }.flatMap { if case .bool(let flag) = $0.value { flag } else { nil } }
    }

    var fields: [String: Spec.Cell] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key.raw, $0.value) })
    }
}

/// SplitMix64, so a shuffled test replays the same orders every run.
struct Seeded: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
