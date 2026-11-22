import CoreGraphics
import Foundation
import Spec
import Testing
import WidgetEngine

@testable import Rows

private let spec = try! document(
    #"""
    {
      "name": "Context",
      "look": "function render() { return { type: 'spacer' }; }",
      "tables": { "items": { "fields": { "title": "text", "done": "bool", "size": "number", "due": "date" } } },
      "queries": {
        "left": { "count": "items", "where": { "done": false }, "window": "all" },
        "total": { "sum": "items.size", "window": "all" },
        "last": { "latest": "items", "window": "today" },
        "open": { "list": "items", "window": "all", "limit": 5 },
        "week": { "daily": "items", "days": 2 }
      }
    }
    """#)

private func query(_ raw: String) -> Spec.QueryID { spec.queries.first { $0.id.raw == raw }!.id }

/// 09:00 UTC on Wednesday 2026-11-18, in a calendar whose week starts on Monday.
private let wednesday: Today = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return Today(at: try! Date("2026-11-18T09:00:00Z", strategy: .iso8601), calendar: calendar)
}()

@Suite struct ContextTests {
    @Test func encodesNumbersEmptyResultsDaysAndTheDate() {
        let json = lookContext(
            results: [
                query("left"): .number(3), query("total"): .number(2.5), query("last"): .row(nil),
                query("open"): .rows([]),
                query("week"): .days([
                    DayCount(day: wednesday.day.adding(-1), count: 2), DayCount(day: wednesday.day, count: 0),
                ]),
            ], spec: spec, family: .medium, size: CGSize(width: 338, height: 158), today: wednesday)
        #expect(
            json
                == #"{"data":{"last":null,"left":3,"open":[],"total":2.5,"week":[{"count":2,"date":"2026-11-17","weekday":"Tue"},{"count":0,"date":"2026-11-18","weekday":"Wed"}]},"family":"medium","height":158,"now":"09:00","today":{"date":"2026-11-18","week":["2026-11-16","2026-11-17","2026-11-18","2026-11-19","2026-11-20","2026-11-21","2026-11-22"],"weekday":"Wed"},"width":338}"#
        )
    }

    @Test func theDocumentedContextRunsALook() async throws {
        let json = lookContext(
            results: [query("left"): .number(3), query("last"): .row(nil)], spec: spec, family: .small,
            size: CGSize(width: 158, height: 158), today: wednesday)
        let look = """
            function render(ctx) {
              return { type: 'text', value: ctx.data.left + ' left on ' + ctx.today.weekday + ', ' + ctx.width + ' wide' };
            }
            """
        let drawing = try await compose(look, context: json, bindings: bindings(spec)).get()
        guard case .text(let run) = drawing.root.kind else {
            Issue.record("the root is not text")
            return
        }
        #expect(run.value == "3 left on Wed, 158 wide")
    }

    @Test func encodesRowsWithEveryFieldOfTheirTable() throws {
        let items = try #require(spec.table(named: "items"))
        let title = try #require(items.field(named: "title")).id
        let key = try #require(RowKey(parsing: "0193f4c2-0000-7000-8000-000000000001"))
        let written = wednesday.instant.addingTimeInterval(-2 * 86_400 - 95 * 60)
        let milk = RowValue(
            key: key, day: wednesday.day.adding(-2), at: written, by: RowAuthor(me: true, name: nil),
            values: [title: .text("Milk")])
        let results: [Spec.QueryID: QueryResult] = [query("last"): .row(milk), query("open"): .rows([milk])]
        let json = lookContext(
            results: results, spec: spec, family: .small, size: CGSize(width: 158, height: 158), today: wednesday)
        let row =
            #"{"at":"07:25","by":{"me":true,"name":null},"day":"2026-11-16","daysAgo":2,"done":false,"due":null,"id":"0193f4c2-0000-7000-8000-000000000001","minutesAgo":2975,"size":null,"title":"Milk"}"#
        #expect(json.contains(#""last":\#(row)"#))
        #expect(json.contains(#""open":[\#(row)]"#))
        #expect(Bindings.rows(in: results, spec: spec) == [items.id: [key.raw]])
    }

    @Test func encodesAnotherMembersRowAndClampsAFutureTime() throws {
        let key = try #require(RowKey(parsing: "0193f4c2-0000-7000-8000-000000000002"))
        let ahead = RowValue(
            key: key, day: wednesday.day, at: wednesday.instant.addingTimeInterval(120),
            by: RowAuthor(me: false, name: "Sam"), values: [:])
        let json = lookContext(
            results: [query("last"): .row(ahead)], spec: spec, family: .small, size: CGSize(width: 158, height: 158),
            today: wednesday)
        #expect(json.contains(#""at":"09:02","by":{"me":false,"name":"Sam"}"#))
        #expect(json.contains(#""minutesAgo":0"#))
    }

    @Test func readsRowTimesInTheReadersTimeZone() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let today = Today(at: wednesday.instant, calendar: tokyo)
        #expect(today.time == "18:00")
        #expect(today.clock(wednesday.instant.addingTimeInterval(-30 * 60)) == "17:30")
        #expect(today.minutes(since: wednesday.instant.addingTimeInterval(-61 * 60)) == 61)
    }
}
