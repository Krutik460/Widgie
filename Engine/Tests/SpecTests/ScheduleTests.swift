import Foundation
import Spec
import Testing

/// `Schedule.nextRun(after:in:)` and the vectors it exports to `Engine/Vectors/schedule.json`, which the Worker's
/// scheduler (`Backend/src/schedule.ts`) checks too, so the phone reloads when the server's row is due. Each case
/// asks for `runs.count` runs in a row, the first after `after` and each later one after the one before.
///
/// The file is what this engine answers for `scheduleCases`. After changing the cases or the rule, write it again
/// with `WIDGIE_WRITE_VECTORS=1 swift test --filter ScheduleTests` and check the Worker against it.
struct ScheduleTests {
    @Test func theVectorsFileIsWhatThisEngineAnswers() throws {
        let written = try scheduleVectors()
        let url = engineDirectory.appending(path: "Vectors/schedule.json")
        if ProcessInfo.processInfo.environment["WIDGIE_WRITE_VECTORS"] == "1" {
            try Data(written.utf8).write(to: url)
        }
        let stored = try String(contentsOf: url, encoding: .utf8)
        let mismatch = zip(stored.split(separator: "\n"), written.split(separator: "\n")).first { $0 != $1 }
        #expect(
            stored == written,
            "Vectors/schedule.json differs from this engine at \(mismatch.map { "\($0.0)\n  now: \($0.1)" } ?? "its end"); write it again with WIDGIE_WRITE_VECTORS=1 swift test --filter ScheduleTests"
        )
    }

    // The three places where Foundation's `.nextTime` matching differs from the server's rule, and the hourly run
    // on the night the clocks go back, checked by hand here as well as in the vectors.

    @Test func aWeeklyTimeTheClocksSkipRunsWhenTheyChangeNotAWeekLater() throws {
        let sunday = Spec.Schedule(cadence: .weekly(.sunday, hour: 2, minute: 30))
        #expect(
            try runs(sunday, "America/New_York", "2026-03-01T12:00:00Z", 2) == [
                "2026-03-08T07:00:00Z", "2026-03-15T06:30:00Z",
            ])
    }

    @Test func aTimeInsideAHalfHourGapRunsWhenTheClocksChange() throws {
        let daily = Spec.Schedule(cadence: .daily(hour: 2, minute: 15))
        #expect(
            try runs(daily, "Australia/Lord_Howe", "2026-10-03T00:00:00Z", 2) == [
                "2026-10-03T15:30:00Z", "2026-10-04T15:15:00Z",
            ])
    }

    @Test func aRepeatedTimeRunsOnceAtTheFirstEvenAskedFromBetweenTheTwo() throws {
        let daily = Spec.Schedule(cadence: .daily(hour: 1, minute: 30))
        let zone = "America/New_York"
        #expect(try runs(daily, zone, "2026-11-01T05:29:59Z", 1) == ["2026-11-01T05:30:00Z"])
        for after in ["2026-11-01T05:30:00Z", "2026-11-01T06:00:00Z", "2026-11-01T06:30:00Z"] {
            #expect(try runs(daily, zone, after, 1) == ["2026-11-02T06:30:00Z"], "after \(after)")
        }
    }

    @Test func anHourlyRunRunsInBothRealHoursWhenTheClocksGoBack() throws {
        let hourly = Spec.Schedule(cadence: .hourly(minute: 15))
        #expect(
            try runs(hourly, "America/New_York", "2026-11-01T04:00:00Z", 4) == [
                "2026-11-01T04:15:00Z", "2026-11-01T05:15:00Z", "2026-11-01T06:15:00Z", "2026-11-01T07:15:00Z",
            ])
        #expect(
            try runs(hourly, "America/New_York", "2026-03-08T05:00:00Z", 3) == [
                "2026-03-08T05:15:00Z", "2026-03-08T06:15:00Z", "2026-03-08T07:15:00Z",
            ])
    }
}

private struct ScheduleCase {
    let name: String
    let zone: String
    let cadence: Spec.Schedule.Cadence
    let after: String
    let count: Int

    init(_ name: String, _ zone: String, _ cadence: Spec.Schedule.Cadence, _ after: String, _ count: Int) {
        self.name = name
        self.zone = zone
        self.cadence = cadence
        self.after = after
        self.count = count
    }
}

/// Two daylight saving changes in each of three zones that change their clocks (New York in the north, Santiago and
/// Lord Howe in the south, Lord Howe by half an hour), plus London, Kolkata's half-hour offset, and UTC.
private let scheduleCases: [ScheduleCase] = {
    func daily(_ hour: Int, _ minute: Int) -> Spec.Schedule.Cadence { .daily(hour: hour, minute: minute) }
    func hourly(_ minute: Int) -> Spec.Schedule.Cadence { .hourly(minute: minute) }
    func weekly(_ day: Weekday, _ hour: Int, _ minute: Int) -> Spec.Schedule.Cadence {
        .weekly(day, hour: hour, minute: minute)
    }
    let york = "America/New_York"
    let santiago = "America/Santiago"
    let howe = "Australia/Lord_Howe"
    return [
        // New York: 02:00 becomes 03:00 on 2026-03-08, and 02:00 becomes 01:00 on 2026-11-01.
        .init("new york daily, a skipped time", york, daily(2, 30), "2026-03-07T12:00:00Z", 3),
        .init("new york daily at 06:00 over the spring change", york, daily(6, 0), "2026-03-06T12:00:00Z", 4),
        .init("new york daily, a repeated time", york, daily(1, 30), "2026-10-31T12:00:00Z", 3),
        .init("new york daily at 06:00 over the fall change", york, daily(6, 0), "2026-10-30T12:00:00Z", 4),
        .init("new york daily at midnight over the fall change", york, daily(0, 0), "2026-10-31T00:00:00Z", 3),
        .init("new york daily at 23:30 over the fall change", york, daily(23, 30), "2026-10-31T00:00:00Z", 3),
        .init("new york weekly, a skipped time on its day", york, weekly(.sunday, 2, 30), "2026-03-01T12:00:00Z", 2),
        .init("new york weekly, a repeated time on its day", york, weekly(.sunday, 1, 30), "2026-10-25T12:00:00Z", 2),
        .init("new york hourly over the spring change", york, hourly(15), "2026-03-08T04:00:00Z", 6),
        .init("new york hourly over the fall change", york, hourly(15), "2026-11-01T03:00:00Z", 6),
        .init("new york hourly on the hour over the fall change", york, hourly(0), "2026-11-01T03:30:00Z", 5),
        .init("new york, a second before a repeated time", york, daily(1, 30), "2026-11-01T05:29:59Z", 1),
        .init("new york, at the first of a repeated time", york, daily(1, 30), "2026-11-01T05:30:00Z", 1),
        .init("new york, between the two of a repeated time", york, daily(1, 30), "2026-11-01T06:00:00Z", 1),
        .init("new york, at the second of a repeated time", york, daily(1, 30), "2026-11-01T06:30:00Z", 1),
        .init(
            "new york weekly, between the two of a repeated time", york, weekly(.sunday, 1, 30), "2026-11-01T06:00:00Z",
            1),
        .init("new york, a minute before the clocks skip", york, daily(2, 30), "2026-03-08T06:59:00Z", 1),
        .init("new york, when the clocks skip", york, daily(2, 30), "2026-03-08T07:00:00Z", 1),
        .init("new york, within an hourly repeated hour", york, hourly(15), "2026-11-01T05:15:00Z", 2),
        // Santiago: 24:00 on Saturday becomes 23:00 on 2026-04-04, and 00:00 becomes 01:00 on 2026-09-06.
        .init("santiago daily, a repeated time before midnight", santiago, daily(23, 30), "2026-04-04T12:00:00Z", 3),
        .init("santiago daily at 06:00 over the fall change", santiago, daily(6, 0), "2026-04-03T12:00:00Z", 4),
        .init("santiago daily, a skipped midnight", santiago, daily(0, 0), "2026-09-05T12:00:00Z", 3),
        .init("santiago daily, a skipped time after midnight", santiago, daily(0, 30), "2026-09-05T12:00:00Z", 3),
        .init("santiago daily at 06:00 over the spring change", santiago, daily(6, 0), "2026-09-04T12:00:00Z", 4),
        .init(
            "santiago weekly, a repeated time on its day", santiago, weekly(.saturday, 23, 30), "2026-03-29T12:00:00Z",
            2),
        .init(
            "santiago weekly, a skipped time on its day", santiago, weekly(.sunday, 0, 15), "2026-08-31T12:00:00Z", 2),
        .init("santiago hourly over the fall change", santiago, hourly(30), "2026-04-05T01:00:00Z", 5),
        .init("santiago hourly over the spring change", santiago, hourly(30), "2026-09-06T02:00:00Z", 5),
        .init("santiago, between the two of a repeated time", santiago, daily(23, 30), "2026-04-05T03:00:00Z", 1),
        // Lord Howe: 02:00 becomes 01:30 on 2026-04-05, and 02:00 becomes 02:30 on 2026-10-04.
        .init("lord howe daily, a repeated time", howe, daily(1, 45), "2026-04-04T00:00:00Z", 3),
        .init("lord howe daily at 06:00 over the fall change", howe, daily(6, 0), "2026-04-03T00:00:00Z", 4),
        .init("lord howe daily, a time in the half-hour gap", howe, daily(2, 15), "2026-10-03T00:00:00Z", 3),
        .init("lord howe daily at the end of the gap", howe, daily(2, 30), "2026-10-03T00:00:00Z", 3),
        .init("lord howe daily at 06:00 over the spring change", howe, daily(6, 0), "2026-10-02T00:00:00Z", 4),
        .init("lord howe weekly, a repeated time on its day", howe, weekly(.sunday, 1, 45), "2026-03-29T00:00:00Z", 2),
        .init(
            "lord howe weekly, a time in the gap on its day", howe, weekly(.sunday, 2, 15), "2026-09-27T00:00:00Z", 2),
        .init("lord howe hourly over the fall change", howe, hourly(45), "2026-04-04T13:00:00Z", 5),
        .init("lord howe hourly at :15 over the fall change", howe, hourly(15), "2026-04-04T13:00:00Z", 5),
        .init("lord howe hourly over the spring change", howe, hourly(15), "2026-10-03T13:00:00Z", 5),
        .init("lord howe hourly on the hour over the spring change", howe, hourly(0), "2026-10-03T13:00:00Z", 5),
        .init("lord howe, between the two of a repeated time", howe, daily(1, 45), "2026-04-04T15:00:00Z", 1),
        // London: 01:00 becomes 02:00 on 2026-03-29, and 02:00 becomes 01:00 on 2026-10-25.
        .init("london daily, a skipped time", "Europe/London", daily(1, 0), "2026-03-28T12:00:00Z", 3),
        .init("london daily, a repeated time", "Europe/London", daily(1, 0), "2026-10-24T12:00:00Z", 3),
        // No changes: a half-hour offset, and UTC.
        .init("kolkata daily", "Asia/Kolkata", daily(6, 0), "2026-03-07T12:00:00Z", 2),
        .init("kolkata hourly", "Asia/Kolkata", hourly(0), "2026-03-07T12:10:00Z", 3),
        .init("utc weekly", "UTC", weekly(.monday, 9, 0), "2026-11-18T10:00:00Z", 2),
        .init("utc hourly", "UTC", hourly(15), "2026-11-18T10:20:00Z", 2),
        .init("utc daily, after a fraction of a second", "UTC", daily(6, 0), "2026-11-18T05:59:59.500Z", 2),
    ]
}()

/// The vectors file's text: one case a line, so a change reads as a diff of the cases it moved.
private func scheduleVectors() throws -> String {
    let lines = try scheduleCases.map { item in
        let schedule = Spec.Schedule(cadence: item.cadence)
        var members = item.cadence.members.map { (key: $0.key, value: $0.value) }.sorted { $0.key < $1.key }
        members.removeAll { $0.key == "every" }
        guard case .string(let every) = item.cadence.members["every"] else { throw VectorError() }
        var fields = [("name", quoted(item.name)), ("zone", quoted(item.zone)), ("every", quoted(every))]
        for member in members {
            guard case .string(let value) = member.value else { throw VectorError() }
            fields.append((member.key, quoted(value)))
        }
        let found = try runs(schedule, item.zone, item.after, item.count)
        fields.append(("after", quoted(item.after)))
        fields.append(("runs", "[" + found.map(quoted).joined(separator: ", ") + "]"))
        return "    {" + fields.map { "\"\($0.0)\": \($0.1)" }.joined(separator: ", ") + "}"
    }
    return """
        {
          "format": 1,
          "about": "Schedule.nextRun(after:in:) in Engine/Sources/Spec/Automations.swift, exported by Engine/Tests/SpecTests/ScheduleTests.swift and checked by Backend/test/schedule.test.ts. Each case asks for runs in a row: the first after `after`, each later one after the one before. every, at, and on are the automation payload's spelling.",
          "cases": [
        \(lines.joined(separator: ",\n"))
          ]
        }

        """
}

private struct VectorError: Error {}

private func quoted(_ text: String) -> String {
    "\"" + text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
}

/// `count` runs in a row after `after`, as ISO 8601 instants in UTC.
private func runs(_ schedule: Spec.Schedule, _ zoneName: String, _ after: String, _ count: Int) throws -> [String] {
    let zone = try #require(TimeZone(identifier: zoneName))
    let reader = ISO8601DateFormatter()
    reader.formatOptions =
        after.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : .withInternetDateTime
    var instant = try #require(reader.date(from: after))
    var found: [String] = []
    for _ in 0..<count {
        instant = try #require(schedule.nextRun(after: instant, in: zone))
        found.append(instant.formatted(.iso8601))
    }
    return found
}
