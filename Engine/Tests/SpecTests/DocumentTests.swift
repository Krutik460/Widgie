import Foundation
import Spec
import Testing

@Suite struct DocumentTests {
    @Test func canonicalBytesSortKeysAndWriteDefaults() throws {
        let reply = """
            {
              "name": "Water",
              "look": "function render(ctx) {}",
              "tables": { "glasses": {} },
              "queries": { "week": { "window": "week", "list": "glasses", "limit": 7 } },
              "actions": { "drink": { "insert": "glasses" } },
              "samples": { "one": { "glasses": [ {} ] } }
            }
            """
        let canonical = String(decoding: try parse(reply).encoded(), as: UTF8.self)
        #expect(
            canonical
                == #"{"actions":{"drink":{"insert":"glasses","values":{}}},"assets":{},"automations":{},"format":1,"look":"function render(ctx) {}","name":"Water","queries":{"week":{"limit":7,"list":"glasses","sort":"newest","window":"week"}},"samples":{"one":{"glasses":[{"daysAgo":0,"repeat":1}]}},"tables":{"glasses":{"fields":{}}}}"#
        )
    }

    @Test func keyOrderAndWhitespaceDoNotChangeTheBytes() throws {
        let one = try parse(#"{"name":"A","look":"x","tables":{"t":{"fields":{"b":"bool","a":"text"}}}}"#)
        let two = try parse(
            #"{ "tables" : { "t" : { "fields" : { "a" : "text", "b" : "bool" } } }, "look" : "x", "name" : "A" }"#)
        #expect(one == two)
        #expect(one.encoded() == two.encoded())
    }

    @Test func stringsWithQuotesNewlinesAndEmojiRoundTrip() throws {
        let look = "function render(ctx) {\n  return { type: 'text', value: \"Say \\\"hi\\\" \u{1F44B}\\t\" };\n}"
        let spec = try parse(document(#""samples": {}"#).replacingOccurrences(of: minimalLook, with: escaped(look)))
        #expect(spec.look == look)
        #expect(try Spec.parse(spec.encoded()).look == look)
    }

    @Test func missingFormatMeansCurrent() throws {
        let withFormat = try parse(#"{"format": 1, "name": "x", "look": "y"}"#)
        let without = try parse(#"{"name": "x", "look": "y"}"#)
        #expect(withFormat == without)
        #expect(Spec.currentFormat == 1)
    }

    @Test func nullMeansAbsent() throws {
        let spec = try parse(
            withTables(#""queries": {"x": {"count": "items", "where": null, "window": "all"}}, "assets": null"#))
        guard case .count(_, nil, .all)? = spec.query("x")?.shape else {
            Issue.record("a null where should read as no where")
            return
        }
        #expect(spec.assets.isEmpty)
    }

    @Test func fillingTimeZoneKeepsAZoneAlreadyThere() throws {
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let filled = try Spec.parse(fixture("wotd")).fillingTimeZone(losAngeles)
        #expect(filled.automations.first?.schedule.timeZone == losAngeles)
        #expect(filled.fillingTimeZone(tokyo).automations.first?.schedule.timeZone == losAngeles)
        let reparsed = try Spec.parse(filled.encoded())
        #expect(reparsed == filled)
        #expect(String(decoding: filled.encoded(), as: UTF8.self).contains(#""timeZone":"America/Los_Angeles""#))
    }

    @Test func fillingDigestsRecordsTheBytesBehindEachAsset() throws {
        let spec = try parse(document(#""assets": {"fox": {"about": "a watercolor fox"}}"#))
        #expect(spec.asset(named: "fox")?.digest == nil)
        let digest = try #require(Spec.Digest(hex: String(repeating: "ab", count: 32)))
        let fox = try #require(spec.asset(named: "fox")?.id)
        let filled = spec.fillingDigests([fox: digest])
        #expect(filled.asset(named: "fox")?.digest == digest)
        #expect(try Spec.parse(filled.encoded()) == filled)
        #expect(Spec.Digest(hex: String(repeating: "AB", count: 32)) == nil)
        #expect(Spec.Digest(hex: "abc") == nil)
    }

    @Test func dailyAutomationRunsAtItsWallClockTime() throws {
        let spec = try Spec.parse(fixture("wotd")).fillingTimeZone(
            try #require(TimeZone(identifier: "America/Los_Angeles")))
        let schedule = try #require(spec.automations.first?.schedule)
        #expect(schedule.nextRun(after: try instant("2026-11-18T13:00:00Z")) == (try instant("2026-11-18T14:00:00Z")))
        #expect(schedule.nextRun(after: try instant("2026-11-18T14:00:00Z")) == (try instant("2026-11-19T14:00:00Z")))
        #expect(schedule.nextRun(after: try instant("2026-03-08T12:00:00Z")) == (try instant("2026-03-08T13:00:00Z")))
    }

    @Test func weeklyAndHourlyAutomationsRunOnTheirSchedule() throws {
        let spec = try parse(
            withTables(
                #""automations": {"weekly": {"prompt": "p", "every": "week", "on": "monday", "at": "09:00", "writes": "items", "timeZone": "UTC"}, "hourly": {"prompt": "p", "every": "hour", "at": ":15", "writes": "items", "timeZone": "UTC"}}"#
            ))
        let weekly = try #require(spec.automations.first { $0.id.raw == "weekly" }?.schedule)
        let hourly = try #require(spec.automations.first { $0.id.raw == "hourly" }?.schedule)
        #expect(weekly.cadence == .weekly(.monday, hour: 9, minute: 0))
        #expect(weekly.nextRun(after: try instant("2026-11-18T10:00:00Z")) == (try instant("2026-11-23T09:00:00Z")))
        #expect(hourly.nextRun(after: try instant("2026-11-18T10:20:00Z")) == (try instant("2026-11-18T11:15:00Z")))
        #expect(try Spec.parse(spec.encoded()) == spec)
    }

    @Test func scheduleWithoutATimeZoneHasNoNextRun() throws {
        let schedule = try #require(try Spec.parse(fixture("wotd")).automations.first?.schedule)
        #expect(schedule.nextRun(after: .now) == nil)
    }

    @Test func runtimeNamesResolveOnlyToWhatTheDocumentDeclares() throws {
        let spec = try Spec.parse(fixture("todo"))
        #expect(spec.action(named: "toggle") != nil)
        #expect(spec.action(named: "Toggle") == nil)
        #expect(spec.action(named: "explode") == nil)
        #expect(spec.sample(named: "busy") != nil)
        #expect(spec.table(named: "items")?.field(named: "done")?.kind == .bool)
    }

    private func escaped(_ text: String) -> String {
        let quoted = String(decoding: JSONValue.string(text).encoded(), as: UTF8.self)
        return String(quoted.dropFirst().dropLast())
    }
}
