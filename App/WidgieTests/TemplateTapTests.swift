import Foundation
import Testing
import WidgetBuilder
import WidgetEngine

@testable import Widgie

/// What a template's face does when it is tapped, and what it shows, read off its picture.
@MainActor @Suite struct TemplateTapTests {
    /// Wednesday, 9 in the morning.
    private let nine = moment(2026, 11, 18, 9)

    private func text(_ id: String, rows: String? = nil, at date: Date) async throws -> String {
        try await TemplateRig(id, rows: rows, at: date).text(at: date)
    }

    /// Each template whose tap writes a row, the button, how many minutes its undo lasts, and rows whose newest
    /// is a minute old and Sam's.
    private nonisolated static let undoable = [
        ("plant-care", "water", 60, #"{"waterings": [{"minutesAgo": 1, "by": "Sam"}]}"#),
        ("pet-fed", "feed", 60, #"{"feeds": [{"minutesAgo": 1, "by": "Sam"}]}"#),
        ("baby-feeds", "left", 10, #"{"feeds": [{"minutesAgo": 1, "side": "Left", "by": "Sam"}]}"#),
        ("savings-jar", "add", 10, #"{"deposits": [{"minutesAgo": 1, "amount": 50, "by": "Sam"}]}"#),
        ("pushups", "ten", 10, #"{"sets": [{"minutesAgo": 1, "reps": 10, "by": "Sam"}]}"#),
        ("chores-scoreboard", "did", 10, #"{"chores": [{"minutesAgo": 1, "by": "Sam"}]}"#),
        ("water", "drink", 10, #"{"glasses": [{"minutesAgo": 1, "by": "Sam"}]}"#),
    ]

    @Test(arguments: undoable)
    func aTapCanBeTakenBackForAWhileButOnlyYourOwn(id: String, action: String, minutes: Int, theirs: String)
        async throws
    {
        let rig = try await TemplateRig(id, rows: "{}", at: nine)
        let before = await rig.picture(at: nine.adding(minutes: 1))
        try await rig.tap(action, at: nine)
        #expect(await rig.actions(at: nine.adding(minutes: minutes - 1)).contains("undo"), "\(id) offers the undo")
        #expect(
            !(await rig.actions(at: nine.adding(minutes: minutes + 1)).contains("undo")),
            "\(id)'s undo lasts \(minutes) minutes")

        try await rig.tap("undo", at: nine.adding(minutes: 1))
        #expect(await rig.picture(at: nine.adding(minutes: 1)).looksLike(before), "\(id)'s undo takes the tap back")

        let partner = try await TemplateRig(id, rows: theirs, at: nine)
        #expect(!(await partner.actions(at: nine)).contains("undo"), "\(id) cannot take back Sam's row")
    }

    /// The pile shows each template's first sample, and none of them offers an undo at any hour, a minute after
    /// midnight included.
    @Test func noUndoShowsInThePileAtAnyHour() async throws {
        for (id, _, _, _) in Self.undoable {
            for hour in [0, 9, 12, 23] {
                let date = moment(2026, 11, 23, hour, hour == 0 ? 1 : 59)
                let actions = try await TemplateRig(id, at: date).actions(at: date)
                #expect(!actions.contains("undo"), "\(id) offers an undo in the pile at \(hour)")
            }
        }
    }

    /// A sample means the same just after midnight as at noon: no row placed minutes ago falls on yesterday.
    /// Monday, so the counts of the week start that day too.
    @Test func everySampleLooksTheSameJustAfterMidnightAsAtNoon() async throws {
        let (early, noon) = (moment(2026, 11, 23, 0, 1), moment(2026, 11, 23, 12))
        for template in Template.catalog() {
            let document = try JSONSerialization.jsonObject(with: template.source().json) as? [String: Any]
            let samples = (document?["samples"] as? [String: Any] ?? [:]).keys.sorted()
            for sample in samples {
                let rows = try JSONSerialization.data(
                    withJSONObject: (document?["samples"] as? [String: Any])?[sample] ?? [:])
                let state = String(decoding: rows, as: UTF8.self)
                for family in Family.allCases {
                    let atEarly = try await TemplateRig(template.id, family: family, rows: state, at: early)
                        .picture(at: early)
                    let atNoon = try await TemplateRig(template.id, family: family, rows: state, at: noon)
                        .picture(at: noon)
                    #expect(atEarly.looksLike(atNoon), "\(template.id) \"\(sample)\" \(family) drifts after midnight")
                }
            }
        }
    }

    @Test func binsNightPassesTheTurnBackAndForth() async throws {
        let rig = try await TemplateRig("bins-night", rows: "{}", at: nine)
        let start = await rig.picture(at: nine)
        let shown = try await rig.text(at: nine)
        #expect(shown.contains("Sam") && shown.contains("up tonight"), "the turn starts with Sam: \(shown)")
        try await rig.tap("pass", at: nine)
        let passed = try await rig.text(at: nine)
        #expect(passed.contains("your turn tonight") && !passed.contains("Sam"), "then it is yours: \(passed)")
        try await rig.tap("pass", at: nine)
        #expect(await rig.picture(at: nine).looksLike(start), "and Sam's again")
    }

    /// The scoreboard counts your taps for you and Sam's rows for Sam.
    @Test func aChoreYouTapCountsAsYours() async throws {
        let rig = try await TemplateRig(
            "chores-scoreboard", rows: #"{"chores": [{"by": "Sam", "repeat": 11}, {"repeat": 9}]}"#, at: nine)
        try await rig.tap("did", at: nine)
        let expected = try await TemplateRig(
            "chores-scoreboard",
            rows: #"{"chores": [{"minutesAgo": 60, "by": "Sam", "repeat": 11}, {"minutesAgo": 60, "repeat": 9}, {}]}"#,
            at: nine)
        #expect(await rig.picture(at: nine).looksLike(await expected.picture(at: nine)), "you 10, Sam 11")
        let shown = try await rig.text(at: nine)
        #expect(shown.contains("10") && shown.contains("11") && !shown.contains("9"), "\(shown)")
    }

    @Test func theTripCountsDownToTodayAndThenHome() async throws {
        let cases = [
            ("{}", ["tap to set the date", "HOME", "SET DATE"]),
            (#"{"trips": [{"date": {"daysFromToday": 12}, "from": "London"}]}"#, ["12", "days until our trip", "LHR"]),
            (#"{"trips": [{"date": {"daysFromToday": 1}}]}"#, ["1", "day until our trip", "HOME", "NOV 19"]),
            (#"{"trips": [{"date": {"daysFromToday": 0}}]}"#, ["Today", "have a wonderful trip"]),
            (#"{"trips": [{"date": {"daysFromToday": -2}}]}"#, ["Home", "tap to plan the next one"]),
        ]
        for (rows, expected) in cases {
            let shown = try await TemplateRig("trip-countdown", family: .medium, rows: rows, at: nine).text(at: nine)
            for words in expected { #expect(shown.contains(words), "\(rows) shows \(words), not \(shown)") }
        }
    }

    @Test func daysFreeNamesTheNextMedal() async throws {
        for (days, medal) in [(0, 1), (6, 7), (7, 14), (47, 60), (180, 365), (400, 730)] {
            let rows = #"{"starts": [{"since": {"daysFromToday": -\#(days)}}]}"#
            let shown = try await text("days-free", rows: rows, at: nine)
            #expect(shown.contains("next medal: \(medal)"), "\(days) days: \(shown)")
        }
    }

    /// $1,240 of $2,000 saved: the $760 left, spread over the weeks to the end of the next June.
    @Test func theSavingsPlanSpreadsWhatIsLeftOverTheWeeksToJune() async throws {
        let cases = [
            (nine, "$24 a week to make it by June"),
            (moment(2027, 6, 20, 9), "$380 a week to make it by June"),
            (moment(2027, 6, 26, 9), "$760 to go by the end of June"),
            (moment(2027, 6, 30, 9), "$760 to go, and June ends today"),
            (moment(2027, 7, 1, 9), "$15 a week to make it by June"),
        ]
        for (date, line) in cases {
            let shown = try await text("savings-jar", at: date)
            #expect(shown.contains(line), "\(date): \(shown)")
        }
    }

    /// Each dated template is one button that opens a form, and the face counts from the date it sets, and from
    /// a new date when it is set again.
    @Test(arguments: [
        ("trip-countdown", "plan", "date", 12, "12 days until our trip", 30, "30 days until our trip"),
        ("days-together", "set", "since", -23, "23", -40, "40"),
        ("days-free", "start", "since", -47, "47 days", -6, "6 days"),
    ])
    func aDatedTemplateCountsFromTheDateItSets(
        id: String, action: String, field: String, first: Int, firstShown: String, second: Int, secondShown: String
    ) async throws {
        let rig = try await TemplateRig(id, rows: "{}", at: nine)
        #expect(await rig.actions(at: nine) == [action])
        for (days, shown) in [(first, firstShown), (second, secondShown)] {
            let day = Calendar.autoupdatingCurrent.dateComponents(
                [.year, .month, .day], from: Calendar.autoupdatingCurrent.date(byAdding: .day, value: days, to: nine)!)
            try await rig.tap(
                action, at: nine, input: [field: .date(year: day.year!, month: day.month!, day: day.day!)])
            let text = try await rig.text(at: nine)
            #expect(text.contains(shown), "\(id) set to \(days) days from today shows \(text)")
        }
    }
}
