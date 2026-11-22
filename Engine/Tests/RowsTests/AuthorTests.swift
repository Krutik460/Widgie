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
}
