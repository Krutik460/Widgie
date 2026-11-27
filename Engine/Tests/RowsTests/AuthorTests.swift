import Foundation
import Rows
import Spec
import Testing

private let shared = #"""
    {
      "name": "Shared",
      "look": "function render() { return { type: 'spacer' }; }",
      "tables": { "hearts": { "fields": { "big": "bool" } } },
      "queries": {
        "sent": { "count": "hearts", "where": { "by": "me" }, "window": "today" },
        "received": { "count": "hearts", "where": { "by": "others" }, "window": "today" },
        "last": { "latest": "hearts", "window": "all" },
        "lastFromThem": { "latest": "hearts", "where": { "by": "others" }, "window": "all" },
        "bigFromMe": { "count": "hearts", "where": { "by": "me", "big": true }, "window": "all" }
      },
      "actions": { "send": { "insert": "hearts" } },
      "samples": {
        "both": {
          "hearts": [
            { "minutesAgo": 200, "by": "Sam", "repeat": 2 },
            { "minutesAgo": 30, "by": "Sam" },
            { "minutesAgo": 10, "big": true },
            { "minutesAgo": 11, "big": false },
            { "minutesAgo": 12, "by": "Sam", "big": true },
            { "daysAgo": 1, "by": "Sam" }
          ]
        }
      }
    }
    """#

@Suite struct Authors {
    let noon = "2026-11-18T12:00:00-05:00"

    @Test func aTapIsMineAndHasItsTime() throws {
        let bench = try Bench(spec: parse(shared))
        try bench.tap("send", at: "2026-11-18T09:41:00-05:00")
        let row = try #require(bench.rows("last", at: noon).first)
        #expect(row.by.me && row.by.name == nil)
        #expect(row.at == (try instant("2026-11-18T09:41:00-05:00")))
        #expect(try bench.number("sent", at: noon) == 1)
        #expect(try bench.number("received", at: noon) == 0)
    }

    @Test func seededRowsByAnotherMemberAreTheirsAndNamed() throws {
        let bench = try Bench(spec: parse(shared))
        try bench.seed("both", at: noon)
        #expect(try bench.number("sent", at: noon) == 2)
        #expect(try bench.number("received", at: noon) == 4, "yesterday's heart is outside today")
        #expect(try bench.number("bigFromMe", at: noon) == 1, "by and a field together")
        let theirs = try #require(bench.rows("lastFromThem", at: noon).first)
        #expect(!theirs.by.me && theirs.by.name == "Sam")
        let minutes = try instant(noon).timeIntervalSince(theirs.at) / 60
        #expect((12..<13).contains(minutes), "placed 12 minutes before the seed's instant")
        let last = try #require(bench.rows("last", at: noon).first)
        #expect(last.by.me, "the newest heart is the one sent 10 minutes ago")
    }

    @Test func minutesAgoCrossingMidnightLandsOnThePreviousDay() throws {
        let bench = try Bench(spec: parse(shared))
        try bench.seed("both", at: "2026-11-18T02:00:00-05:00")
        #expect(
            try bench.number("received", at: "2026-11-18T02:00:00-05:00") == 2,
            "only the 30- and 12-minute hearts are today")
    }

    @Test func aTodayRowWithoutMinutesIsNeverInTheFuture() throws {
        let spec = try parse(
            shared.replacingOccurrences(of: #"{ "minutesAgo": 10, "big": true }"#, with: #"{ "daysAgo": 0 }"#))
        let bench = try Bench(spec: spec)
        let morning = "2026-11-18T08:00:00-05:00"
        try bench.seed("both", at: morning)
        let mine = try #require(bench.rows("last", at: morning).first)
        #expect(mine.at <= (try instant(morning)), "midday would be four hours ahead")
    }

    @Test func aSeededDateFromTodayIsCountedFromTheSeedsDay() throws {
        let spec = try parse(
            #"""
            {
              "name": "Trip", "look": "function render() { return { type: 'spacer' }; }",
              "tables": { "trips": { "fields": { "date": "date" } } },
              "queries": { "trip": { "latest": "trips", "window": "all" } },
              "samples": { "soon": { "trips": [{ "date": { "daysFromToday": 12 } }] } }
            }
            """#)
        let bench = try Bench(spec: spec)
        let late = "2026-11-27T23:30:00-05:00"
        try bench.seed("soon", at: late)
        let trip = try #require(bench.rows("trip", at: late).first)
        #expect(trip.values.first { $0.key.raw == "date" }?.value == .date(try #require(Day(iso: "2026-12-09"))))
    }

    /// A glass from 30 or 240 minutes ago that `staysToday` counts for today at any hour, and is never placed
    /// before today began or after the seed's instant. New York springs forward on 2026-03-08 and falls back on
    /// 2026-11-01, so those days are 23 and 25 hours long.
    @Test func aRowThatStaysTodayIsOnTodayJustAfterMidnightAndAcrossTheClockChange() throws {
        let spec = try parse(
            #"""
            {
              "name": "Water", "look": "function render() { return { type: 'spacer' }; }",
              "tables": { "glasses": { "fields": {} } },
              "queries": {
                "today": { "count": "glasses", "window": "today" },
                "last": { "latest": "glasses", "window": "all" }
              },
              "samples": {
                "half an hour": { "glasses": [{ "minutesAgo": 30, "staysToday": true }] },
                "this morning": { "glasses": [{ "minutesAgo": 240, "staysToday": true }] },
                "drifts": { "glasses": [{ "minutesAgo": 30 }] }
              }
            }
            """#)
        func placed(_ sample: String, at iso: String) throws -> (today: Double, minutesAgo: Double) {
            let bench = try Bench(spec: spec)
            try bench.seed(sample, at: iso)
            let at = try #require(bench.rows("last", at: iso).first).at
            return (try bench.number("today", at: iso), try instant(iso).timeIntervalSince(at) / 60)
        }
        let noon = try placed("half an hour", at: "2026-11-18T12:00:00-05:00")
        #expect(noon.today == 1 && (30..<30.1).contains(noon.minutesAgo), "30 minutes ago when today allows it")
        let justAfter = try placed("half an hour", at: "2026-11-18T00:02:00-05:00")
        #expect(justAfter.today == 1, "kept on today just after midnight")
        #expect((1.9...2).contains(justAfter.minutesAgo), "placed as today began, never in the future")
        #expect(
            try placed("drifts", at: "2026-11-18T00:02:00-05:00").today == 0,
            "without staysToday the same row is yesterday's")
        // 03:30 on the short day is 150 minutes after midnight, so 240 minutes ago is the day before.
        let spring = try placed("this morning", at: "2026-03-08T03:30:00-04:00")
        #expect(spring.today == 1 && (149.9...150).contains(spring.minutesAgo), "the 23-hour day")
        // 01:30 after the clocks go back is 150 minutes after midnight on the long day.
        let fall = try placed("this morning", at: "2026-11-01T01:30:00-05:00")
        #expect(fall.today == 1 && (149.9...150).contains(fall.minutesAgo), "the 25-hour day")
    }

    /// New York springs forward on 2026-03-08: midnight to noon is 660 minutes, less than `full`'s 719, and
    /// its today rows must still land on today.
    @Test func fullStaysOnTodayOnASpringForwardDay() throws {
        let spec = try parse(shared)
        let bench = try Bench(spec: spec)
        let noon = "2026-03-08T12:00:00-04:00"
        try bench.store.seed(spec.full, widget: bench.widget, today: bench.today(noon))
        #expect(try bench.number("sent", at: noon) >= 100)
        #expect(try bench.number("received", at: noon) >= 100)
    }
}
