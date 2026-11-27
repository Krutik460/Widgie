import Foundation

extension Spec {
    /// An AI block. It runs on the server, never on the phone. Each run writes one row to `writes`, and the
    /// model's output is that table's fields, so there is no second schema to keep in step.
    package struct Automation: Hashable, Sendable {
        package let id: AutomationID
        package let prompt: String
        package let schedule: Schedule
        package let writes: Table
    }

    package struct Schedule: Hashable, Sendable {
        package enum Cadence: Hashable, Sendable {
            case hourly(minute: Int)
            case daily(hour: Int, minute: Int)
            case weekly(Weekday, hour: Int, minute: Int)
        }

        package let cadence: Cadence

        package init(cadence: Cadence) {
            self.cadence = cadence
        }

        /// The first run strictly after `instant` in `zone`, by the rule of the server's scheduler
        /// (`Backend/src/schedule.ts`), so the phone reloads when the server's row shows. Both check
        /// `Engine/Vectors/schedule.json`. Automations follow the phone's current time zone, so someone who moves
        /// keeps getting the word at 06:00 local.
        ///
        /// A daily or weekly time that a daylight saving change skips runs at the moment the clocks change (02:30
        /// runs at 03:00), and one that happens twice runs once, at the first: a day whose first instant is at or
        /// before `instant` has had its run. An hourly run is at every instant whose wall clock shows its minute,
        /// so the repeated hour runs twice and a skipped hour not at all. Foundation's `.nextTime` matching differs
        /// in three places (it skips a weekly time the clocks skip, skips a time inside a half-hour gap, and takes
        /// a repeated time's second instant when asked from between the two), so this is not `Calendar.nextDate`.
        package func nextRun(after instant: Date, in zone: TimeZone) -> Date? {
            let clock = ZoneClock(zone: zone)
            let after = instant.timeIntervalSince1970
            let run: Int?
            switch cadence {
            case .hourly(let minute):
                run = clock.nextHourly(minute: minute, after: after)
            case .daily(let hour, let minute):
                run = clock.nextDaily(on: nil, hour: hour, minute: minute, after: after)
            case .weekly(let weekday, let hour, let minute):
                run = clock.nextDaily(on: weekday, hour: hour, minute: minute, after: after)
            }
            return run.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
    }
}

/// Wall-clock arithmetic in one zone, in whole seconds since 1970, as `schedule.ts` does it in milliseconds.
private struct ZoneClock {
    let zone: TimeZone

    private static let minute = 60
    private static let hour = 3_600
    private static let day = 86_400

    /// The zone's offset from UTC at an instant, in seconds.
    private func offset(_ seconds: Int) -> Int {
        zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// The first instant after `after` that shows `hour:minute`, on `weekday` when one is given.
    func nextDaily(on weekday: Weekday?, hour: Int, minute: Int, after: TimeInterval) -> Int? {
        let start = Int(after.rounded(.down))
        // A day earlier than the wall clock's, since a repeated hour can start on the day before.
        let first = Self.floorDivide(start + offset(start), Self.day) - 1
        for index in first...(first + 9) {
            if let weekday, Day(index: index).weekday != weekday { continue }
            // A day whose first instant is not after `after` has had its run, even when a repeated time's second
            // is ahead.
            let run = firstInstant(day: index, hour: hour, minute: minute)
            if TimeInterval(run) > after { return run }
        }
        return nil
    }

    /// The first instant whose wall clock reads `hour:minute` on `day`: the earlier of two where the clocks go
    /// back, or, where they skip it, the moment they change.
    private func firstInstant(day: Int, hour: Int, minute: Int) -> Int {
        let local = day * Self.day + hour * Self.hour + minute * Self.minute
        let offsets = Set([offset(local - Self.day), offset(local), offset(local + Self.day)])
        if let run = offsets.map({ local - $0 }).filter({ offset($0) == local - $0 }).min() { return run }

        // Skipped: before the change the zone is behind this wall time, after it ahead. Find the change to the
        // minute.
        let ahead = offsets.max() ?? 0
        var skipped = local - ahead
        var changed = local - (offsets.min() ?? 0)
        while changed - skipped > Self.minute {
            let middle = skipped + (changed - skipped) / 2 / Self.minute * Self.minute
            if offset(middle) == ahead { changed = middle } else { skipped = middle }
        }
        return changed
    }

    /// The first instant after `after` whose wall clock shows `minute` and second 0.
    func nextHourly(minute: Int, after: TimeInterval) -> Int? {
        var from = after
        while from < after + TimeInterval(4 * Self.hour) {
            // At most one change within two hours, so the candidate for each offset in effect covers the next
            // hour.
            let start = Int(from.rounded(.down))
            let offsets = Set([offset(start), offset(start + 2 * Self.hour)])
            let runs = offsets.map { nextUtcMinute(from: from, Self.modulo(minute - $0 / Self.minute, 60)) }
            if let run = runs.filter({ Self.modulo(($0 + offset($0)) / Self.minute, 60) == minute }).min() {
                return run
            }
            from += TimeInterval(Self.hour)
        }
        return nil
    }

    /// The first whole minute after `from` whose UTC minute is `utcMinute`.
    private func nextUtcMinute(from: TimeInterval, _ utcMinute: Int) -> Int {
        let run = Self.floorDivide(Int(from.rounded(.down)), Self.hour) * Self.hour + utcMinute * Self.minute
        return TimeInterval(run) > from ? run : run + Self.hour
    }

    private static func floorDivide(_ a: Int, _ b: Int) -> Int {
        (a - modulo(a, b)) / b
    }

    private static func modulo(_ a: Int, _ b: Int) -> Int {
        ((a % b) + b) % b
    }
}

extension Spec.Automation {
    static func parse(_ id: Spec.AutomationID, _ json: JSONValue, _ resolver: Resolver) throws(Diagnostic)
        -> Spec.Automation
    {
        do throws(Diagnostic) {
            let automation = try Reader(
                json,
                else:
                    "an automation must be an object like {\"prompt\": \"...\", \"every\": \"day\", \"at\": \"06:00\", \"writes\": \"words\"}, not \(json.described)"
            )
            // Documents saved before automations followed the phone's time zone (2026-11-27) carry the zone
            // they were built in as `timeZone`. It is read past and never written again.
            try automation.requireOnly(["at", "every", "on", "prompt", "timeZone", "writes"]) {
                "unknown key \(Diagnostic.quote($0)) (keys: prompt, every, at, on, writes)"
            }
            guard let prompt = try automation.string("prompt", maxLength: Spec.Limits.promptLength), !prompt.isEmpty
            else {
                throw Diagnostic("needs \"prompt\": what the model should write each time it runs")
            }
            guard let target = automation["writes"] else {
                throw Diagnostic("needs \"writes\": the table each run adds a row to \(resolver.tableChoices)")
            }
            let writes = try resolver.table(target, for: "writes")
            return Spec.Automation(
                id: id, prompt: prompt, schedule: Spec.Schedule(cadence: try cadence(automation)), writes: writes)
        } catch {
            throw error.within("automation \(Diagnostic.quote(id.raw))")
        }
    }

    private static func cadence(_ automation: Reader) throws(Diagnostic) -> Spec.Schedule.Cadence {
        guard let every = automation["every"] else { throw Diagnostic("needs \"every\": hour, day, or week") }
        guard case .string(let raw) = every, ["hour", "day", "week"].contains(raw) else {
            throw Diagnostic("\"every\" must be hour, day, or week, not \(every.described)")
        }
        if raw != "week", automation.has("on") {
            throw Diagnostic("\"on\" names a weekday and works only with \"every\": \"week\"")
        }
        if raw == "hour" {
            guard let at = automation["at"] else { return .hourly(minute: 0) }
            guard case .string(let text) = at, text.count == 3, text.hasPrefix(":"), let minute = Int(text.dropFirst()),
                (0...59).contains(minute)
            else {
                throw Diagnostic("\"at\" for every hour must be the minute, like \":15\", not \(at.described)")
            }
            return .hourly(minute: minute)
        }
        guard let at = automation["at"] else {
            throw Diagnostic("needs \"at\": the time of day it runs, like \"06:00\" (24-hour)")
        }
        let parts = clock(at)
        guard parts.count == 2 else {
            throw Diagnostic("\"at\" must be a time of day like \"06:00\" (24-hour), not \(at.described)")
        }
        if raw == "day" { return .daily(hour: parts[0], minute: parts[1]) }
        let names = Weekday.allCases.map(\.name)
        guard let on = automation["on"] else {
            throw Diagnostic("every week needs \"on\": the weekday it runs (\(names.joined(separator: ", ")))")
        }
        guard case .string(let name) = on, let weekday = Weekday.allCases.first(where: { $0.name == name }) else {
            throw Diagnostic("\"on\" must be a weekday (\(names.joined(separator: ", "))), not \(on.described)")
        }
        return .weekly(weekday, hour: parts[0], minute: parts[1])
    }

    /// `"06:00"` as `[6, 0]`, or an empty list for anything that is not a 24-hour time.
    private static func clock(_ value: JSONValue) -> [Int] {
        guard case .string(let text) = value, text.count == 5 else { return [] }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }), let hour = Int(parts[0]),
            let minute = Int(parts[1]),
            (0...23).contains(hour), (0...59).contains(minute)
        else { return [] }
        return [hour, minute]
    }

    var json: JSONValue {
        .object(schedule.cadence.members.merging(["prompt": .string(prompt), "writes": .string(writes.id.raw)]) { $1 })
    }
}

extension Spec.Schedule.Cadence {
    /// `every`, `at`, and `on` as the document writes them, for the document and for the automation payload.
    package var members: [String: JSONValue] {
        switch self {
        case .hourly(let minute):
            ["every": .string("hour"), "at": .string(String(format: ":%02d", minute))]
        case .daily(let hour, let minute):
            ["every": .string("day"), "at": .string(String(format: "%02d:%02d", hour, minute))]
        case .weekly(let weekday, let hour, let minute):
            [
                "every": .string("week"), "on": .string(weekday.name),
                "at": .string(String(format: "%02d:%02d", hour, minute)),
            ]
        }
    }
}
