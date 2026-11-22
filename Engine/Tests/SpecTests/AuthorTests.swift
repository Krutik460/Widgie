import Foundation
import Testing

@testable import Spec

/// `where by`, and sample rows placed by minutes and written by another member.
@Suite struct AuthorTests {
    @Test func whereReadsByAloneOrBesideAField() throws {
        let spec = try parse(
            withTables(
                #""queries": {"#
                    + #""mine": {"count": "glasses", "where": {"by": "me"}, "window": "today"}, "#
                    + #""theirs": {"latest": "items", "where": {"by": "others", "done": false}, "window": "all"}}"#))
        guard case .count(_, let mine?, .today)? = spec.query("mine")?.shape else {
            Issue.record("mine is not a filtered count")
            return
        }
        #expect(mine.by == .me && mine.field == nil)
        guard case .latest(_, let theirs?, .all)? = spec.query("theirs")?.shape else {
            Issue.record("theirs is not a filtered latest")
            return
        }
        #expect(theirs.by == .others && theirs.field?.field.path == "items.done")
        #expect(
            String(decoding: spec.encoded(), as: UTF8.self).contains(#""where":{"by":"others","done":false}"#),
            "canonical bytes keep both conditions")
    }

    @Test func whereRefusesAnUnknownAuthor() {
        #expect(
            rejection(withTables(#""queries": {"x": {"count": "glasses", "where": {"by": "Sam"}, "window": "all"}}"#))
                == #"query "x": where "by" must be "me" (the person's own rows) or "others" (rows written by anyone the widget is shared with), not the string "Sam""#
        )
    }

    @Test func sampleRowsTakeMinutesAgoAndAnAuthor() throws {
        let spec = try parse(
            withTables(
                #""samples": {"fed": {"glasses": [{"minutesAgo": 95, "by": "Sam"}, {"daysAgo": 1, "by": "me"}]}}"#))
        let rows = try #require(spec.sample(named: "fed")).rows
        #expect(rows.map(\.minutesAgo) == [95, nil])
        #expect(rows.map(\.by) == ["Sam", nil])
        #expect(rows.map(\.daysAgo) == [0, 1])
    }

    @Test func sampleRowRefusesBothPlacements() {
        #expect(
            rejection(withTables(#""samples": {"x": {"glasses": [{"daysAgo": 1, "minutesAgo": 5}]}}"#))
                == #"sample "x", glasses[0]: give "daysAgo" or "minutesAgo", not both"#)
    }

    @Test func sampleRowRefusesAnEmptyOrLongName() {
        let line =
            #"sample "x", glasses[0]: "by" is "me" or another member's name on one line, like "Sam", up to 30 characters"#
        #expect(rejection(withTables(#""samples": {"x": {"glasses": [{"by": ""}]}}"#)) == line)
        #expect(
            rejection(withTables(#""samples": {"x": {"glasses": [{"by": "\#(String(repeating: "a", count: 31))"}]}}"#))
                == #"sample "x", glasses[0]: "by" is 31 characters; keep it to 30 or fewer"#)
    }

    @Test func sampleAuthorIsTrimmedOfMeaningButNotOfCase() throws {
        let spec = try parse(withTables(#""samples": {"x": {"glasses": [{"by": "Me"}, {"by": "Sam"}]}}"#))
        #expect(try #require(spec.sample(named: "x")).rows.map(\.by) == [nil, "Sam"])
        let line =
            #"sample "x", glasses[0]: "by" is "me" or another member's name on one line, like "Sam", up to 30 characters"#
        #expect(rejection(withTables(#""samples": {"x": {"glasses": [{"by": "   "}]}}"#)) == line)
        #expect(rejection(withTables(#""samples": {"x": {"glasses": [{"by": "Sam\u2028Lee"}]}}"#)) == line)
    }

    @Test func fullStateWritesRowsByAnotherMemberExceptForMe() throws {
        let spec = try parse(
            withTables(
                #""queries": {"#
                    + #""mine": {"count": "glasses", "where": {"by": "me"}, "window": "today"}, "#
                    + #""all": {"count": "glasses", "window": "today"}}"#))
        let today = spec.full.rows.filter { $0.daysAgo == 0 }
        #expect(today.contains { $0.by == nil && $0.count >= 100 })
        #expect(today.contains { $0.by == Spec.longestMemberName && $0.count >= 100 })
        #expect(Spec.longestMemberName.utf16.count == Spec.Limits.memberNameLength)
        #expect(today.allSatisfy { $0.minutesAgo == Spec.widestMinutesAgo }, "today's rows draw the widest age")
    }
}
