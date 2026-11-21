import Foundation
import Spec
import Testing

/// Each class of mistake a model makes, and the one line it gets back. The line names where the problem is
/// and the valid choices, so the model can fix it in one repair.
struct Mistake: CustomTestStringConvertible, Sendable {
    let label: String
    let json: String
    let line: String

    var testDescription: String { label }
}

@Suite struct MistakeTests {
    static let jsonCases: [Mistake] = [
        Mistake(
            label: "trailing comma", json: #"{"name": "x",}"#,
            line: #"not valid JSON at line 1, column 14: remove the comma before "}""#),
        Mistake(
            label: "single quotes", json: #"{'name': 'x'}"#,
            line: "not valid JSON at line 1, column 2: use double quotes for keys, not single quotes"),
        Mistake(
            label: "duplicate key", json: #"{"name": "a", "name": "b"}"#,
            line: #"not valid JSON at line 1, column 15: the key "name" appears twice in one object"#),
        Mistake(
            label: "line and column on a later line", json: "{\n  \"name\": \"x\"\n  \"look\": \"y\"\n}",
            line: #"not valid JSON at line 3, column 3: expected "," or "}" after the value of "name""#),
        Mistake(
            label: "trailing comma in a list", json: #"{"name": ["x",]}"#,
            line: #"not valid JSON at line 1, column 15: remove the comma before "]""#),
        Mistake(
            label: "nested too deep", json: String(repeating: "[", count: 257) + String(repeating: "]", count: 257),
            line: "not valid JSON at line 1, column 257: values are nested more than 256 deep"),
        Mistake(label: "not an object", json: "[]", line: "the document must be a JSON object, not a list"),
    ]

    static let documentCases: [Mistake] = [
        Mistake(
            label: "unknown top-level key", json: document(#""title": "Water""#),
            line:
                #"unknown top-level key "title" (keys: actions, assets, automations, format, look, name, queries, samples, tables)"#
        ),
        Mistake(
            label: "missing name", json: #"{"look": "x"}"#,
            line: #"missing "name": what the widget picker shows, like "Water""#),
        Mistake(
            label: "missing look", json: #"{"name": "x"}"#,
            line: #"missing "look": the JavaScript source as one string that defines function render(ctx)"#),
        Mistake(
            label: "look as a tree", json: #"{"name": "x", "look": {"type": "text"}}"#,
            line: #""look" must be the JavaScript source as one string that defines function render(ctx)"#),
        Mistake(
            label: "empty look", json: #"{"name": "x", "look": "  "}"#,
            line: #""look" is empty; write the JavaScript source that defines function render(ctx)"#),
        Mistake(
            label: "newer format", json: #"{"format": 2, "name": "x", "look": "x"}"#,
            line: "format 2 is newer than this app reads (1); update the app"),
        Mistake(
            label: "format as a string", json: #"{"format": "1", "name": "x", "look": "x"}"#,
            line: #""format" must be a whole number; leave it out or write 1, not the string "1""#),
        Mistake(
            label: "format zero", json: #"{"format": 0, "name": "x", "look": "x"}"#,
            line: #"format 0 does not exist; leave "format" out or write 1"#),
        Mistake(
            label: "bad id", json: withTables(#""queries": {"Today": {"count": "glasses", "window": "today"}}"#),
            line: #"query "Today": an id starts with a lowercase letter and has only letters and digits, at most 32"#),
        Mistake(
            label: "too many tables",
            json: document(
                #""tables": {"#
                    + (1...9).map { #""t\#($0)": {}"# }.joined(separator: ", ") + "}"),
            line: "at most 8 tables, found 9"),
        Mistake(
            label: "asset without about", json: document(#""assets": {"fox": {}}"#),
            line: #"asset "fox": needs "about": what the picture shows"#),
    ]

    static let tablesCases: [Mistake] = [
        Mistake(
            label: "unknown field kind", json: document(#""tables": {"items": {"fields": {"done": "boolean"}}}"#),
            line: #"table "items": field "done" must be text, number, bool, or date, not the string "boolean""#),
        Mistake(
            label: "reserved field id", json: document(#""tables": {"items": {"fields": {"day": "date"}}}"#),
            line: #"table "items": field id "day" is reserved (reserved: day, daysAgo, id, newest, oldest, repeat)"#),
        Mistake(
            label: "table as a list", json: document(#""tables": {"items": ["title"]}"#),
            line: #"table "items": a table must be an object like {"fields": {"title": "text"}}, not a list"#),
    ]

    static let queriesCases: [Mistake] = [
        Mistake(
            label: "list and latest queries return too much",
            json: withTables(
                #""queries": {\#((0..<5).map { #""l\#($0)": {"list": "items", "window": "all", "limit": 100}"# }.joined(separator: ", ")), "last": {"latest": "items", "window": "all"}}"#
            ),
            line:
                "list and latest queries return up to 2004 field values together (rows times their table's fields, a latest counting one row); keep it to 1000 or fewer by lowering list limits"
        ),
        Mistake(
            label: "dangling table",
            json: document(
                #""tables": {"glasses": {"fields": {}}}, "queries": {"today": {"count": "glass", "window": "today"}}"#),
            line: #"query "today": no table "glass" (tables: glasses)"#),
        Mistake(
            label: "a field where a table goes",
            json: withTables(#""queries": {"x": {"count": "items.done", "window": "all"}}"#),
            line: #"query "x": count takes a table, not a field; write "items""#),
        Mistake(
            label: "no shape", json: withTables(#""queries": {"today": {"window": "today"}}"#),
            line:
                #"query "today": needs one of count, sum, latest, list, streak, daily, like {"count": "items", "window": "today"}"#
        ),
        Mistake(
            label: "two shapes", json: withTables(#""queries": {"x": {"count": "items", "list": "items"}}"#),
            line: #"query "x": has both "count" and "list"; use exactly one of count, sum, latest, list, streak, daily"#
        ),
        Mistake(
            label: "sum over a text field",
            json: withTables(#""queries": {"total": {"sum": "items.title", "window": "all"}}"#),
            line: #"query "total": sum needs a number field; "items.title" is text (number fields: items.size)"#),
        Mistake(
            label: "sum without a table", json: withTables(#""queries": {"total": {"sum": "size", "window": "all"}}"#),
            line: #"query "total": sum takes "table.field" (number fields: items.size), not "size""#),
        Mistake(
            label: "windowed streak", json: withTables(#""queries": {"run": {"streak": "glasses", "window": "week"}}"#),
            line: #"query "run": streak takes no "window"; it always counts back from today"#),
        Mistake(
            label: "missing window", json: withTables(#""queries": {"today": {"count": "glasses"}}"#),
            line:
                #"query "today": count needs "window": today, week, month, all, or {"days": 7} for the last 7 days with today last"#
        ),
        Mistake(
            label: "unknown window",
            json: withTables(#""queries": {"today": {"count": "glasses", "window": "this week"}}"#),
            line:
                #"query "today": "window" must be today, week, month, all, or {"days": 7} for the last 7 days with today last, not the string "this week""#
        ),
        Mistake(
            label: "rolling window without days",
            json: withTables(#""queries": {"x": {"count": "glasses", "window": {"last": 7}}}"#),
            line: #"query "x", window: takes only "days", not "last""#),
        Mistake(
            label: "rolling window too long",
            json: withTables(#""queries": {"x": {"count": "glasses", "window": {"days": 0}}}"#),
            line: #"query "x", window: "days" must be a whole number from 1 to 366, not the number 0"#),
        Mistake(
            label: "key of another shape",
            json: withTables(#""queries": {"x": {"count": "items", "window": "all", "limit": 5}}"#),
            line: #"query "x": count takes no "limit" (keys: count, where, window)"#),
        Mistake(
            label: "where compares a bool field to a string",
            json: withTables(
                #""queries": {"open": {"list": "items", "where": {"done": "no"}, "window": "all", "limit": 20}}"#),
            line: #"query "open", where: "items.done" is a bool field; give true or false, not the string "no""#),
        Mistake(
            label: "where with two fields",
            json: withTables(
                #""queries": {"x": {"count": "items", "where": {"done": false, "title": "a"}, "window": "all"}}"#),
            line: #"query "x": where takes exactly one field and a value, like {"done": false}; found 2 (done, title)"#),
        Mistake(
            label: "where on a date field",
            json: withTables(#""queries": {"x": {"count": "items", "where": {"due": "2026-11-18"}, "window": "all"}}"#),
            line:
                #"query "x": where cannot compare a date field ("items.due"); compare a text, number, or bool field, or sort by the date"#
        ),
        Mistake(
            label: "where on an unknown field",
            json: withTables(#""queries": {"x": {"count": "items", "where": {"status": "open"}, "window": "all"}}"#),
            line: #"query "x": where names no field "status" in items (fields: done, due, size, title)"#),
        Mistake(
            label: "where on daily names another table's field",
            json: withTables(#""queries": {"x": {"daily": "glasses", "days": 7, "where": {"done": true}}}"#),
            line: #"query "x": where names no field "done" in glasses (glasses has no fields)"#),
        Mistake(
            label: "daily over a text field",
            json: withTables(#""queries": {"x": {"daily": "items.title", "days": 7}}"#),
            line: #"query "x": daily needs a number field; "items.title" is text (number fields: items.size)"#),
        Mistake(
            label: "streak of a field without a goal",
            json: withTables(#""queries": {"x": {"streak": "items.size"}}"#),
            line:
                #"query "x": a streak of "items.size" needs "goal": the day's total that keeps the streak, like {"streak": "items.size", "goal": 2000}"#
        ),
        Mistake(
            label: "streak goal of zero",
            json: withTables(#""queries": {"x": {"streak": "glasses", "goal": 0}}"#),
            line: #"query "x": "goal" must be a whole number from 1 to 100, not the number 0"#),
        Mistake(
            label: "fractional goal on a row streak",
            json: withTables(#""queries": {"x": {"streak": "glasses", "goal": 2.5}}"#),
            line: #"query "x": "goal" must be a whole number from 1 to 100, not the number 2.5"#),
        Mistake(
            label: "negative goal on a field streak",
            json: withTables(#""queries": {"x": {"streak": "items.size", "goal": -5}}"#),
            line: #"query "x": "goal" must be a number above 0 and at most 1000000, like 8, not the number -5"#),
        Mistake(
            label: "goal on a count",
            json: withTables(#""queries": {"x": {"count": "glasses", "window": "today", "goal": 8}}"#),
            line: #"query "x": count takes no "goal" (keys: count, where, window)"#),
        Mistake(
            label: "list without limit", json: withTables(#""queries": {"x": {"list": "items", "window": "all"}}"#),
            line: #"query "x": list needs "limit": the most rows to return, a whole number from 1 to 100"#),
        Mistake(
            label: "limit out of range",
            json: withTables(#""queries": {"x": {"list": "items", "window": "all", "limit": 500}}"#),
            line: #"query "x": "limit" must be a whole number from 1 to 100, not the number 500"#),
        Mistake(
            label: "sort by an unknown field",
            json: withTables(#""queries": {"x": {"list": "items", "window": "all", "limit": 5, "sort": "priority"}}"#),
            line:
                #"query "x": "sort" must be newest, oldest, or a field of items (fields: done, due, size, title) with "-" in front to sort descending, not the string "priority""#
        ),
        Mistake(
            label: "daily days out of range", json: withTables(#""queries": {"x": {"daily": "glasses", "days": 400}}"#),
            line: #"query "x": "days" must be a whole number from 1 to 366, not the number 400"#),
    ]

    static let actionsCases: [Mistake] = [
        Mistake(
            label: "no effect", json: withTables(#""actions": {"go": {"open": "items"}}"#),
            line: #"action "go": needs one of insert, insertOn, set, toggle, delete, form, like {"insert": "items"}"#),
        Mistake(
            label: "insertOn with an unknown field",
            json: withTables(#""actions": {"late": {"insertOn": "items", "values": {"name": "Run"}}}"#),
            line: #"action "late", values: no field "name" in items (fields: done, due, size, title)"#),
        Mistake(
            label: "insertOn with a field target",
            json: withTables(#""actions": {"late": {"insertOn": "items.done"}}"#),
            line: #"action "late": insertOn takes a table, not a field; write "items""#),
        Mistake(
            label: "toggle on a text field", json: withTables(#""actions": {"flip": {"toggle": "items.title"}}"#),
            line: #"action "flip": toggle needs a bool field; "items.title" is text (bool fields: items.done)"#),
        Mistake(
            label: "set without to", json: withTables(#""actions": {"finish": {"set": "items.done"}}"#),
            line: #"action "finish": set needs "to": the value to store in "items.done", a bool"#),
        Mistake(
            label: "set to the wrong kind",
            json: withTables(#""actions": {"finish": {"set": "items.done", "to": "yes"}}"#),
            line: #"action "finish", to: "items.done" is a bool field; give true or false, not the string "yes""#),
        Mistake(
            label: "insert an unknown field",
            json: withTables(#""actions": {"add": {"insert": "items", "values": {"name": "x"}}}"#),
            line: #"action "add", values: no field "name" in items (fields: done, due, size, title)"#),
        Mistake(
            label: "delete with values", json: withTables(#""actions": {"rm": {"delete": "items", "values": {}}}"#),
            line: #"action "rm": delete takes no "values" (keys: delete)"#),
        Mistake(
            label: "form without fields", json: withTables(#""actions": {"add": {"form": "items", "fields": []}}"#),
            line:
                #"action "add": form needs "fields": a list of field ids of items to ask for (fields: done, due, size, title)"#
        ),
        Mistake(
            label: "form asks for an unknown field",
            json: withTables(#""actions": {"add": {"form": "items", "fields": ["name"]}}"#),
            line: #"action "add": form asks for no field "name" in items (fields: done, due, size, title)"#),
    ]

    static let automationsCases: [Mistake] = [
        Mistake(
            label: "unknown cadence",
            json: withTables(#""automations": {"daily": {"prompt": "p", "every": "morning", "writes": "items"}}"#),
            line: #"automation "daily": "every" must be hour, day, or week, not the string "morning""#),
        Mistake(
            label: "twelve-hour time",
            json: withTables(
                #""automations": {"daily": {"prompt": "p", "every": "day", "at": "6am", "writes": "items"}}"#),
            line: #"automation "daily": "at" must be a time of day like "06:00" (24-hour), not the string "6am""#),
        Mistake(
            label: "weekly without a weekday",
            json: withTables(
                #""automations": {"weekly": {"prompt": "p", "every": "week", "at": "09:00", "writes": "items"}}"#),
            line:
                #"automation "weekly": every week needs "on": the weekday it runs (monday, tuesday, wednesday, thursday, friday, saturday, sunday)"#
        ),
        Mistake(
            label: "writes an unknown table",
            json: withTables(
                #""automations": {"daily": {"prompt": "p", "every": "day", "at": "06:00", "writes": "word"}}"#),
            line: #"automation "daily": no table "word" (tables: glasses, items)"#),
        Mistake(
            label: "unknown time zone",
            json: withTables(
                #""automations": {"daily": {"prompt": "p", "every": "day", "at": "06:00", "writes": "items", "timeZone": "Mars/Base"}}"#
            ),
            line:
                #"automation "daily": "timeZone" must be a time zone name like "America/Los_Angeles", not the string "Mars/Base""#
        ),
    ]

    static let samplesCases: [Mistake] = [
        Mistake(
            label: "sample of an unknown table", json: withTables(#""samples": {"busy": {"glass": [{"daysAgo": 0}]}}"#),
            line: #"sample "busy": no table "glass" (tables: glasses, items)"#),
        Mistake(
            label: "sample field the table lacks",
            json: withTables(#""samples": {"busy": {"glasses": [{"daysAgo": 0, "ml": 250}]}}"#),
            line: #"sample "busy", glasses[0]: no field "ml" in glasses (glasses has no fields)"#),
        Mistake(
            label: "sample value of the wrong kind",
            json: withTables(#""samples": {"busy": {"items": [{"title": "a"}, {"done": "yes"}]}}"#),
            line: #"sample "busy", items[1]: "items.done" is a bool field; give true or false, not the string "yes""#),
        Mistake(
            label: "row in the future", json: withTables(#""samples": {"busy": {"glasses": [{"daysAgo": -1}]}}"#),
            line: #"sample "busy", glasses[0]: "daysAgo" must be a whole number from 0 to 400, not the number -1"#),
        Mistake(
            label: "repeat zero", json: withTables(#""samples": {"busy": {"glasses": [{"repeat": 0}]}}"#),
            line: #"sample "busy", glasses[0]: "repeat" must be a whole number from 1 to 100, not the number 0"#),
        Mistake(
            label: "reserved sample name", json: withTables(#""samples": {"full": {}}"#),
            line: #"sample "full": the name "full" is reserved for a state the builder makes; pick another"#),
        Mistake(
            label: "sample row with an id",
            json: withTables(#""samples": {"busy": {"items": [{"id": "t1", "title": "a"}]}}"#),
            line: #"sample "busy", items[0]: "id" is made by the app; leave it out"#),
        Mistake(
            label: "sample row that is not an object", json: withTables(#""samples": {"busy": {"glasses": [3]}}"#),
            line: #"sample "busy", glasses[0]: a row must be an object like {"daysAgo": 0}, not the number 3"#),
    ]

    static let all =
        jsonCases + documentCases + tablesCases + queriesCases + actionsCases + automationsCases + samplesCases

    @Test(arguments: all)
    func producesItsLine(_ mistake: Mistake) {
        #expect(rejection(mistake.json) == mistake.line)
    }

    @Test func everyLineIsOneLine() {
        for mistake in Self.all {
            #expect(!(rejection(mistake.json) ?? "\n").contains("\n"), "\(mistake.label)")
        }
    }

    @Test func refinementThatChangesAFieldKindIsRefused() throws {
        let before = try Spec.parse(fixture("todo"))
        let after = try parse(document(#""tables": {"items": {"fields": {"title": "text", "done": "text"}}}"#))
        #expect(
            throws: Diagnostic("field \"items.done\" was bool and is now text; keep the kind or use a new field id")
        ) {
            try after.checkCompatible(replacing: before)
        }
    }

    @Test func refinementMayAddRemoveAndKeepFields() throws {
        let before = try Spec.parse(fixture("todo"))
        let after = try parse(
            document(
                #""tables": {"items": {"fields": {"title": "text", "due": "date"}}, "notes": {"fields": {"done": "text"}}}"#
            ))
        try after.checkCompatible(replacing: before)
    }
}
