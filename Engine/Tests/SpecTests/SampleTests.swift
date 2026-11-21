import Foundation
import Spec
import Testing

/// Whether a row a state inserts would match a `where`: equal values match, and a bool field with no value
/// counts as false.
private func matches(_ row: Spec.SampleRow, _ filter: Spec.FieldValue?) -> Bool {
    guard let filter else { return true }
    if let value = row.values.first(where: { $0.field == filter.field }) { return value.value == filter.value }
    return filter.value == .bool(false)
}

private func rows(
    of sample: Spec.Sample, table: Spec.TableID, daysAgo: Int? = nil, matching filter: Spec.FieldValue? = nil
)
    -> Int
{
    sample.rows.filter { $0.table.id == table && (daysAgo == nil || $0.daysAgo == daysAgo) && matches($0, filter) }
        .reduce(0) { $0 + $1.count }
}

@Suite struct SampleTests {
    @Test func rowsDefaultToTodayAndOneEach() throws {
        let spec = try parse(withTables(#""samples": {"busy": {"glasses": [{}, {"daysAgo": 2, "repeat": 3}]}}"#))
        let busy = try #require(spec.sample(named: "busy"))
        #expect(busy.rows.map(\.daysAgo) == [0, 2])
        #expect(busy.rows.map(\.count) == [1, 3])
    }

    @Test func rowsKeepTheirOrderAndTypedValues() throws {
        let spec = try parse(
            withTables(
                #""samples": {"busy": {"items": [{"title": "b", "due": "2026-11-20"}, {"title": "a", "done": true, "size": 2.5}]}}"#
            ))
        let rows = try #require(spec.sample(named: "busy")).rows
        #expect(rows.count == 2)
        #expect(rows[0].values.map(\.value) == [.date(try #require(Day(iso: "2026-11-20"))), .text("b")])
        #expect(rows[1].values.map(\.field.path) == ["items.done", "items.size", "items.title"])
        #expect(rows[1].values.map(\.value) == [.bool(true), .number(2.5), .text("a")])
    }

    @Test func sampleOverAThousandRowsIsRefused() {
        let entries = Array(repeating: #"{"repeat": 100}"#, count: 11).joined(separator: ", ")
        #expect(
            rejection(withTables(#""samples": {"huge": {"glasses": [\#(entries)]}}"#))
                == #"sample "huge": 1100 rows after repeat; keep a sample to 1000 or fewer"#)
    }

    /// JavaScript holds text as UTF-16, so the limit counts UTF-16 units: an emoji is 2.
    @Test func textIsLimitedInUTF16Units() throws {
        func sample(_ title: String) -> String {
            withTables(#""samples": {"busy": {"items": [{"title": "\#(title)"}]}}"#)
        }
        _ = try parse(sample(String(repeating: "💧", count: 150)))
        #expect(
            rejection(sample(String(repeating: "💧", count: 151)))
                == #"sample "busy", items[0]: the value for "items.title" is 302 characters as JavaScript counts them (an emoji counts as 2); keep it to 300 or fewer"#
        )
        _ = try parse(sample(String(repeating: "a", count: 300)))
    }

    @Test func stateFilesUseTheSampleGrammar() throws {
        let spec = try Spec.parse(fixture("todo"))
        let state = try spec.parseState(
            Data(#"{"items": [{"daysAgo": 1, "title": "Buy milk"}]}"#.utf8), name: "rows.json")
        #expect(state.name == "rows.json")
        #expect(state.rows.first?.values.map(\.value) == [.text("Buy milk")])
        #expect(
            throws: Diagnostic(
                "no field \"due\" in items (fields: done, title)", at: ["state \"rows.json\"", "items[0]"])
        ) {
            try spec.parseState(Data(#"{"items": [{"due": "2026-11-18"}]}"#.utf8), name: "rows.json")
        }
    }

    @Test func emptyStateHasNoRows() {
        #expect(Spec.empty.name == "empty")
        #expect(Spec.empty.rows.isEmpty)
    }

    /// Specs whose queries do not share a filter, so no query's rows can stand in for another's.
    static let separateQueries = [
        #""queries": {"recent": {"list": "items", "where": {"done": true}, "window": "today", "limit": 30}}"#,
        #""queries": {"top": {"list": "items", "window": "week", "sort": "-size", "limit": 7}}"#,
        #""queries": {"total": {"sum": "items.size", "where": {"title": "Run"}, "window": "all"}}"#,
        #""queries": {"run": {"streak": "glasses"}}"#,
        #""queries": {"year": {"daily": "glasses", "days": 366}}"#,
        #""queries": {"goal": {"streak": "glasses", "goal": 8}}"#,
        #""queries": {"kept": {"streak": "items.size", "where": {"done": true}, "goal": 10}}"#,
        #""queries": {"open": {"daily": "items", "where": {"done": false}, "days": 14}}"#,
        #""queries": {"sizes": {"daily": "items.size", "where": {"title": "Run"}, "days": 7}}"#,
    ]

    @Test(arguments: referenceWidgets)
    func fullStateFillsEveryQueryOfAReferenceWidget(_ name: String) throws {
        try expectFull(Spec.parse(fixture(name)))
    }

    @Test(arguments: separateQueries)
    func fullStateFillsAQueryOnItsOwn(_ queries: String) throws {
        try expectFull(parse(withTables(queries)))
    }

    private func expectFull(_ spec: Spec) {
        let full = spec.full
        #expect(full.name == "full")
        for query in spec.queries {
            switch query.shape {
            case .list(let table, let filter, _, let limit, _):
                #expect(rows(of: full, table: table.id, daysAgo: 0, matching: filter) >= limit, "\(query.id)")
            case .count(let table, let filter, _):
                #expect(rows(of: full, table: table.id, daysAgo: 0, matching: filter) >= 100, "\(query.id)")
            case .sum(let field, let filter, _):
                #expect(rows(of: full, table: field.table, daysAgo: 0, matching: filter) >= 100, "\(query.id)")
            case .latest(let table, let filter, _):
                #expect(rows(of: full, table: table.id, daysAgo: 0, matching: filter) >= 1, "\(query.id)")
            case .streak(let measure, let filter, let goal):
                for daysAgo in 0..<100 {
                    #expect(
                        measured(full, measure, daysAgo: daysAgo, matching: filter) >= goal, "\(query.id) \(daysAgo)")
                }
            case .daily(let measure, let filter, let days):
                for daysAgo in 0..<days {
                    #expect(
                        rows(of: full, table: measure.table, daysAgo: daysAgo, matching: filter) >= 1, "\(query.id)")
                }
                #expect(rows(of: full, table: measure.table, daysAgo: 0, matching: filter) >= 100, "\(query.id)")
            }
        }
        for row in full.rows {
            for value in row.values {
                if case .text(let text) = value.value, value.field.kind == .text, !isFilterLiteral(value, spec) {
                    #expect(text.count >= 40, "\(value.field.path)")
                }
            }
        }
    }

    @Test func fullStateGivesEveryTextFieldOfALatestRowALongValue() throws {
        let full = try Spec.parse(fixture("wotd")).full
        let row = try #require(full.rows.first)
        #expect(row.values.map(\.field.id.raw) == ["definition", "example", "kind", "word"])
        #expect(row.values.allSatisfy { if case .text(let text) = $0.value { text.count >= 40 } else { false } })
    }

    @Test func fullStateWritesWhatTheWidgetCanStoreInEachField() throws {
        let spec = try parse(
            document(
                #""tables": {"moods": {"fields": {"mood": "text", "note": "text", "score": "number", "starred": "bool"}}}, "#
                    + #""queries": {"last": {"latest": "moods", "window": "all"}}, "#
                    + #""actions": {"#
                    + #""happy": {"insert": "moods", "values": {"mood": "🙂", "score": 5, "starred": false}}, "#
                    + #""meh": {"insert": "moods", "values": {"mood": "😐 meh", "score": 3}}, "#
                    + #""star": {"toggle": "moods.starred"}, "#
                    + #""write": {"form": "moods", "fields": ["note"]}}"#))
        let row = try #require(spec.full.rows.first)
        #expect(row.values.map(\.field.id.raw) == ["mood", "note", "score", "starred"])
        let note = try #require(row.values.first { $0.field.id.raw == "note" })
        #expect(
            note.value.text.map { $0.utf16.count == 300 && $0.hasPrefix("Water the plants") } == true,
            "the longest text a field holds")
        #expect(
            row.values.filter { $0.field.id.raw != "note" }.map(\.value) == [.text("😐 meh"), .number(5), .bool(true)])
    }

    /// A day's row count, or the sum of a field over the day's rows, among rows matching `filter`.
    private func measured(
        _ sample: Spec.Sample, _ measure: Spec.Measure, daysAgo: Int, matching filter: Spec.FieldValue?
    ) -> Double {
        let day = sample.rows.filter { $0.table.id == measure.table && $0.daysAgo == daysAgo && matches($0, filter) }
        guard case .total(let field) = measure else { return Double(day.reduce(0) { $0 + $1.count }) }
        return day.reduce(0) { total, row in
            guard case .number(let value)? = row.values.first(where: { $0.field == field.erased })?.value else {
                return total
            }
            return total + value * Double(row.count)
        }
    }

    private func isFilterLiteral(_ value: Spec.FieldValue, _ spec: Spec) -> Bool {
        spec.queries.contains { query in
            switch query.shape {
            case .count(_, let filter?, _), .sum(_, let filter?, _), .latest(_, let filter?, _),
                .list(_, let filter?, _, _, _), .streak(_, let filter?, _), .daily(_, let filter?, _):
                filter == value
            default: false
            }
        }
    }
}

extension Spec.Cell {
    fileprivate var text: String? {
        if case .text(let text) = self { text } else { nil }
    }
}
